/*
 * jetwebctl.c — JetWeb 短时 root 提档与后台护航助手（非常驻守护进程，任务完成即退，零持续耗电）
 *
 * 职责：
 *   1. --probe
 *      验证 TrollStore persona(99/uid=0) 拉起与基础权限是否可用。
 *   2. --query <pid1> [pid2 ...]
 *      使用 XNU MEMORYSTATUS_CMD_GET_PRIORITY_LIST(1) 单 PID 快查接口读取真实 Jetsam 档位与物理内存（MB）。
 *   3. --apply <band> <max_mb> <pid1> [pid2 ...]
 *      将 JetWeb 主进程及其关联的 WebKit 进程（WebContent / Networking / GPU）锁入目标保护档位：
 *      - 同时写入 requested priority (flags=0) 与 assertion priority (MEMORYSTATUS_SET_PRIORITY_ASSERTION=0x1)，
 *        防止 WebKit XPC 进程在 clean 态被内核 memorystatus_update_idle_priority_locked 打回 0 档（IDLE 回收）；
 *      - 开启 MEMORYSTATUS_CMD_ELEVATED_INACTIVEJETSAMPRIORITY_ENABLE(14)，防止 runningboardd 释放断言瞬间跌入 0 档；
 *      - 通过 MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES(7) 同步抬高非活跃内存上限（memlimit_inactive，非致命），
 *        防止后台或非当前标签因默认 XPC HWM 过低被 memorystatus_kill_hiwat_proc 提前强杀；
 *      - 安全红线 1：路径严格白名单（仅限容器内 .../JetWeb.app/JetWeb 与系统 WebKit.framework 下的 XPC 进程）；
 *      - 安全红线 2：目标档位硬钳制在 [30, 95]，绝不降级前台活跃进程 (>=100)，但为其预对齐非活跃内存上限；
 *      - 安全红线 3：WebContent 单进程物理内存超过 max_mb 时放弃保活（清断言回退 30 档并收紧非致命上限），保护 4GB 内存。
 *   4. --bg-guard <band> <max_mb> <epoch_file> <expected_epoch> <host_pid> <pid1> [pid2 ...]
 *      退后台后独立运行的短时多波次护航模式（覆盖 UIBackgroundTask 结束、XNU 10s 老化降档、
 *      WebKit 20s ProcessThrottler 挂起及 ~32s FinishTaskInterruptable 断言到期窗口），
 *      若检测到用户切回前台（epoch 变更）或宿主退出则 1 秒内立即退出，全部波次完成后自动退出，零常驻耗电。
 *   5. --trim <gentle|deep> [pid1 pid2 ...]
 *      以 uid=0 发送 WebKit 原生 MemoryPressureHandler 通知（org.WebKit.memoryWarning / org.WebKit.lowMemory），
 *      在不重载网页、不丢 DOM/WebSocket/输入草稿的前提下，强制渲染进程同步清理 BFCache、已解码位图缓存、
 *      字体/CSS/选择器缓冲与空闲 FastMalloc 脏页归还内核，并实测前后物理内存差值。
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <time.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/resource.h>
#ifdef __APPLE__
#include <notify.h>
#endif

#define PROC_PIDPATHINFO_MAXSIZE (4 * 1024)
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

#ifndef RUSAGE_INFO_V4
#define RUSAGE_INFO_V4 4
typedef void *rusage_info_t;
struct rusage_info_v4 {
    uint8_t  ri_uuid[16];
    uint64_t ri_user_time;
    uint64_t ri_system_time;
    uint64_t ri_pkg_idle_wkups;
    uint64_t ri_interrupt_wkups;
    uint64_t ri_pageins;
    uint64_t ri_wired_size;
    uint64_t ri_resident_size;
    uint64_t ri_phys_footprint;
    uint64_t ri_proc_start_abstime;
    uint64_t ri_proc_exit_abstime;
    uint64_t ri_child_user_time;
    uint64_t ri_child_system_time;
    uint64_t ri_child_pkg_idle_wkups;
    uint64_t ri_child_interrupt_wkups;
    uint64_t ri_child_pageins;
    uint64_t ri_child_elapsed_abstime;
    uint64_t ri_diskio_bytesread;
    uint64_t ri_diskio_byteswritten;
    uint64_t ri_cpu_time_qos_default;
    uint64_t ri_cpu_time_qos_maintenance;
    uint64_t ri_cpu_time_qos_background;
    uint64_t ri_cpu_time_qos_utility;
    uint64_t ri_cpu_time_qos_legacy;
    uint64_t ri_cpu_time_qos_user_initiated;
    uint64_t ri_cpu_time_qos_user_interactive;
    uint64_t ri_billed_system_time;
    uint64_t ri_serviced_system_time;
    uint64_t ri_logical_writes;
    uint64_t ri_lifetime_max_phys_footprint;
    uint64_t ri_instructions;
    uint64_t ri_cycles;
    uint64_t ri_billed_energy;
    uint64_t ri_serviced_energy;
    uint64_t ri_interval_max_phys_footprint;
    uint64_t ri_runnable_time;
};
#endif
extern int proc_pid_rusage(int pid, int flavor, rusage_info_t *buffer);

/* Exact XNU bsd/sys/kern_memorystatus.h constants (verified on xnu-8796.101.5 / iOS 16.4.1) */
#define MEMORYSTATUS_CMD_GET_PRIORITY_LIST                        1
#define MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES                  2
#define MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES                  7
#define MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES                  8
#define MEMORYSTATUS_CMD_ELEVATED_INACTIVEJETSAMPRIORITY_ENABLE   14
#define MEMORYSTATUS_CMD_ELEVATED_INACTIVEJETSAMPRIORITY_DISABLE  15

