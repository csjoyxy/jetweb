# JetWeb 工作交接文档（当前版本：`v0.2.2`）

> 更新日期：2026-11-28
> 仓库：`https://github.com/csjoyxy/jetweb`
> 主分支最新发版构建提交：`7453391`（Tag: `v0.2.2`，Actions Run: `46093883632`）
> 目标环境：iOS 15.0+（主测试真机：**iPhone 11 / iOS 16.4.1 / 4GB RAM**，TrollStore 安装，编译目标 `-target arm64-apple-ios15.0` / `-miphoneos-version-min=15.0`）

---

## 一、项目定位与核心架构速览

**JetWeb**（`com.lili.jetweb`）是面向 TrollStore 环境的多合一常驻桌面级 WebApp 容器，用于替代易被 iOS Jetsam 强杀重刷的 Safari 主屏幕书签。

### 核心模块职责
| 文件路径 | 核心职责 |
| --- | --- |
| `src/app/AppMain.swift` | `@main` 应用入口与窗口生命周期挂载 |
| `src/app/HubViewController.swift` | 多实例 `WKWebView` 容器、0ms 秒切毛玻璃胶囊底栏、灵动悬浮岛、三级内存释放与自动休眠、单页内存失控熔断与清缓存保登录修复、锁定模式热同步、前后台保活护航总控 |
| `src/app/GlassMenuSheet.swift` | 控制中心风格毛玻璃底部快捷菜单、高对比度语义调色盘 `JWGlassPalette`（WCAG AA）、圆角徽标组件 |
| `src/app/SettingsDrawerView.swift` | SwiftUI 常驻工作台设置页、锁定模式联动面板、单站点独立优先级/空间/豁免配置、诊断日志查看器 |
| `src/app/Models.swift` | `SiteItem` 与 `AppConfig` 配置持久化（本地 `/var/mobile/Library/JetWeb/config.json`，兼容向前升级） |
| `src/app/NotificationManager.swift` | iOS 原生横幅/声音通知投递、去重限频、`mixWithOthers` 混音静音后台监听与音频打断保护 |
| `src/app/WebScripts.swift` | ES2024–ES2026 WebKit 兼容垫片、深色输入框对比度修正、CSS 滚动锚定防跳、支持 Shadow DOM 的对话消息/流式输出监听器、原位 JS 内存清理 |
| `src/app/JetWebBridge.h` / `.m` | C/ObjC 桥接：`posix_spawn` root persona(99) 拉起 `jetwebctl`、WebKit 私有进程 PID 提取、三层独立 `WKWebsiteDataStore` 容器、`LockdownBypass` 容器白名单检测与 Darwin 通知热监听 |
| `src/jetwebctl.c` | 纯 C 短时 root 助手（`--probe` / `--query` / `--trim` / `--apply` / `--bg-guard`），任务完成即退、无常驻守护进程 |
| `src/entitlements-app.plist` / `src/entitlements-helper.plist` | TrollStore 主程序与 root 提档助手权限清单（受 `scripts/verify-jetweb.py` 严格一致性校验保护） |

---

## 二、近期版本演进与本次 `v0.2.2` 交付内容

### 1. `v0.2.2`（`7453391` · 2026-11-28）—— 卡死页面「清缓存保登录」一键急救、单页死循环发烫自动熔断与 Shadow DOM 通知修复
基于真机跨夜 10 小时日志与 `agy`（`antigravity.google.com`）超长对话引发的前端死循环（`101.6% CPU` / `1194 MB` / 进度条卡 `10%`）实测数据，实施五项根治改进：
1. **新增「修复白屏/卡死（清缓存保登录）」一键自救（`repairSitePreservingLogin`）**：
   - 同时挂载在 **顶栏站点胶囊长按菜单**、**右下角悬浮岛菜单** 以及 **已休眠/熔断状态卡片**；
   - 执行时先强制销毁卡死的 `WKWebView`（毫秒级终结 `100% CPU` 失控 `WebContent` 进程、释放文件锁），清空引发死锁的 `lastKnownURL` 子页面记忆，并清除该站点除 `WKWebsiteDataTypeCookies` 以外的全部缓存与前端数据库（`IndexedDB`、`LocalStorage`、`SessionStorage`、`ServiceWorker`、`FetchCache`、`Disk/MemoryCache`），**100% 保留 Google / ChatGPT 等账号登录 Cookie 免重新登录**，随后重建干净 `WKWebView` 回到初始首页。
