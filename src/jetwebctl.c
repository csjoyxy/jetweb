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
#define JW_GETEUID() jw_test_geteuid()
#else
#define JW_GETEUID() geteuid()
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
 * Align inactive memory limit (memlimit_inactive) so XNU's memorystatus_kill_hiwat_proc
 * does not prematurely kill protected WebContent / Networking / GPU / Host processes
 * via low default XPC inactive high-water-marks when leaving foreground.
 */
static void ensure_inactive_memlimit(pid_t pid, jw_target_kind_t kind, int32_t max_mb, int over_mem) {
    memorystatus_memlimit_properties_t mm;
    memset(&mm, 0, sizeof(mm));
    if (memorystatus_control(MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES,
                             (int32_t)pid, 0, &mm, sizeof(mm)) != 0) {
        return;
    }

    uint32_t clean_active_attr = mm.memlimit_active_attr & MEMORYSTATUS_MEMLIMIT_ATTR_FATAL;
    uint32_t clean_inactive_attr = mm.memlimit_inactive_attr & MEMORYSTATUS_MEMLIMIT_ATTR_FATAL;

    if (over_mem) {
        /* Over-budget WebContent: set non-fatal inactive HWM to max_mb so kernel reclaims it first under pressure */
        int32_t cap_mb = max_mb;
        if (mm.memlimit_inactive == cap_mb && clean_inactive_attr == 0) {
            return;
        }
        mm.memlimit_inactive = cap_mb;
        mm.memlimit_inactive_attr = 0;
        if (mm.memlimit_active > 0 && mm.memlimit_active < cap_mb) {
            mm.memlimit_active = cap_mb;
        }
        mm.memlimit_active_attr = clean_active_attr;
        (void)memorystatus_control(MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES,
                                   (int32_t)pid, 0, &mm, sizeof(mm));
        return;
    }

    int32_t desired_inactive = (kind == JW_TARGET_WEBCONTENT)
        ? (max_mb + 64)
        : ((max_mb > 512) ? max_mb : 512);

    int need_raise = (mm.memlimit_inactive > 0 && mm.memlimit_inactive < desired_inactive);
    int need_clear_fatal = (clean_inactive_attr != 0 && mm.memlimit_inactive > 0 && mm.memlimit_inactive < 1024);
    if (!need_raise && !need_clear_fatal) {
        return;
    }

    if (need_raise) {
        mm.memlimit_inactive = desired_inactive;
    }
    mm.memlimit_inactive_attr = 0; /* non-fatal soft high-water-mark */
    if (mm.memlimit_active > 0 && mm.memlimit_active < mm.memlimit_inactive) {
        mm.memlimit_active = mm.memlimit_inactive;
    }
    mm.memlimit_active_attr = clean_active_attr;

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

static void apply_protection_batch(int band, int max_mb, int pid_argc, char *pid_argv[],
                                   int quiet, char *summary_out, size_t summary_cap) {
    size_t sum_off = 0;
    if (summary_out && summary_cap > 0) summary_out[0] = '\0';

    for (int i = 0; i < pid_argc; i++) {
        int pid_i = 0;
        if (parse_positive_int(pid_argv[i], &pid_i) != 0) continue;
        pid_t pid = (pid_t)pid_i;
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

        /* Pre-align inactive memory limit even while in foreground (>=100) so FG->BG transition is safe */
        ensure_inactive_memlimit(pid, kind, max_mb, over_mem);

        /* Never demote foreground processes (>=100); pre-arm elevated inactive floor unless over_mem */
        if (cur >= JW_BAND_FOREGROUND) {
            set_elevated_inactive_floor(pid, over_mem ? 0 : 1);
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

        /* Always reinforce assertion priority & floor even if cur == band */
        if (set_priority_band(pid, band, 1) == 0) {
            int32_t after = band;
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
            int pid_i = 0;
            if (parse_positive_int(argv[i], &pid_i) != 0) continue;
            pid_t pid = (pid_t)pid_i;
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
            "Usage: jetwebctl --probe | --query <pids...> | --apply <band> <max_mb> <pids...> | "
            "--bg-guard <band> <max_mb> <epoch_file> <epoch> <host_pid> <log_file|-> <pids...>\n");
    return 1;
}