#define MEMORYSTATUS_SET_PRIORITY_ASSERTION  0x1
#define MEMORYSTATUS_MEMLIMIT_ATTR_FATAL     0x1

#define JW_BAND_BACKGROUND  30
#define JW_BAND_MAX_PROTECT 95
#define JW_BAND_FOREGROUND  100

typedef struct memorystatus_priority_entry {
    pid_t    pid;
    int32_t  priority;
    uint64_t user_data;
    int32_t  limit;
    uint32_t state;
} memorystatus_priority_entry_t;

typedef struct memorystatus_priority_properties {
    int32_t  priority;
    uint64_t user_data;
} memorystatus_priority_properties_t;

typedef struct memorystatus_memlimit_properties {
    int32_t  memlimit_active;
    uint32_t memlimit_active_attr;
    int32_t  memlimit_inactive;
    uint32_t memlimit_inactive_attr;
} memorystatus_memlimit_properties_t;

_Static_assert(sizeof(memorystatus_priority_entry_t) == 24, "memorystatus_priority_entry_t ABI mismatch");
_Static_assert(sizeof(memorystatus_priority_properties_t) == 16, "memorystatus_priority_properties_t ABI mismatch");
_Static_assert(sizeof(memorystatus_memlimit_properties_t) == 16, "memorystatus_memlimit_properties_t ABI mismatch");

extern int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags,
                                void *buffer, size_t buffersize);

#ifdef JW_TEST_BUILD
extern uid_t jw_test_geteuid(void);
extern uint32_t jw_test_notify_post(const char *name);
#define JW_GETEUID() jw_test_geteuid()
#define JW_NOTIFY_POST(name) jw_test_notify_post(name)
#else
#define JW_GETEUID() geteuid()
#define JW_NOTIFY_POST(name) notify_post(name)
#endif

typedef enum {
    JW_TARGET_INVALID = 0,
    JW_TARGET_HOST_APP = 1,
    JW_TARGET_WEBCONTENT = 2,
    JW_TARGET_WEBKIT_AUX = 3
} jw_target_kind_t;

static int has_suffix(const char *str, const char *suffix) {
    size_t slen = strlen(str);
    size_t xlen = strlen(suffix);
    return (slen >= xlen) && (strcmp(str + slen - xlen, suffix) == 0);
}

static jw_target_kind_t classify_allowed_path(const char *path) {
    if (!path || path[0] == '\0') return JW_TARGET_INVALID;
    if ((strncmp(path, "/var/containers/Bundle/Application/", 35) == 0 ||
         strncmp(path, "/private/var/containers/Bundle/Application/", 43) == 0) &&
        has_suffix(path, "/JetWeb.app/JetWeb")) {
        return JW_TARGET_HOST_APP;
    }
    if ((strncmp(path, "/System/", 8) == 0 ||
         strncmp(path, "/private/preboot/", 17) == 0) &&
        strstr(path, "/System/Library/Frameworks/WebKit.framework/") != NULL) {
        if (strstr(path, "com.apple.WebKit.WebContent") != NULL) {
            return JW_TARGET_WEBCONTENT;
        }
        if (strstr(path, "com.apple.WebKit.Networking") != NULL ||
            strstr(path, "com.apple.WebKit.GPU") != NULL) {
            return JW_TARGET_WEBKIT_AUX;
        }
    }
    return JW_TARGET_INVALID;
}

