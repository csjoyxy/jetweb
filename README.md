# JetWeb

![Release](https://img.shields.io/github/v/release/csjoyxy/jetweb)
![Platform](https://img.shields.io/badge/Platform-iOS%2015.0%2B%20(TrollStore)-lightgrey)

面向 iOS 15.0+（主目标 iPhone 11 / iOS 16.4.1，TrollStore 安装）的**多合一常驻 WebApp 容器**，解决 Safari「添加到主屏幕」WebApp 切后台极易被 Jetsam 回收导致白屏重刷的问题。

---

## 核心特性

1. **多站点单容器常驻**：支持在本机自由添加/编辑/排序最多 8 个常用 WebApp（配置仅保存在 `/var/mobile/Library/JetWeb/config.json`，不进入代码仓库），标签间 **0ms 秒切不白屏**，共用持久登录态。
2. **外壳 + `WebContent` 成对提档保活**：内置瞬时 root 助手 `jetwebctl`（毫秒级执行即退，零常驻后台耗电），通过 `WKWebView` 获取当前各标签精确的 `com.apple.WebKit.WebContent` / `Networking` / `GPU` 进程 PID，与主进程一并抬升至目标保护档位（默认 `85`，上限 `95`，绝不触碰前台 `100` 档）。
3. **4GB 内存安全阀**：单标签渲染进程物理内存超过设定上限（默认 `450 MB`）时自动停止保活并退回 `30` 档，避免异常网页撑爆整机内存。
4. **全屏沉浸模式**：支持一键收起底部切换栏为可拖动迷你悬浮胶囊（点击展开、长按快捷切站），兼顾 100% 全屏视野与快速切换。
5. **与 [JetPilot](https://github.com/csjoyxy/jetpilot) 联动**：安装后可在 JetPilot 主页将 `JetWeb`（`com.lili.jetweb`）加入保护规则，同时同步写出 `/var/mobile/Library/JetPilot/webhub_pids.txt` 供守护进程联动巡检。

---

## 仓库结构

```
src/
  app/main.m                # 容器主界面：多实例 WKWebView、底栏/悬浮胶囊、常驻工作台设置
  app/Info.plist            # App 信息（com.lili.jetweb）
  app/Icon-*.png            # 应用图标
  jetwebctl.c               # 瞬时 root 提档助手（--probe / --query / --apply）
  entitlements-app.plist    # 主程序权限（persona-mgmt 拉起 root 子进程）
  entitlements-helper.plist # 提档助手权限（memorystatus / jetsam.modify-priority）
scripts/
  verify-jetweb.py          # 打包后签名、架构、版本号与嵌入权限校验脚本
.github/workflows/
  build-jetweb.yml          # GitHub Actions：编译 → 打包 JetWeb.tipa → 验包 → 挂载 Release
```

---

## 安装与发版流程

1. 推送 `main` 或 `review/*` 分支即自动触发 GitHub Actions 编译打包并上传 `JetWeb.tipa` 产物；
2. 真机验证通过后，打 tag（如 `v0.1.0`）并推送，Actions 在通过 `verify-jetweb.py` 验包门禁后自动将 `JetWeb.tipa` 挂载到 GitHub Release；
3. 手机端下载 `JetWeb.tipa`，通过 TrollStore 安装即可使用。
