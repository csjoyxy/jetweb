# JetWeb

![Release](https://img.shields.io/github/v/release/csjoyxy/jetweb)
![Platform](https://img.shields.io/badge/Platform-iOS%2015.0%2B%20(TrollStore)-lightgrey)

面向 iOS 15.0+（主目标 iPhone 11 / iOS 16.4.1，TrollStore 安装）的**多合一常驻 WebApp 容器**，解决 Safari「添加到主屏幕」WebApp 切后台极易被 Jetsam 回收导致白屏重刷的问题。

---

## 核心特性

1. **多站点单容器常驻 + 同站多账号分身 + 长按休眠释放内存**：支持在本机自由添加/编辑/排序最多 8 个常用 WebApp（配置仅保存在 `/var/mobile/Library/JetWeb/config.json`，不进入代码仓库），标签间 **0ms 秒切不白屏**；每个标签可任选「默认共享空间」或「独立账号空间」（同网站可同时登录多个账号互不串号）；底栏长按任意标签可一键**「🌙 休眠释放内存」**（立即销毁 `WebContent` 进程释放内存至 `0 MB`，完整保留登录态与底栏入口，点击即唤醒）。
2. **单站点自定义保活等级（30~92 档）+ 金字塔压阵护航**：支持为每个站点预设或手动输入精确进程等级（`30 ~ 92` 档，区分主次先后回收顺序），自动将 `Networking/GPU`（`+1` 档，上限 `94`）与 `JetWeb` 主容器（`+2` 档，上限 `95`）压阵在最高活跃标签之上；内置纯 C 短时 root 助手 `jetwebctl` 以 `pid:band` 断言级优先级、前台瞬时内存峰值防误杀缓冲（清除 `memlimit_active` 致命标记 + `+320 MB` 软高水位缓冲）与 SPA 路由记忆护航，并通过独立 `--bg-guard` 覆盖退后台后 0.6s～55s 系统降档窗口。
3. **智能新消息系统通知 + 限时省电后台监听**：通用三合一网页对话监听器（`window.Notification` 桥接、网页标题未读角标、对话列表新增未读圆点与 AI 流式回复落定摘要），当其他标签或退到后台的对话站点完成回复时，直接发送 iOS 原生横幅/锁屏通知与提示音，点击通知横幅即直达对应标签；后台采用 `mixWithOthers` 混音静音监听（不打断音乐/视频/无锁屏播放器），支持限时护航（默认 `15` 分钟）与「收到回复 `65` 秒后自动休眠并无缝移交 `--bg-guard`」，兼顾及时收信与长待机零耗电。
4. **4GB 内存安全阀 + 外部链接跳转下载**：单标签渲染进程持续超过设定上限（默认 `450 MB`）时自动停止保活并退回 `30` 档；点击新窗口外链或长按任意链接可一键跳转 iOS 自带 Safari 打开下载或拷贝链接。
5. **外观兜底、自签名证书与内置诊断日志**：支持全局/单站点浅色与深色切换及输入框对比度自动兜底，支持内网自签名 HTTPS / `wss://` 按域名信任与分空间 HTTP Basic Auth，内置滚动诊断日志查看器支持一键复制与导出。
6. **与 [JetPilot](https://github.com/csjoyxy/jetpilot) 联动**：同步写出 `/var/mobile/Library/JetPilot/webhub_pids.txt` 供联动巡检。

---

## 仓库结构

```
src/
  app/AppMain.swift            # Swift 入口 (@main AppDelegate)
  app/HubViewController.swift  # UIKit 多实例 WKWebView 容器、秒切底栏、悬浮胶囊、保活与认证调度
  app/NotificationManager.swift# iOS 原生通知投递、去重限频与限时省电后台静音监听调度
  app/SettingsDrawerView.swift # SwiftUI 常驻工作台设置抽屉、通知策略、多账号空间、证书与诊断日志页
  app/Models.swift             # 配置与进程状态模型 (兼容 config.json)
  app/Logger.swift             # 线程安全诊断日志器 (256KB 自动轮转 + URL 脱敏)
  app/WebScripts.swift         # WebKit 兼容垫片、深色输入框修正、三合一新消息检测与前端报错采集
  app/ErrorOverlayView.swift   # 导航/证书失败可读提示与重试视图
  app/JetWebBridge.h/.m        # 精简 C/ObjC 桥接 (POSIX persona 提权拉起、WebKit 私有 PID 与独立存储 SPI)
  app/Info.plist               # App 信息 (com.lili.jetweb + 后台混音监听权限)
  app/Icon-*.png               # 应用图标
  jetwebctl.c                  # 纯 C 短时 root 提档与后台护航助手 (--probe / --query / --apply / --bg-guard)
  entitlements-app.plist       # 主程序权限 (persona-mgmt + IOKit)
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