static uint64_t read_phys_footprint_mb(pid_t pid) {
    struct rusage_info_v4 ri;
    memset(&ri, 0, sizeof(ri));
    if (proc_pid_rusage((int)pid, RUSAGE_INFO_V4, (rusage_info_t *)&ri) == 0) {
        return ri.ri_phys_footprint / (1024ULL * 1024ULL);
    }
    return 0;
}

/*
 * Read effective Jetsam priority band from XNU.
 * NOTE: Command 3 in XNU is MEMORYSTATUS_CMD_GET_JETSAM_SNAPSHOT (NOT priority properties!).
 * Single-PID query uses MEMORYSTATUS_CMD_GET_PRIORITY_LIST (1) with non-zero pid and
 * sizeof(memorystatus_priority_entry_t) (24 bytes), falling back to full list (pid=0).
 */
static int read_priority(pid_t pid, int32_t *out_prio) {
    if (pid <= 0 || !out_prio) {
        errno = EINVAL;
        return -1;
    }

    memorystatus_priority_entry_t single;
    memset(&single, 0, sizeof(single));
    single.pid = -1;
    int got_single = memorystatus_control(MEMORYSTATUS_CMD_GET_PRIORITY_LIST,
                                          (int32_t)pid, 0, &single, sizeof(single));
    if (got_single >= 0 && single.pid == pid) {
        *out_prio = single.priority;
        return 0;
    }

    int sz = memorystatus_control(MEMORYSTATUS_CMD_GET_PRIORITY_LIST, 0, 0, NULL, 0);
    if (sz <= 0) return -1;
    size_t alloc_sz = (size_t)sz + sizeof(memorystatus_priority_entry_t) * 16;
    memorystatus_priority_entry_t *list = (memorystatus_priority_entry_t *)malloc(alloc_sz);
    if (!list) return -1;
    int got = memorystatus_control(MEMORYSTATUS_CMD_GET_PRIORITY_LIST, 0, 0, list, alloc_sz);
    if (got <= 0) {
        int saved_err = errno;
        free(list);
        errno = saved_err ? saved_err : EIO;
        return -1;
    }
    int count = got / (int)sizeof(memorystatus_priority_entry_t);
    int found = 0;
    for (int i = 0; i < count; i++) {
        if (list[i].pid == pid) {
            *out_prio = list[i].priority;
            found = 1;
            break;
        }
    }
    free(list);
    if (!found) {
        errno = ESRCH;
        return -1;
    }
    return 0;
}

static void set_elevated_inactive_floor(pid_t pid, int enable) {
    uint32_t cmd = enable
        ? MEMORYSTATUS_CMD_ELEVATED_INACTIVEJETSAMPRIORITY_ENABLE
        : MEMORYSTATUS_CMD_ELEVATED_INACTIVEJETSAMPRIORITY_DISABLE;
    (void)memorystatus_control(cmd, (int32_t)pid, 1, NULL, 0);
}

/*
 * Align both active (foreground) and inactive (background) memory limits as non-fatal
 * soft high-water-marks (attr = 0):
 * - Clears MEMORYSTATUS_MEMLIMIT_ATTR_FATAL on memlimit_active so transient JS/DOM spikes
 *   (e.g. scrolling long conversations or SPA hydration hitting 550~750 MB before GC)
 *   trigger WebKit's MemoryPressureHandler GC instead of an instant kernel PERPROCESSLIMIT kill;
 * - Raises memlimit_inactive so FG->BG transitions are not killed by low default XPC HWMs;
 * - Caps background over-budget WebContent to max_mb soft HWM so true leaks are reclaimed first.
 */
