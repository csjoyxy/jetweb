# JetWeb 工作交接文档（当前版本：`v0.2.1`）

> 更新日期：2026-11-27
> 仓库：`https://github.com/csjoyxy/jetweb`
> 主分支最新发版构建提交：`ab4d293`（Tag: `v0.2.1`，Actions Run: `46005863275`）
> 目标环境：iOS 15.0+（主测试真机：**iPhone 11 / iOS 16.4.1 / 4GB RAM**，TrollStore 安装，编译目标 `-target arm64-apple-ios15.0` / `-miphoneos-version-min=15.0`）

---

## 一、项目定位与核心架构速览

**JetWeb**（`com.lili.jetweb`）是面向 TrollStore 环境的多合一常驻桌面级 WebApp 容器，用于替代易被 iOS Jetsam 强杀重刷的 Safari 主屏幕书签。

### 核心模块职责
| 文件路径 | 核心职责 |
| --- | --- |
| `src/app/AppMain.swift` | `@main` 应用入口与窗口生命周期挂载 |
| `src/app/HubViewController.swift` | 多实例 `WKWebView` 容器、0ms 秒切毛玻璃胶囊底栏、灵动悬浮岛、三级内存释放与自动休眠、锁定模式热同步、前后台保活护航总控 |
| `src/app/GlassMenuSheet.swift` | 控制中心风格毛玻璃底部快捷菜单、高对比度语义调色盘 `JWGlassPalette`（WCAG AA）、圆角徽标组件 |
| `src/app/SettingsDrawerView.swift` | SwiftUI 常驻工作台设置页、锁定模式联动面板、单站点独立优先级/空间/豁免配置、诊断日志查看器 |
| `src/app/Models.swift` | `SiteItem` 与 `AppConfig` 配置持久化（本地 `/var/mobile/Library/JetWeb/config.json`，兼容向前升级） |
| `src/app/NotificationManager.swift` | iOS 原生横幅/声音通知投递、去重限频、`mixWithOthers` 混音静音后台监听与音频打断保护 |
| `src/app/WebScripts.swift` | WebKit API 兼容垫片、深色输入框对比度修正、CSS 滚动锚定防跳、三合一对话消息/流式输出监听器、原位 JS 内存清理 |
| `src/app/JetWebBridge.h` / `.m` | C/ObjC 桥接：`posix_spawn` root persona(99) 拉起 `jetwebctl`、WebKit 私有进程 PID 提取、三层独立 `WKWebsiteDataStore` 容器、`LockdownBypass` 容器白名单检测与 Darwin 通知热监听 |
| `src/jetwebctl.c` | 纯 C 短时 root 助手（`--probe` / `--query` / `--trim` / `--apply` / `--bg-guard`），任务完成即退、无常驻守护进程 |
| `src/entitlements-app.plist` / `src/entitlements-helper.plist` | TrollStore 主程序与 root 提档助手权限清单（受 `scripts/verify-jetweb.py` 严格一致性校验保护） |

---

## 二、近期版本演进与本次 `v0.2.1` 交付内容

### 1. `v0.2.1`（`ab4d293` · 2026-11-27）—— 全链路省电与降唤醒专项优化
基于真机 132 分钟运行日志（`jetweb-diag.log`）实测诊断，在不降低后台零被杀（13 次回前台 `terminatedCount=0`）可靠性的前提下，消除四类隐形功耗开销：
1. **智能按需后台护航（`AppConfig.bgSmartNotifyOnly`，默认开启）**：
   - 仅当最近 3 分钟内用户在站点发出提问（`user_sent`）、网页处于流式生成（`streaming`）或正在加载时切入后台，才启动 `AVAudioPlayer` 静音等信监听；
   - 普通阅读后切去其他 App 或锁屏时，**跳过 15 分钟静音音频播放**，顺手摘除离屏后台标签合成层并移交 `--bg-guard` 锁住 Jetsam 档位，约 1 秒即进入 `0% CPU` 系统冻结（预计削减日常 ~80% 后台耗电）；
   - 若退后台瞬间异步检测到页面仍有生成中状态（如存在“停止生成”按钮），自动动态晋升开启后台监听；设置页保留开关供需要被动接收他人群聊消息的用户切换回“每次退后台均监听”。
2. **前台巡检降频、波次去抖合并与 UI 脏检查**：
   - 修复 `startForegroundProtectTimer` 传入 `completion` 闭包绕过 `lastLoggedApplyDigest` 去重导致每 25 秒写盘记日志的问题；
   - 前台稳定态巡检周期由 `25s` 放宽至 `45s`（`tolerance = 9s`），切标签/导航提交后的保护波次加入 `0.28s` 去抖合并并精简为 `[0s, 2.2s, 9.5s]`，移除打开设置页时重复的二次 `--query` 子进程拉起；
   - `rebuildTabPills` 引入视觉签名脏检查与原位 `SitePillControl.configure(...)` 更新，未打开设置页时暂停广播 `@Published runtime.liveStatuses`，彻底消除周期性 UI 销毁重建开销。
3. **网页注入脚本 `MutationObserver` 零无用功裁剪（`WebScripts.swift`）**：
   - 当用户正在观看当前前台标签（`isUserWatching() == true`）时，`conversationMonitorScript` 直接 `O(1)` 短路返回，不再对每个流式字符遍历 DOM 祖先与拷贝 `textContent`；后台未读圆点扫描节流放宽至 `3.2s` 并优先限定在 `nav/aside` 侧栏容器；
   - `scrollAnchorStabilizerScript` 在隐藏/后台标签（`document.visibilityState === 'hidden'`）上直接跳过 `MutationObserver` 与 `ResizeObserver` 回调，避免离屏强制排版（`getBoundingClientRect`）。
