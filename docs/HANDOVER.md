# JetWeb 工作交接文档（当前版本：`v0.2.3`）

> 更新日期：2026-11-28
> 仓库：`https://github.com/csjoyxy/jetweb`
> 主分支最新发版构建提交：`34c965a`（Tag: `v0.2.3`，Actions Run: `46099208638`）
> 目标环境：iOS 15.0+（主测试真机：**iPhone 11 / iOS 16.4.1 / 4GB RAM**，TrollStore 安装，编译目标 `-target arm64-apple-ios15.0` / `-miphoneos-version-min=15.0`）

---

## 一、项目定位与核心架构速览

**JetWeb**（`com.lili.jetweb`）是面向 TrollStore 环境的多合一常驻桌面级 WebApp 容器，用于替代易被 iOS Jetsam 强杀重刷的 Safari 主屏幕书签。

### 核心模块职责
| 文件路径 | 核心职责 |
| --- | --- |
| `src/app/AppMain.swift` | `@main` 应用入口与窗口生命周期挂载 |
| `src/app/HubViewController.swift` | 多实例 `WKWebView` 容器、0ms 秒切毛玻璃胶囊底栏、灵动悬浮岛、三级内存释放与自动休眠、单页内存失控熔断与清缓存保登录修复、单站点「纯净原生模式」、锁定模式热同步、前后台保活护航总控 |
| `src/app/GlassMenuSheet.swift` | 控制中心风格毛玻璃底部快捷菜单、高对比度语义调色盘 `JWGlassPalette`（WCAG AA）、圆角徽标组件 |
| `src/app/SettingsDrawerView.swift` | SwiftUI 常驻工作台设置页、锁定模式联动面板、单站点独立优先级/空间/纯净模式/豁免配置、诊断日志查看器 |
| `src/app/Models.swift` | `SiteItem` 与 `AppConfig` 配置持久化（本地 `/var/mobile/Library/JetWeb/config.json`，兼容向前升级） |
| `src/app/NotificationManager.swift` | iOS 原生横幅/声音通知投递、去重限频、`mixWithOthers` 混音静音后台监听与音频打断保护 |
| `src/app/WebScripts.swift` | ES2023–ES2026 + `scheduler` 软内核兼容层、单世界（`.page`）深色输入框对比度修正、**前台零 `MutationObserver` 开销**的按需后台对话完成监听器、原位 JS 内存清理 |
| `src/app/JetWebBridge.h` / `.m` | C/ObjC 桥接：`posix_spawn` root persona(99) 拉起 `jetwebctl`、WebKit 私有进程 PID 提取、三层独立 `WKWebsiteDataStore` 容器、安全解锁隐藏 WebKit 现代特性（`RequestIdleCallback` / `ConstructableStylesheets` / `CSSNesting` 等）、`LockdownBypass` 容器白名单检测与 Darwin 通知热监听 |
| `src/jetwebctl.c` | 纯 C 短时 root 助手（`--probe` / `--query` / `--trim` / `--apply` / `--bg-guard`），任务完成即退、无常驻守护进程 |
| `src/entitlements-app.plist` / `src/entitlements-helper.plist` | TrollStore 主程序与 root 提档助手权限清单（受 `scripts/verify-jetweb.py` 严格一致性校验保护） |

---

## 二、近期版本演进与本次 `v0.2.3` 交付内容

### 1. `v0.2.3`（`34c965a` · 2026-11-28）—— 根治 `antigravity.google.com` 登录态超长对话白屏卡死与 `600~830MB` 内存暴涨（对齐 `JetBrowser` / `Safari` 纯净引擎）
通过对比同机 iPhone 11（iOS 16.4.1）上原厂 `Safari` 与 `JetBrowser`（稳定 `331 MB` / `0%` 空闲 CPU）以及 `jetweb-diag02.log` 全新独立账号容器 `agy #2`（Google 登录跳回 `antigravity.google.com/u/0/remote/...` 后 18 秒内从 `20 MB` 暴涨至 `826 MB` 白屏）的实测对照，100% 锁定根因为 `JetWeb` 独有的双 JS 世界（`.defaultClient` + `.page`）与页面加载期全树 `MutationObserver` / 滚动同步重排干扰，实施六项根治重构：
1. **彻底移除 700 行 `scrollAnchorStabilizerScript()`（消除虚拟列表死锁与双倍 DOM 包装器内存）**：
   - 该脚本此前注入在隔离世界 `.defaultClient` 并在 `document-start` 对整棵 `documentElement` 挂载 `MutationObserver` + `ResizeObserver` + 捕获级 `scroll` 监听；在 `antigravity.google.com` 水合超长虚拟滚动对话时触发 `scroll <-> elementFromPoint 强制同步排版 <-> 450 次 div.textContent 大字符串拷贝` 死循环；移除后虚拟滚动条 100% 回归原生流畅度。
2. **全面消灭 `.defaultClient` 第二 JS 世界（大型 SPA 立省 `80~180 MB` 内存）**：
   - 将 `inputContrastFixScript()` 从 `.defaultClient` 迁入主框架 `.page` 世界，并将 `didFinish` 输入框复检收敛为仅检查当前焦点元素，避免 WebKit 为数万个 DOM 节点创建双份 C++/JSC `DOMWrapperWorld`。