static void ensure_memlimits(pid_t pid, jw_target_kind_t kind, int32_t max_mb, int over_mem, int is_foreground) {
    memorystatus_memlimit_properties_t mm;
    memset(&mm, 0, sizeof(mm));
    if (memorystatus_control(MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES,
                             (int32_t)pid, 0, &mm, sizeof(mm)) != 0) {
        return;
    }

    uint32_t active_fatal = mm.memlimit_active_attr & MEMORYSTATUS_MEMLIMIT_ATTR_FATAL;
    uint32_t inactive_fatal = mm.memlimit_inactive_attr & MEMORYSTATUS_MEMLIMIT_ATTR_FATAL;

    int32_t target_active;
    if (kind == JW_TARGET_WEBCONTENT) {
        target_active = max_mb + 320;
        if (target_active < 800) target_active = 800;
        if (target_active > 1400) target_active = 1400;
    } else {
        target_active = (max_mb + 256 > 768) ? (max_mb + 256) : 768;
    }

    int32_t target_inactive;
    if (!is_foreground && over_mem) {
        target_inactive = max_mb;
    } else if (kind == JW_TARGET_WEBCONTENT) {
        target_inactive = max_mb + 160;
    } else {
        target_inactive = (max_mb > 512) ? max_mb : 512;
    }

    int need_active_raise = (mm.memlimit_active > 0 && mm.memlimit_active < target_active);
    int need_inactive_change;
    if (!is_foreground && over_mem) {
        need_inactive_change = (mm.memlimit_inactive != target_inactive);
    } else {
        need_inactive_change = (mm.memlimit_inactive > 0 && mm.memlimit_inactive < target_inactive);
    }

    if (!active_fatal && !inactive_fatal && !need_active_raise && !need_inactive_change) {
        return;
    }

    if (need_active_raise) {
        mm.memlimit_active = target_active;
    }
    if (need_inactive_change) {
        mm.memlimit_inactive = target_inactive;
    }
    if (mm.memlimit_active > 0 && mm.memlimit_inactive > 0 && mm.memlimit_active < mm.memlimit_inactive) {
        mm.memlimit_active = mm.memlimit_inactive;
    }

    /* Non-fatal soft high-water-marks on both active & inactive ledgers */
    mm.memlimit_active_attr = 0;
    mm.memlimit_inactive_attr = 0;

    (void)memorystatus_control(MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES,
                               (int32_t)pid, 0, &mm, sizeof(mm));
}

/*
 * Lock target process into priority band:
 * - Toggle elevated inactive floor (CMD 14/15) to block transient drops into IDLE (0);
 * - Set requested priority (flags = 0);
 * - Set assertion priority (flags = MEMORYSTATUS_SET_PRIORITY_ASSERTION) so XPC dirty-tracking
 *   processes (WebContent / Networking / GPU) stay at `band` even when clean/idle.
 */
static int set_priority_band(pid_t pid, int32_t band, int enable_floor) {
    if (band < 0) band = 0;
    if (band > JW_BAND_MAX_PROTECT) band = JW_BAND_MAX_PROTECT;

    set_elevated_inactive_floor(pid, enable_floor);

    memorystatus_priority_properties_t sp;
    memset(&sp, 0, sizeof(sp));
    sp.priority = band;

    int rc_req = memorystatus_control(MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES,
                                      (int32_t)pid, 0, &sp, sizeof(sp));
    int rc_asr = memorystatus_control(MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES,
                                      (int32_t)pid, MEMORYSTATUS_SET_PRIORITY_ASSERTION, &sp, sizeof(sp));
    return (rc_asr == 0 || rc_req == 0) ? 0 : -1;
}

static int parse_positive_int(const char *s, int *out_val) {
    if (!s || !*s || !out_val) return -1;
    char *endp = NULL;
    errno = 0;
    long v = strtol(s, &endp, 10);
    if (errno != 0 || !endp || *endp != '\0' || v <= 0 || v > 2147483647L) return -1;
    *out_val = (int)v;
    return 0;
}

static int parse_ulong_str(const char *s, unsigned long *out_val) {
    if (!s || !*s || !out_val) return -1;
    char *endp = NULL;
    errno = 0;
    unsigned long v = strtoul(s, &endp, 10);
    if (errno != 0 || !endp) return -1;
    while (*endp == ' ' || *endp == '\t' || *endp == '\r' || *endp == '\n') endp++;
    if (*endp != '\0') return -1;
    *out_val = v;
    return 0;
}

static int read_epoch_file(const char *path, unsigned long *out_epoch) {
    if (!path || !out_epoch) return -1;
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    char buf[64];
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return -1;
    buf[n] = '\0';
    return parse_ulong_str(buf, out_epoch);
}

static int is_allowed_log_path(const char *path) {
    if (!path || path[0] == '\0' || strcmp(path, "-") == 0) return 0;
    if (strstr(path, "..") != NULL) return 0;
    if (strncmp(path, "/var/mobile/Library/JetWeb/", 27) == 0 ||
        strncmp(path, "/private/var/mobile/Library/JetWeb/", 35) == 0 ||
        strncmp(path, "/var/mobile/Containers/Data/Application/", 40) == 0 ||
        strncmp(path, "/private/var/mobile/Containers/Data/Application/", 48) == 0) {
        return 1;
    }
#ifdef JW_TEST_BUILD
    if (strncmp(path, "/tmp/", 5) == 0) return 1;
#endif
    return 0;
}

