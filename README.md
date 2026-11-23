# Ledger

安装时记账，卸载时对账。Ledger 是一个只在本机工作的 macOS 知情工具：新 App 落盘时记录它留下了什么，App 消失后再把账本摊开——还剩什么、每一样是什么、能不能动。

当前开发阶段：**M1（骨架、菜单栏、窗口壳、SQLite、单实例）**。扫描、记账、对账与清理尚未接入。

## 构建

要求 macOS 14+、Swift 5.9+ 与 Xcode 26（构建脚本自动使用已安装的 Xcode 工具链）。

```sh
./scripts/build-app.sh
open build/Ledger.app
```

构建产物为 `build/Ledger.app`，ad-hoc 签名，不会自动安装或开机启动。

## 运行

Ledger 是菜单栏应用，启动时不显示窗口：

- 左键点击菜单栏书本图标：打开主窗口。
- 右键点击：打开 Ledger / 退出 Ledger。
- 关闭窗口不会退出应用。

四个页签（概览、待处理、周报、设置）目前为骨架。

## 数据

本地账本位于：

```text
~/Library/Application Support/com.ledger.app/ledger.sqlite
```

使用 SQLite WAL 模式，`PRAGMA user_version = 1`。数据不加密（依赖 FileVault），不联网。

## 权限

M1 不需要任何额外权限。Full Disk Access 等可选权限将在扫描阶段接入，未授权时相关目录会作为盲区展示。

## 已知限制

- 尚未实现扫描/记账/对账/清理（M2 起逐步接入）；登录自启 LaunchAgent 待打包阶段接入。
- 详情见 docs/（需求、架构、设计、流程）与 devlog/（每日进度）。
