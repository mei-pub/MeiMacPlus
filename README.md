# MeiMacPlus

**Mac 增强工具集：按住 ⌘Q 防误退 + 合盖不息屏。** macOS 菜单栏常驻。

⌘Q 防误退的灵感来自开源项目 [SlowQuitApps](https://github.com/dteoh/SlowQuitApps)（GPL-2.0）的行为设计；
本项目是**独立的 Swift 实现**（未复制其代码），采用 MIT 许可证发布。

## 功能

### 退出保护（⌘Q 防误触）

- **按住才退出**：全局拦截 ⌘Q，需按住设定时长（默认 1 秒）应用才会退出，彻底避免误触。
- **可视化倒计时浮层**：按住时屏幕中央显示玻璃质感圆环进度 + 剩余时间 + 目标应用图标。
- **菜单栏开关**：一键启用/暂停退出保护（菜单栏图标随状态变化）。
- **白名单**：从运行中的应用添加或手输 Bundle ID，可切换"仅保护列表应用"模式。

### 合盖不息屏

- **合盖保持运行**：开启后合上 MacBook 盖子，屏幕熄灭，但系统**不休眠、不断网**，
  所有程序正常运行（下载、转码、远程访问都不中断）。
- **一次授权**：首次开启需输入管理员密码，安装一个极小的后台特权助手；之后开/关即时生效。
- **状态即真相**：设置写入系统电源管理（`pmset disablesleep`），重启、退出 App 均保持；
  App 启动时从系统读取真实状态同步开关。关闭开关即恢复系统默认。
- ⚠️ 注意：开启期间系统不会自动或手动休眠（苹果菜单"睡眠"仅熄屏）；电池模式合盖长时间
  运行请注意散热。

### 通用

- **可视化设置窗口**：时长滑块、浮层开关、白名单管理。
- **开机常驻**：基于 `SMAppService`（macOS 13+）的开机自动启动。
- **辅助功能权限引导**：首次启动逐步引导授权，授权后自动继续。
- **单实例**：重复启动会激活已运行实例。
- **中英双语**界面。

## 系统要求

- macOS 13.0 (Ventura) 或更高
- 辅助功能权限（系统设置 → 隐私与安全性 → 辅助功能）——退出保护需要
- 管理员密码（仅首次开启"合盖不息屏"时需要一次）

## 安装

1. 挂载 `dist/MeiMacPlus-<版本>.dmg`，将 MeiMacPlus 拖入 Applications 文件夹。
2. 首次启动按引导授予辅助功能权限。
3. （可选）在菜单栏勾选"开机自动启动"。

> 当前 DMG 为 ad-hoc 签名（开发者证书就位前）。正式分发请按
> [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md) 用 Developer ID 签名并公证。

## 合盖不息屏是如何工作的

合盖休眠在 macOS 中属于 *demand sleep*，用户态电源断言（IOPMAssertion）无法阻止；
唯一可靠的开关是系统电源管理设置 `pmset -a disablesleep 1`，而它需要 root 权限。

因此 MeiMacPlus 采用**特权助手**架构：

```
MeiMacPlus.app
├── Contents/MacOS/MeiMacPlus            ← 菜单栏应用
└── Contents/Library/LaunchDaemons/MeiMacPlusHelper   ← 特权助手（随包分发）

安装后（仅首次开启时授权一次）：
/Library/PrivilegedHelperTools/com.meimacplus.helper  ← 助手二进制
/Library/LaunchDaemons/com.meimacplus.helper.plist    ← launchd 配置（按需启动）
```

- App 与助手通过 XPC 通信，助手只暴露一个动作：执行 `pmset -a disablesleep 0|1` 并读回验证。
- 助手按需启动（MachServices），无 KeepAlive，不常驻、不耗资源。
- **安全模型**：助手校验连接方的代码签名有效且指定标识符为 `com.meimacplus.MeiMacPlus`，
  其他进程一律拒绝并记录日志。选择手动安装（经典 SMJobBless 布局）而非 SMAppService，
  是因为后者在每次重建/重签后校验失效，会反复要求重新授权。
- **读取不需要权限**：App 直接跑 `pmset -g` 同步开关真实状态。

### 卸载与手动恢复

卸载 App 不会自动移除助手（它是惰性的，仅在被连接时短暂运行）。如需彻底清理：

```bash
sudo launchctl bootout system/com.meimacplus.helper
sudo rm /Library/LaunchDaemons/com.meimacplus.helper.plist /Library/PrivilegedHelperTools/com.meimacplus.helper
```

若卸载时"合盖不息屏"仍处于开启状态，恢复系统默认：

```bash
sudo pmset -a disablesleep 0
```

## 构建与测试

```bash
# 构建（本仓库自带 Xcode 工程，含 App / Tests / Helper 三个 target）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project MeiMacPlus.xcodeproj -scheme MeiMacPlus \
  -configuration Release -derivedDataPath build/DerivedData build

# 单元测试
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project MeiMacPlus.xcodeproj -scheme MeiMacPlus \
  -configuration Debug -derivedDataPath build/DerivedData test

# 日常开发（Release 构建 + 用稳定的自签名身份重签，保持 TCC 授权不丢）
./scripts/make_dev_identity.sh   # 首次
./scripts/build_dev.sh --relaunch

# 生成图标 / 重新打 DMG
./scripts/make_iconset.sh build/appicon_1024.png
./scripts/make_dmg.sh
```

## 配置

设置持久化在 `com.meimacplus.MeiMacPlus` 域，键名与 SlowQuitApps 习惯对齐：
`enabled`、`delay`（毫秒）、`displayOverlay`、`whitelist`（Bundle ID 数组）、`invertList`、
`keepAwakeOnLidClose`。

```bash
# 例：按住 2 秒才退出
defaults write com.meimacplus.MeiMacPlus delay -int 2000
```

> 由 MeiQuitManage（1.0）更名而来。Bundle ID 变更，旧版本的设置与授权不会自动迁移。

## 架构概览

| 模块 | 职责 |
| --- | --- |
| `CmdQInterceptor` | CGEventTap 会话级事件拦截（需辅助功能权限，非沙盒） |
| `HoldEngine` | 纯逻辑按住状态机（可注入时钟，单元测试覆盖） |
| `InterceptPolicy` | 白名单/反转模式决策（纯函数） |
| `OverlayWindowController` | 非激活式倒计时浮层（SwiftUI + NSPanel） |
| `KeepAwakeManager` | 合盖不息屏客户端（pmset 读取解析 + XPC 调用 + 助手安装） |
| `MeiMacPlusHelper` | 特权助手守护进程（root XPC 服务，pmset 写入 + 客户端签名校验） |
| `MenuBarController` | 菜单栏图标与菜单 |
| `LoginItemManager` | SMAppService 开机启动 |
| `AppSettings` | UserDefaults 封装（ObservableObject） |

## 设计决策：为什么不发 Mac App Store

**App Store 强制 App Sandbox，而沙盒完全禁止 CGEventTap 事件监听**（即使授予辅助功能权限），
也无法安装特权助手 —— 两个核心能力都出不了沙盒。本项目仅提供 **DMG 直发完整版**
（Developer ID 签名 + 公证）。详见 [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md)。

## 许可

MIT © 2026 MeiMacPlus。行为设计致谢 [SlowQuitApps](https://github.com/dteoh/SlowQuitApps)（GPL-2.0，本项目未复制其代码）。