static void append_guard_log_line(const char *log_path, const char *msg) {
    if (!is_allowed_log_path(log_path) || !msg || !*msg) return;
    int fd = open(log_path, O_WRONLY | O_APPEND | O_NOFOLLOW);
    if (fd < 0) return;
    struct stat st;
    if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size < (256 * 1024)) {
        time_t now = time(NULL);
        struct tm tm_now;
        memset(&tm_now, 0, sizeof(tm_now));
        localtime_r(&now, &tm_now);
        char line[640];
        int len = snprintf(line, sizeof(line), "%02d:%02d:%02d [BG-GUARD] %s\n",
                           tm_now.tm_hour, tm_now.tm_min, tm_now.tm_sec, msg);
        if (len > 0) {
            size_t to_write = (size_t)len < sizeof(line) ? (size_t)len : (sizeof(line) - 1);
            ssize_t wr = write(fd, line, to_write);
            (void)wr;
        }
    }
    close(fd);
}

static void append_summary_item(char *buf, size_t cap, size_t *off_io, const char *piece) {
    if (!buf || !off_io || !piece || *off_io + 2 >= cap) return;
    int n = snprintf(buf + *off_io, cap - *off_io, "%s%s", (*off_io > 0 ? " " : ""), piece);
    if (n > 0) {
        size_t adv = (size_t)n;
        *off_io = (*off_io + adv < cap) ? (*off_io + adv) : (cap - 1);
    }
}

#define JW_BAND_MAX_WEBCONTENT 92
#define JW_BAND_MAX_WEBKIT_AUX 94

static int parse_pid_spec(const char *s, int default_band, pid_t *out_pid, int *out_band) {
    if (!s || !*s || !out_pid || !out_band) return -1;
    const char *colon = strchr(s, ':');
    if (!colon) {
        int pid_i = 0;
        if (parse_positive_int(s, &pid_i) != 0) return -1;
        *out_pid = (pid_t)pid_i;
        *out_band = default_band;
        return 0;
    }
    size_t pid_len = (size_t)(colon - s);
    if (pid_len == 0 || pid_len >= 16) return -1;
    char pid_buf[16];
    memcpy(pid_buf, s, pid_len);
    pid_buf[pid_len] = '\0';
    int pid_i = 0;
    if (parse_positive_int(pid_buf, &pid_i) != 0) return -1;

    int b = default_band;
    if (*(colon + 1) != '\0') {
        if (parse_positive_int(colon + 1, &b) != 0) return -1;
    }
    if (b < JW_BAND_BACKGROUND) b = JW_BAND_BACKGROUND;
    if (b > JW_BAND_MAX_PROTECT) b = JW_BAND_MAX_PROTECT;
    *out_pid = (pid_t)pid_i;
    *out_band = b;
    return 0;
}

static int clamp_band_for_kind(int band, jw_target_kind_t kind) {
    if (band < JW_BAND_BACKGROUND) band = JW_BAND_BACKGROUND;
    if (kind == JW_TARGET_WEBCONTENT && band > JW_BAND_MAX_WEBCONTENT) {
        return JW_BAND_MAX_WEBCONTENT;
    }
    if (kind == JW_TARGET_WEBKIT_AUX && band > JW_BAND_MAX_WEBKIT_AUX) {
        return JW_BAND_MAX_WEBKIT_AUX;
    }
    if (band > JW_BAND_MAX_PROTECT) {
        return JW_BAND_MAX_PROTECT;
    }
    return band;
}