4. **消除后台静音保活期间的重复 `--bg-guard` 55 秒波次**：
   - 当后台静音监听处于活跃状态（主进程维持 `100 FG`）时，不再重复启动 55 秒 7 波次 `jetwebctl --bg-guard`，仅执行一次 `+1.4s` 子进程锁档并立即释放 `UIBackgroundTask`，待静音监听真正结束（或被电话/媒体打断）挂起前再执行完整 7 波次 `--bg-guard`。

### 2. `v0.2.0`（`96eb9f7` · 2026-11-26）—— iOS 16.4.1 全局锁定模式（Lockdown Mode）豁免与 `LockdownBypass` 联动
- 定位并修复因 `com.apple.private.security.no-sandbox = true` 导致内核 `sandbox_container_path_for_pid` 返回空字符串、WebKit 跳过 `<DataContainer>/System/Preferences/com.apple.WebKit.cpmconfig_ignore` 白名单检查的根因；
- 补齐 `com.apple.developer.web-browser`、`MobileContainerManager.allowed`、`canmaplsdatabase` 权限；
- 在首个 `WKWebView` 创建前完成 `WKProcessPool` 进程级豁免同步，监听 `"WKCaptivePortalModeContainerConfigurationChanged"` Darwin 通知支持免重启热切换，并支持单站点精细化强制锁定隔离。

### 3. `cea8ef9` / `22e901a` / `08473ec` —— 三层主动内存释放 + 智能闲置标签自动休眠
- 闲置 `45s` 离屏摘除窗口树省显存 → 超水位/退后台前 `jetwebctl --trim` 无损内存脱水 → 闲置 `10/20/30/60` 分钟自动休眠清零至 `0 MB`（支持单标签 `📌 免自动休眠` 白名单与对话子页面 `lastKnownURL` 持久化精准恢复）+ 极端内存告警 LRU 自救。

---

## 三、交付产物与校验信息（`v0.2.1`）

- **GitHub Release 页面**：`https://github.com/csjoyxy/jetweb/releases/tag/v0.2.1`
- **`JetWeb.tipa` 直链**：`https://github.com/csjoyxy/jetweb/releases/download/v0.2.1/JetWeb.tipa`
- **安装包大小 / SHA-256**：`698,851 bytes` / `367f575722efe3ce9b56da97372428bb0ece3e4929c1f2238aa4b648a16d5bd9`
- **验包门禁状态**：`scripts/verify-jetweb.py` 全项 `STATUS: VERIFIED`（Mach-O ARM64、`LC_CODE_SIGNATURE`、`entitlements-app.plist` 与 `entitlements-helper.plist` 精确一致、`JW_VERSION == CFBundleShortVersionString == 0.2.1`）

---

## 四、关键红线与接力开发注意事项（必读）

1. **严守 iOS 15.0+ 编译与运行时兼容红线**：
   - 编译参数固定为 `-target arm64-apple-ios15.0` 与 `-miphoneos-version-min=15.0`；
   - 严禁直接硬调 iOS 16+/17+ 专属公开符号或仅高版本存在的 SF Symbols；涉及私有或高版本 WebKit/系统符号时，必须通过 `NSClassFromString` / `NSSelectorFromString` + `respondsToSelector:` + ObjC `@try/@catch` 安全反射封装在 `JetWebBridge.m`。
2. **严守 `scripts/verify-jetweb.py` 验包门禁**：
   - 每次升版本号时，**必须同步修改** `src/app/JetWebBridge.h` 的 `#define JW_VERSION` 与 `src/app/Info.plist` 的 `CFBundleShortVersionString`；
   - 修改权限时，确保 `src/entitlements-app.plist` 与 `ldid -Sentitlements-app.plist` 嵌入结果完全一致；
   - C 代码注释中切勿在 `/* ... */` 块注释内书写包含 `/*/` 的路径通配符（统一使用 `//` 单行注释）。
3. **发版与交接规范**：
   - 每次先推送 `main` 验证 GitHub Actions 编译与 `verify-jetweb.py` 通过，再打 `vX.Y.Z` 标签推送触发 GitHub Release 自动挂载 `JetWeb.tipa`；
   - **每发布一个新版本，必须同步更新本交接文档（`docs/HANDOVER.md`）并向用户输出当期版本工作交接文档**。

---

## 五、后续观察点与演进建议

1. **真机续航复测对比**：安装 `v0.2.1` 后，日常使用数小时可在「运行与诊断日志」观察：
   - 普通阅读切后台时应出现 `[NOTIFY] Smart-skip BG audio listener (no active reply/task in 3m) -> 0-power freeze with Jetsam guard`，不再每次空跑 15 分钟音频；
   - 前台静置阅读时 `[JETSAM] apply` 仅在档位或进程集合变化时记录，不再每 25 秒刷屏。
2. **真机分档调优建议**：在 4GB 内存机型同时配置 7～8 个站点时，建议将 1～2 个主力站点设为 `80~88 档`，其余辅助账号保持 `70 档` 搭配 `10~20 分钟` 闲置自动休眠，进一步降低多网页并发峰值压力。