2. **修复「卡在加载中（`isLoading`）导致后台开启 15 分钟静音保活烧机」的漏洞**：
   - 移除 `hasRecentConversationTaskForBgGuard()` 中对 `wv.isLoading` 的无条件放行；
   - 新增 `hasAwakeOverheatedOrRunawayTab()` 过热熔断拦截：只要任一唤醒标签单进程内存超过阈值（`max(780, maxMemoryMB + 180) MB`），退入后台时强制跳过静音音频监听，立即交由系统内核冻结至 `0% CPU` 防止口袋发烫。
3. **单标签 JS 堆死循环自动熔断器（`tryTripRunawayActiveTabCircuitBreaker`）与闪退死循环保护**：
   - 在高水位巡检（`patrol-high`）与系统内存告警（`MEM-WARN`）深度无损脱水后，若前台单标签仍占用 `>= max(960, maxMemoryMB + 360) MB` 且深度 GC 释放不足 `32 MB`（证明为不可回收的 JS 死循环堆膨胀），自动触发熔断休眠销毁失控进程并提示清缓存修复；
   - `reloadSiteFromHomeOrCurrent(..., forceHome: true)` 在页面卡加载或高内存时改为硬重建 `WKWebView`，避免向已死锁的同源渲染进程发送无效导航；
   - `snapshotLiveURLBeforeHibernate` 跳过加载进度 `< 35%` 的半截卡死网址；`webViewWebContentProcessDidTerminate` 对 `Commit` 后 `45s` 内速崩页面自动清空 `lastKnownURL`，`90s` 内连崩 `>= 2` 次自动熔断停止无限重刷。
4. **打通 `antigravity.google.com` 等 Shadow DOM 应用的后台任务与完成通知（`WebScripts.swift`）**：
   - `conversationMonitorScript` 通过 `Element.prototype.attachShadow` 有界挂载与 `ev.composedPath()` 穿透 Shadow Root，识别 Material 图标按钮（`stop` / `stop_circle` / `send` / `arrow_upward`），并将长耗时 Agent 任务流式有效期扩展至 `10 分钟`。
5. **扩展 iOS 16.4 WebKit 现代标准垫片（`compatPolyfillScript`）**：
   - 新增 `window.requestIdleCallback` / `cancelIdleCallback`、`ReadableStream.prototype[Symbol.asyncIterator]`、`Set.prototype` 七大集合方法、`AbortSignal.timeout`、`RegExp.escape` 与 `Error.isError`。

### 2. `v0.2.1`（`ab4d293` · 2026-11-27）—— 全链路省电与降唤醒专项优化
- 真机跨夜实测验证整夜 7.5 小时 `0% CPU` 纯冻结零唤醒、连续 32 次切回前台 `terminatedCount=0`；
- 按需智能后台护航（`bgSmartNotifyOnly`）、前台巡检降频至 `45s`、日志摘要去重与 `MutationObserver` 前台短路裁剪。

### 3. `v0.2.0`（`96eb9f7` · 2026-11-26）—— iOS 16.4.1 全局锁定模式豁免与 `LockdownBypass` 联动
- 修复 `no-sandbox` 下 WebKit 容器白名单失效问题，支持 `LockdownBypass` 实时 Darwin 通知热同步与单站点锁定策略切换。

---

## 三、交付产物与校验信息（`v0.2.2`）

- **GitHub Release 页面**：`https://github.com/csjoyxy/jetweb/releases/tag/v0.2.2`
- **`JetWeb.tipa` 直链**：`https://github.com/csjoyxy/jetweb/releases/download/v0.2.2/JetWeb.tipa`
- **安装包大小 / SHA-256**：`708,447 bytes` / `7c7ed758c853373d607d51cd92400e3ac286e68036881e6523559b7a8bfe7eb4`
- **验包门禁状态**：`scripts/verify-jetweb.py` 全项 `STATUS: VERIFIED`（Mach-O ARM64、`LC_CODE_SIGNATURE`、`entitlements-app.plist` 与 `entitlements-helper.plist` 精确一致、`JW_VERSION == CFBundleShortVersionString == 0.2.2`）

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
   - 每次先验证 GitHub Actions 编译与 `verify-jetweb.py` 全绿，再打 `vX.Y.Z` 标签推送触发 GitHub Release 自动挂载 `JetWeb.tipa`；
   - **每发布一个新版本，必须同步更新本交接文档（`docs/HANDOVER.md`）并向用户输出当期版本工作交接文档**。