static void apply_protection_batch(int default_band, int max_mb, int pid_argc, char *pid_argv[],
                                   int quiet, char *summary_out, size_t summary_cap) {
    size_t sum_off = 0;
    if (summary_out && summary_cap > 0) summary_out[0] = '\0';

    for (int i = 0; i < pid_argc; i++) {
        pid_t pid = 0;
        int raw_target_band = default_band;
        if (parse_pid_spec(pid_argv[i], default_band, &pid, &raw_target_band) != 0) continue;
        int pid_i = (int)pid;
        char item[64];

        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_pidpath((int)pid, path, sizeof(path)) <= 0) {
            if (!quiet) printf("GONE pid=%d\n", pid_i);
            if (summary_out) {
                snprintf(item, sizeof(item), "%d:GONE", pid_i);
                append_summary_item(summary_out, summary_cap, &sum_off, item);
            }
            continue;
        }
        jw_target_kind_t kind = classify_allowed_path(path);
        if (kind == JW_TARGET_INVALID) {
            if (!quiet) printf("SKIP_PATH pid=%d\n", pid_i);
            continue;
        }

        int target_band = clamp_band_for_kind(raw_target_band, kind);

        int32_t cur = -1;
        if (read_priority(pid, &cur) != 0) {
            if (!quiet) printf("ERR_READ pid=%d errno=%d\n", pid_i, errno);
            if (summary_out) {
                snprintf(item, sizeof(item), "%d:ERR(%d)", pid_i, errno);
                append_summary_item(summary_out, summary_cap, &sum_off, item);
            }
            continue;
        }
        uint64_t fp = read_phys_footprint_mb(pid);
        int over_mem = (kind == JW_TARGET_WEBCONTENT && fp > (uint64_t)max_mb) ? 1 : 0;
        int is_fg = (cur >= JW_BAND_FOREGROUND) ? 1 : 0;

        /* Align both active (spike buffer, non-fatal) and inactive memory limits */
        ensure_memlimits(pid, kind, max_mb, over_mem, is_fg);

        /* Never demote foreground processes (>=100); pre-arm elevated inactive floor */
        if (is_fg) {
            set_elevated_inactive_floor(pid, 1);
            if (!quiet) printf("FG pid=%d cur=%d fp=%llu\n", pid_i, (int)cur, (unsigned long long)fp);
            if (summary_out) {
                snprintf(item, sizeof(item), "%d:FG(%d,%lluM)", pid_i, (int)cur, (unsigned long long)fp);
                append_summary_item(summary_out, summary_cap, &sum_off, item);
            }
            continue;
        }

        /* Single-tab memory safety valve: release protection back to band 30 when exceeding max_mb */
        if (over_mem) {
            int32_t after = cur;
            if (set_priority_band(pid, JW_BAND_BACKGROUND, 0) == 0) {
                after = JW_BAND_BACKGROUND;
                (void)read_priority(pid, &after);
            }
            if (!quiet) {
                printf("OVER_MEM pid=%d before=%d after=%d fp=%llu max=%d\n",
                       pid_i, (int)cur, (int)after, (unsigned long long)fp, max_mb);
            }
            if (summary_out) {
                snprintf(item, sizeof(item), "%d:OVER(%d->%d,%lluM)", pid_i, (int)cur, (int)after, (unsigned long long)fp);
                append_summary_item(summary_out, summary_cap, &sum_off, item);
            }
            continue;
        }

        /* Always reinforce assertion priority & floor even if cur == target_band */
        if (set_priority_band(pid, target_band, 1) == 0) {
            int32_t after = target_band;
            (void)read_priority(pid, &after);
            if (!quiet) {
                printf("OK pid=%d before=%d after=%d fp=%llu\n",
                       pid_i, (int)cur, (int)after, (unsigned long long)fp);
            }
            if (summary_out) {
                snprintf(item, sizeof(item), "%d:%d->%d(%lluM)", pid_i, (int)cur, (int)after, (unsigned long long)fp);
                append_summary_item(summary_out, summary_cap, &sum_off, item);
            }
        } else {
            if (!quiet) printf("ERR_SET pid=%d before=%d errno=%d\n", pid_i, (int)cur, errno);
            if (summary_out) {
                snprintf(item, sizeof(item), "%d:SET_ERR(%d)", pid_i, errno);
                append_summary_item(summary_out, summary_cap, &sum_off, item);
            }
        }
    }
}

static int bg_guard_should_continue(const char *epoch_file, unsigned long expected_epoch, pid_t host_pid) {
    if (host_pid > 0 && kill(host_pid, 0) != 0 && errno == ESRCH) {
        return 0;
    }
    unsigned long disk_epoch = 0;
    if (read_epoch_file(epoch_file, &disk_epoch) == 0 && disk_epoch != expected_epoch) {
        return 0;
    }
    return 1;
}

static int sleep_interruptible_seconds(int seconds, const char *epoch_file,
                                       unsigned long expected_epoch, pid_t host_pid) {
    for (int s = 0; s < seconds; s++) {
        if (!bg_guard_should_continue(epoch_file, expected_epoch, host_pid)) {
            return 0;
        }
        struct timespec req;
        req.tv_sec = 1;
        req.tv_nsec = 0;
        while (nanosleep(&req, &req) != 0 && errno == EINTR) {
            if (!bg_guard_should_continue(epoch_file, expected_epoch, host_pid)) {
                return 0;
            }
        }
    }
    return bg_guard_should_continue(epoch_file, expected_epoch, host_pid);
}

