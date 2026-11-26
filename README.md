# JetWeb

![Release](https://img.shields.io/github/v/release/csjoyxy/jetweb)
![Platform](https://img.shields.io/badge/Platform-iOS%2015.0%2B%20(TrollStore)-lightgrey)

面向 iOS 15.0+（主目标 iPhone 11 / iOS 16.4.1，TrollStore 安装）的**多合一常驻 WebApp 容器**，解决 Safari「添加到主屏幕」WebApp 切后台极易被 Jetsam 回收导致白屏重刷的问题。

---

## 核心特性

1. **多站点单容器常驻 + 同站多账号分身 + 智能闲置自动休眠**：支持在本机自由添加/编辑/排序最多 8 个常用 WebApp（配置仅保存在 `/var/mobile/Library/JetWeb/config.json`，不进入代码仓库），标签间 **0ms 秒切不白屏**；每个标签可任选「默认共享空间」或「独立账号空间」（同网站可同时登录多个账号互不串号）；底栏长按任意标签可一键**「🌙 休眠释放内存」**，并支持全局 **闲置标签自动休眠（10 / 20 / 30 / 60 分钟）** 与单标签 **「📌 免自动休眠」白名单**（自动跳过当前标签、AI 流式输出中或刚收到未读回复的标签，休眠后降至 `0 MB` 并持久化记忆具体对话子路径，下次唤醒精准恢复）。
2. **单站点自定义保活等级（30~92 档）+ 金字塔压阵护航**：支持为每个站点预设或手动输入精确进程等级（`30 ~ 92` 档，区分主次先后回收顺序），自动将 `Networking/GPU`（`+1` 档，上限 `94`）与 `JetWeb` 主容器（`+2` 档，上限 `95`）压阵在最高活跃标签之上；内置纯 C 短时 root 助手 `jetwebctl` 以 `pid:band` 断言级优先级、前台瞬时内存峰值防误杀缓冲（清除 `memlimit_active` 致命标记 + `+320 MB` 软高水位缓冲）与 SPA 路由记忆护航，并通过独立 `--bg-guard` 覆盖退后台后 0.6s～55s 系统降档窗口。
3. **智能新消息系统通知 + 限时省电后台监听**：通用三合一网页对话监听器（`window.Notification` 桥接、网页标题未读角标、对话列表新增未读圆点与 AI 流式回复落定摘要），当其他标签或退到后台的对话站点完成回复时，直接发送 iOS 原生横幅/锁屏通知与提示音，点击通知横幅即直达对应标签；后台采用 `mixWithOthers` 混音静音监听（不打断音乐/视频/无锁屏播放器），支持限时护航（默认 `15` 分钟）与「收到回复 `65` 秒后自动休眠并无缝移交 `--bg-guard`」，兼顾及时收信与长待机零耗电。
4. **三层主动内存释放 + 4GB 内存防杀自救 + 外部链接跳转下载**：
   - **无损原位内存脱水（不重载网页）**：支持在菜单/仪表盘一键触发，或在单页超软水位、切入后台前自动触发（`jetwebctl --trim` 唤醒 WebKit 原生 `MemoryPressureHandler` 清空历史页缓存、释放已解码大图位图与空闲脏页归还内核，保留 DOM、输入草稿与 WebSocket）；
   - **闲置标签延迟离屏省显存**：切走超设定时长（默认 `45s`，流式回复中自动豁免）的非当前标签自动临时移出窗口树，释放离屏合成显存并让 `35~88` 分档优先级在前台也实时生效（点回瞬间挂回不重载）；
   - **内存告警三级自救**：收到系统内存告警先执行全量深度无损脱水，若仍高危则按「低档位优先 → 最久未看 (LRU)」自动休眠次要非当前标签保住当前页；单标签持续超上限（默认 `450 MB`）自动回退 `30` 档；外链支持一键跳转 Safari 打开下载或拷贝链接。
5. **iOS 锁定模式（Lockdown Mode）豁免与 `LockdownBypass` 实时联动 + 单站点精细隔离**：针对 `no-sandbox` 权限下内核 `sandbox_container_path_for_pid` 返回空导致 WebKit 跳过 `<DataContainer>/System/Preferences/com.apple.WebKit.cpmconfig_ignore` 白名单检查的根因，内置数据容器自动定位与 `WKCaptivePortalModeContainerConfigurationChanged` Darwin 通知热监听——无需杀后台即可实时跟随 `LockdownBypass` 开关或内置策略豁免锁定模式（完整恢复 JIT、WebAssembly、WebGL 与网页自定义图标字体），同时支持按单标签对高危外站强制开启 `CaptivePortal` 锁定模式隔离运行。
6. **外观兜底、自签名证书与内置诊断日志**：支持全局/单站点浅色与深色切换及输入框对比度自动兜底，支持内网自签名 HTTPS / `wss://` 按域名信任与分空间 HTTP Basic Auth，内置滚动诊断日志查看器支持一键复制与导出。
7. **与 [JetPilot](https://github.com/csjoyxy/jetpilot) 联动**：同步写出 `/var/mobile/Library/JetPilot/webhub_pids.txt` 供联动巡检。

---

## 仓库结构

```
src/
  app/AppMain.swift            # Swift 入口 (@main AppDelegate)
  app/HubViewController.swift  # UIKit 多实例 WKWebView 容器、零遮挡毛玻璃胶囊坞、灵动悬浮岛与保活调度
  app/GlassMenuSheet.swift     # iOS 控制中心风格毛玻璃底部面板、首字母徽标、快捷磁贴与高光描边组件
  app/NotificationManager.swift# iOS 原生通知投递、去重限频与限时省电后台静音监听调度
  app/SettingsDrawerView.swift # SwiftUI 毛玻璃护航仪表盘、锁定模式策略、通知、多账号空间、证书与诊断页
  app/Models.swift             # 配置与进程状态模型 (兼容 config.json)
  app/Logger.swift             # 线程安全诊断日志器 (256KB 自动轮转 + URL 脱敏)
  app/WebScripts.swift         # WebKit 兼容垫片、滚动锚定防跳、深色输入框修正与三合一新消息检测
  app/ErrorOverlayView.swift   # 毛玻璃卡片式导航/证书异常提示与重试视图
  app/JetWebBridge.h/.m        # 精简 C/ObjC 桥接 (POSIX persona 拉起、锁定模式白名单联动、私有 PID 与独立存储 SPI)
  app/Info.plist               # App 信息 (com.lili.jetweb + 后台混音监听权限)
  app/Icon-*.png               # 应用图标
  jetwebctl.c                  # 纯 C 短时 root 提档、内存脱水与后台护航助手 (--probe / --query / --trim / --apply / --bg-guard)
  entitlements-app.plist       # 主程序权限 (persona-mgmt + web-browser + MCM/LS 容器查询 + IOKit)
  entitlements-helper.plist    # 提档助手权限 (memorystatus / jetsam.modify-priority)
scripts/
  verify-jetweb.py             # 打包后签名、架构、版本号与嵌入权限校验脚本
.github/workflows/
  build-jetweb.yml             # GitHub Actions：编译 C + Swift → 打包 JetWeb.tipa → 验包 → 挂载 Release
```

---

## 安装与发版流程

1. 推送 `main` 或 `review/*` 分支即自动触发 GitHub Actions 编译打包并上传 `JetWeb.tipa` 产物；
2. 真机验证通过后，打 tag（如 `v0.1.0`）并推送，Actions 在通过 `verify-jetweb.py` 验包门禁后自动将 `JetWeb.tipa` 挂载到 GitHub Release；
3. 手机端下载 `JetWeb.tipa`，通过 TrollStore 安装即可使用。
