# JetWeb

![Release](https://img.shields.io/github/v/release/csjoyxy/jetweb)
![Platform](https://img.shields.io/badge/Platform-iOS%2015.0%2B%20(TrollStore)-lightgrey)

面向 iOS 15.0+（主目标 iPhone 11 / iOS 16.4.1，TrollStore 安装）的**多合一常驻 WebApp 容器**，解决 Safari「添加到主屏幕」WebApp 切后台极易被 Jetsam 回收导致白屏重刷的问题。

---

## 核心特性

1. **多站点单容器常驻 + 同站多账号分身**：支持在本机自由添加/编辑/排序最多 8 个常用 WebApp（配置仅保存在 `/var/mobile/Library/JetWeb/config.json`，不进入代码仓库），标签间 **0ms 秒切不白屏**；每个标签可任选「默认共享空间」或「独立账号空间」（独立持久 Cookie / LocalStorage / IndexedDB，同网站可同时登录多个账号互不串号）。
2. **外壳 + `WebContent` 断言级提档与非活跃内存护航**：内置纯 C 短时 root 助手 `jetwebctl`（任务完成即退，零常驻后台耗电），以断言级优先级（`MEMORYSTATUS_SET_PRIORITY_ASSERTION` + 非活跃保底）及非致命 `memlimit_inactive` 同步保护主进程与 `WebContent` / `Networking` / `GPU` 进程，并通过独立 `--bg-guard` 覆盖退后台后 0.6s～55s 系统降档窗口。
3. **4GB 内存安全阀**：单标签渲染进程物理内存超过设定上限（默认 `450 MB`）时自动停止保活并退回 `30` 档，避免异常网页撑爆整机内存。
4. **外观兜底、自签名证书与内置诊断日志**：支持全局/单站点浅色与深色切换及输入框对比度自动兜底，支持内网自签名 HTTPS / `wss://` 按域名信任与分空间 HTTP Basic Auth，内置滚动诊断日志查看器支持一键复制与导出。
5. **与 [JetPilot](https://github.com/csjoyxy/jetpilot) 联动**：同步写出 `/var/mobile/Library/JetPilot/webhub_pids.txt` 供联动巡检。

---

## 仓库结构

```
src/
  app/AppMain.swift            # Swift 入口 (@main AppDelegate)
  app/HubViewController.swift  # UIKit 多实例 WKWebView 容器、秒切底栏、悬浮胶囊、保活与认证调度
  app/SettingsDrawerView.swift # SwiftUI 常驻工作台设置抽屉、多账号空间管理、证书管理与诊断日志页
  app/Models.swift             # 配置与进程状态模型 (兼容 config.json)
  app/Logger.swift             # 线程安全诊断日志器 (256KB 自动轮转 + URL 脱敏)
  app/WebScripts.swift         # iOS 16.4 WebKit 兼容垫片、深色输入框对比度修正与前端报错采集
  app/ErrorOverlayView.swift   # 导航/证书失败可读提示与重试视图
  app/JetWebBridge.h/.m        # 精简 C/ObjC 桥接 (POSIX persona 提权拉起、WebKit 私有 PID 与独立存储 SPI)
  app/Info.plist               # App 信息 (com.lili.jetweb)
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