3. **重构 `conversationMonitorScript()` 实现「页面加载与前台浏览 `0` 观察器开销」**：
   - **关键改进**：前台观看当前标签（含首屏加载与 SPA 水合全过程）时，**完全不挂载任何 `MutationObserver`、不启动任何定时器、不执行任何 DOM 布局读取**；仅当切到其他标签或退入后台（`!isUserWatching()`）时才按需连接 `MutationObserver`，回到前台瞬间 `disconnect()`；
   - 移除 `window.Notification`（`permission = 'granted'`）与 `Element.prototype.attachShadow` 全局覆写，保持与原厂 `Safari` / `JetBrowser` 一致的 API 特征（防止 Google / Lit 应用误入残缺的桌面 Web Push 分支），并全面禁用触发同步重排的 `.innerText`（改用 `childElementCount <= 5` 限界的轻量叶子 `.textContent` 切片）。
4. **同步移植 `JetBrowser` 已真机验证的「软内核升级」套件**：
   - `JetWebBridge.m` 新增 `JWBridgeUnlockExperimentalWebKitFeatures`，安全反射启用 iOS 16.4 WebKit 内置的 `RequestIdleCallback`、`OffscreenCanvas`、`ConstructableStylesheets`、`CSSNestingEnabled`、`CSSSubgridEnabled`、`FetchPriority`、`ImportMaps`、`HTMLPopoverAttribute` 等稳定现代特性；
   - `compatPolyfillScript()` 补齐 `scheduler.yield` / `scheduler.postTask`（保障现代前端分片水合让出主线程）、`Iterator` 原型链全套辅助方法及 `Array.prototype` 不可变方法，默认 UA 同步升级为 `Safari 18.4`。
5. **净化 `WKWebView` 视图层级与收紧 4GB 机型失控熔断阈值**：
   - 将 `ErrorOverlayView` 从 `WKWebView` 内部移至外层 `webContainerView`，杜绝外部 AutoLayout 子视图干扰 `WKScrollView` 瓦片合成；
   - 针对 4GB 内存真机在 `826 MB` 即触发系统 `MEM-WARN` 的实测特征，将单页失控熔断阈值从 `960 MB` 下调至 `max(780, maxMemoryMB + 200) MB`（如 `800 MB`）。
6. **新增单站点「🍃 纯净原生模式（零辅助脚本）」一键兜底开关**：
   - 在顶栏当前站点菜单、底栏长按菜单与设置详情页均提供一键切换；开启后该标签页不注入任何 `WKUserScript` 与消息通道，100% 等同系统自带 Safari 裸 `WKWebView`。

### 2. `v0.2.2`（`7453391` · 2026-11-28）—— 卡死页面「清缓存保登录」一键急救与后台过热拦截
- 新增 `repairSitePreservingLogin` 清非 Cookie 缓存保登录自救按钮，以及 `hasAwakeOverheatedOrRunawayTab()` 拦截高内存/卡加载页面开启后台 15 分钟静音保活（已在 `jetweb-diag02.log` 真机验证成功阻断后台发烫）。

### 3. `v0.2.1`（`ab4d293` · 2026-11-27）—— 全链路省电与降唤醒专项优化
- 真机跨夜 7.5 小时实测 `0% CPU` 纯冻结零唤醒、连续 32 次切回前台 `terminatedCount=0`。

### 4. `v0.2.0`（`96eb9f7` · 2026-11-26）—— iOS 16.4.1 全局锁定模式豁免与 `LockdownBypass` 联动
- 修复 `no-sandbox` 下 WebKit 容器白名单失效问题，支持 `LockdownBypass` 实时 Darwin 通知热同步与单站点锁定策略切换。

---

## 三、交付产物与校验信息（`v0.2.3`）

- **GitHub Release 页面**：`https://github.com/csjoyxy/jetweb/releases/tag/v0.2.3`
- **`JetWeb.tipa` 直链**：`https://github.com/csjoyxy/jetweb/releases/download/v0.2.3/JetWeb.tipa`
- **安装包大小 / SHA-256**：`706,192 bytes` / `dd86d109ea9e7d90a37a6b2dc9ec813822cc7722424dd7e56464c10c838c37eb`
- **验包门禁状态**：`scripts/verify-jetweb.py` 全项 `STATUS: VERIFIED`（Mach-O ARM64、`LC_CODE_SIGNATURE`、`entitlements-app.plist` 与 `entitlements-helper.plist` 精确一致、`JW_VERSION == CFBundleShortVersionString == 0.2.3`）

---

## 四、关键红线与接力开发注意事项（必读）

1. **严守 iOS 15.0+ 编译与运行时兼容红线**：
   - 编译参数固定为 `-target arm64-apple-ios15.0` 与 `-miphoneos-version-min=15.0`；
   - 严禁直接硬调 iOS 16+/17+ 专属公开符号或仅高版本存在的 SF Symbols；涉及私有或高版本 WebKit/系统符号时，必须通过 `NSClassFromString` / `NSSelectorFromString` + `respondsToSelector:` + ObjC `@try/@catch` 安全反射封装在 `JetWebBridge.m`。
2. **严守「零 `.defaultClient` 双世界、零前台全树 `MutationObserver`」性能红线**：
   - 所有辅助 `WKUserScript` 统一运行在 `.page` 世界，禁止向 `.defaultClient` 注入 DOM 脚本（避免大型 SPA 双倍包装器内存暴涨）；
   - 前台首屏加载、水合与用户浏览期间严禁挂载全树 `MutationObserver` 或调用 `.innerText`。
3. **严守 `scripts/verify-jetweb.py` 验包门禁与发版交接规范**：
   - 每次升版本号时，**必须同步修改** `src/app/JetWebBridge.h` 的 `#define JW_VERSION` 与 `src/app/Info.plist` 的 `CFBundleShortVersionString`；
   - 每次先验证 GitHub Actions 编译与 `verify-jetweb.py` 全绿，再打 `vX.Y.Z` 标签推送触发 GitHub Release 自动挂载 `JetWeb.tipa`，并同步更新本交接文档（`docs/HANDOVER.md`）及向用户输出当期工作交接文档。