static void clamp_policy_params(int *band_io, int *max_mb_io) {
    if (*band_io < JW_BAND_BACKGROUND) *band_io = JW_BAND_BACKGROUND;
    if (*band_io > JW_BAND_MAX_PROTECT) *band_io = JW_BAND_MAX_PROTECT;
    if (*max_mb_io < 100) *max_mb_io = 100;
    if (*max_mb_io > 1500) *max_mb_io = 1500;
}

#define JW_MAX_TRIM_PIDS 32

typedef struct {
    pid_t            pid;
    jw_target_kind_t kind;
    uint64_t         before_mb;
} jw_trim_entry_t;

static int run_memory_trim(int is_deep, int pid_argc, char *pid_argv[]) {
    jw_trim_entry_t entries[JW_MAX_TRIM_PIDS];
    int entry_count = 0;

    for (int i = 0; i < pid_argc && entry_count < JW_MAX_TRIM_PIDS; i++) {
        pid_t pid = 0;
        int unused_band = 85;
        if (parse_pid_spec(pid_argv[i], 85, &pid, &unused_band) != 0) continue;

        int dup = 0;
        for (int k = 0; k < entry_count; k++) {
            if (entries[k].pid == pid) {
                dup = 1;
                break;
            }
        }
        if (dup) continue;

        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_pidpath((int)pid, path, sizeof(path)) <= 0) {
            printf("GONE pid=%d\n", (int)pid);
            continue;
        }
        jw_target_kind_t kind = classify_allowed_path(path);
        if (kind == JW_TARGET_INVALID) {
            printf("SKIP_PATH pid=%d\n", (int)pid);
            continue;
        }
        entries[entry_count].pid = pid;
        entries[entry_count].kind = kind;
        entries[entry_count].before_mb = read_phys_footprint_mb(pid);
        entry_count++;
    }

    const char *notif_name = is_deep ? "org.WebKit.lowMemory" : "org.WebKit.memoryWarning";
    uint32_t nrc = JW_NOTIFY_POST(notif_name);
    if (nrc != 0) {
        printf("ERR_NOTIFY code=%u\n", (unsigned)nrc);
        return 3;
    }

    if (entry_count > 0) {
        struct timespec req;
        req.tv_sec = 0;
#ifdef JW_TEST_BUILD
        req.tv_nsec = 10L * 1000L * 1000L;
#else
        req.tv_nsec = 300L * 1000L * 1000L;
#endif
        while (nanosleep(&req, &req) != 0 && errno == EINTR) {}
    }

    uint64_t total_before = 0;
    uint64_t total_after = 0;
    int alive_count = 0;

    for (int i = 0; i < entry_count; i++) {
        pid_t pid = entries[i].pid;
        int pid_i = (int)pid;
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_pidpath(pid_i, path, sizeof(path)) <= 0) {
            printf("GONE pid=%d\n", pid_i);
            continue;
        }
        if (classify_allowed_path(path) == JW_TARGET_INVALID) {
            continue;
        }
        int32_t cur = -1;
        (void)read_priority(pid, &cur);
        uint64_t after_mb = read_phys_footprint_mb(pid);
        total_before += entries[i].before_mb;
        total_after += after_mb;
        alive_count++;
        printf("STAT pid=%d kind=%d cur=%d before=%llu fp=%llu\n",
               pid_i,
               (int)entries[i].kind,
               (int)cur,
               (unsigned long long)entries[i].before_mb,
               (unsigned long long)after_mb);
    }

    uint64_t saved = (total_before > total_after) ? (total_before - total_after) : 0;
    printf("TRIM_SUM mode=%s before=%llu after=%llu saved=%llu count=%d\n",
           is_deep ? "deep" : "gentle",
           (unsigned long long)total_before,
           (unsigned long long)total_after,
           (unsigned long long)saved,
           alive_count);
    return 0;
}

int main(int argc, char *argv[]) {
    if (argc >= 2 && strcmp(argv[1], "--probe") == 0) {
        return (JW_GETEUID() == 0) ? 0 : 2;
    }

    if (JW_GETEUID() != 0) {
        fprintf(stderr, "ERR not_root euid=%u\n", (unsigned)JW_GETEUID());
        return 2;
    }

    if (argc >= 3 && strcmp(argv[1], "--query") == 0) {
        for (int i = 2; i < argc; i++) {
            pid_t pid = 0;
            int unused_band = 85;
            if (parse_pid_spec(argv[i], 85, &pid, &unused_band) != 0) continue;
            int pid_i = (int)pid;
            char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
            if (proc_pidpath((int)pid, path, sizeof(path)) <= 0) {
                printf("GONE pid=%d\n", pid_i);
                continue;
            }
            jw_target_kind_t kind = classify_allowed_path(path);
            if (kind == JW_TARGET_INVALID) {
                printf("SKIP_PATH pid=%d\n", pid_i);
                continue;
            }
            int32_t cur = -1;
            (void)read_priority(pid, &cur);
            uint64_t fp = read_phys_footprint_mb(pid);
            printf("STAT pid=%d kind=%d cur=%d fp=%llu\n",
                   pid_i, (int)kind, (int)cur, (unsigned long long)fp);
        }
        return 0;
    }

    if (argc >= 3 && strcmp(argv[1], "--trim") == 0) {
        int is_deep = -1;
        if (strcmp(argv[2], "gentle") == 0) {
            is_deep = 0;
        } else if (strcmp(argv[2], "deep") == 0) {
            is_deep = 1;
        } else {
            fprintf(stderr, "ERR invalid_trim_mode mode=%s\n", argv[2]);
            return 1;
        }
        return run_memory_trim(is_deep, argc - 3, &argv[3]);
    }

    if (argc >= 5 && strcmp(argv[1], "--apply") == 0) {
        int band = 85;
        int max_mb = 450;
        if (parse_positive_int(argv[2], &band) != 0) band = 85;
        if (parse_positive_int(argv[3], &max_mb) != 0) max_mb = 450;
        clamp_policy_params(&band, &max_mb);

        apply_protection_batch(band, max_mb, argc - 4, &argv[4], 0, NULL, 0);
        return 0;
    }

    if (argc >= 9 && strcmp(argv[1], "--bg-guard") == 0) {
        int band = 85;
        int max_mb = 450;
        if (parse_positive_int(argv[2], &band) != 0) band = 85;
        if (parse_positive_int(argv[3], &max_mb) != 0) max_mb = 450;
        clamp_policy_params(&band, &max_mb);

        const char *epoch_file = argv[4];
        unsigned long expected_epoch = 0;
        if (parse_ulong_str(argv[5], &expected_epoch) != 0) return 1;

        int host_pid_i = 0;
        if (parse_positive_int(argv[6], &host_pid_i) != 0) return 1;
        pid_t host_pid = (pid_t)host_pid_i;
        const char *log_path = argv[7];

        /* Protect this short-lived guard process itself (~400KB RSS) until its 55s waves complete */
        (void)set_priority_band(getpid(), band, 1);

#ifdef JW_TEST_BUILD
        const int wave_delays[] = { 0, 1, 1 };
#else
        const int wave_delays[] = { 0, 2, 4, 8, 12, 12, 17 };
#endif
        int num_waves = (int)(sizeof(wave_delays) / sizeof(wave_delays[0]));
        int completed_waves = 0;
        for (int w = 0; w < num_waves; w++) {
            if (wave_delays[w] > 0) {
                if (!sleep_interruptible_seconds(wave_delays[w], epoch_file, expected_epoch, host_pid)) {
                    break;
                }
            } else if (!bg_guard_should_continue(epoch_file, expected_epoch, host_pid)) {
                break;
            }
            char sum[420];
            apply_protection_batch(band, max_mb, argc - 8, &argv[8], 1, sum, sizeof(sum));
            completed_waves = w + 1;
            if (is_allowed_log_path(log_path)) {
                char msg[512];
                snprintf(msg, sizeof(msg), "wave=%d/%d ep=%lu [%s]", w + 1, num_waves, expected_epoch, sum);
                append_guard_log_line(log_path, msg);
            }
        }
        if (is_allowed_log_path(log_path)) {
            char end_msg[128];
            snprintf(end_msg, sizeof(end_msg), "exit waves=%d/%d ep=%lu (%s)",
                     completed_waves, num_waves, expected_epoch,
                     (completed_waves == num_waves ? "completed" : "cancelled_by_fg_or_exit"));
            append_guard_log_line(log_path, end_msg);
        }
        return 0;
    }

    fprintf(stderr,
            "Usage: jetwebctl --probe | --query <pids...> | --trim <gentle|deep> [pids...] | "
            "--apply <band> <max_mb> <pids...> | "
            "--bg-guard <band> <max_mb> <epoch_file> <epoch> <host_pid> <log_file|-> <pids...>\n");
    return 1;
}
