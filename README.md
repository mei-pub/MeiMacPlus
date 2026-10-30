# MeiQuitManage

**按住 ⌘Q，告别误触退出。** macOS 菜单栏常驻的“慢退出”保护工具。

灵感来自开源项目 [SlowQuitApps](https://github.com/dteoh/SlowQuitApps)（GPL-2.0）的行为设计；
本项目是**独立的 Swift 实现**（未复制其代码），采用 MIT 许可证发布。

## 功能

- **按住才退出**：全局拦截 ⌘Q，需按住设定时长（默认 1 秒）应用才会退出，彻底避免误触。
- **可视化倒计时浮层**：按住时屏幕中央显示玻璃质感圆环进度 + 剩余时间 + 目标应用图标。
- **菜单栏开关**：一键启用/暂停退出保护（菜单栏图标随状态变化：实心/半透明）。
- **可视化设置窗口**：按住时长滑块、浮层开关、白名单管理（从运行中的应用添加或手输 Bundle ID）、仅保护列表模式。
- **开机常驻**：基于 `SMAppService`（macOS 13+）的开机自动启动。
- **辅助功能权限引导**：首次启动逐步引导授权，授权后自动继续。
- **单实例**：重复启动会激活已运行实例。
- **中英双语**界面。

## 系统要求

- macOS 13.0 (Ventura) 或更高
- 辅助功能权限（系统设置 → 隐私与安全性 → 辅助功能）

## 安装

1. 挂载 `dist/MeiQuitManage-<版本>.dmg`，将 MeiQuitManage 拖入 Applications 文件夹。
2. 首次启动按引导授予辅助功能权限。
3. （可选）在菜单栏勾选“开机自动启动”。

> 当前 DMG 为 ad-hoc 签名（开发者证书就位前）。正式分发请按
> [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md) 用 Developer ID 签名并公证。

## 构建与测试

```bash
# 构建（本仓库自带 Xcode 工程）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project MeiQuitManage.xcodeproj -scheme MeiQuitManage \
  -configuration Release -derivedDataPath build/DerivedData build

# 单元测试
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project MeiQuitManage.xcodeproj -scheme MeiQuitManage \
  -configuration Debug -derivedDataPath build/DerivedData test

# 生成图标 / 重新打 DMG
./scripts/make_iconset.sh build/appicon_1024.png
./scripts/make_dmg.sh
```

## 配置

设置持久化在 `com.meiquit.MeiQuitManage` 域，键名与 SlowQuitApps 习惯对齐：
`enabled`、`delay`（毫秒）、`displayOverlay`、`whitelist`（Bundle ID 数组）、`invertList`。

```bash
# 例：按住 2 秒才退出
defaults write com.meiquit.MeiQuitManage delay -int 2000
```

## 架构概览

| 模块 | 职责 |
| --- | --- |
| `CmdQInterceptor` | CGEventTap 会话级事件拦截（需辅助功能权限，非沙盒） |
| `HoldEngine` | 纯逻辑按住状态机（可注入时钟，单元测试覆盖） |
| `InterceptPolicy` | 白名单/反转模式决策（纯函数） |
| `OverlayWindowController` | 非激活式倒计时浮层（SwiftUI + NSPanel） |
| `MenuBarController` | 菜单栏图标与菜单 |
| `LoginItemManager` | SMAppService 开机启动 |
| `AppSettings` | UserDefaults 封装（ObservableObject） |

## 设计决策：为什么不发 Mac App Store

**App Store 强制 App Sandbox，而沙盒完全禁止 CGEventTap 事件监听**（即使授予辅助功能权限），
无法实现“按住 ⌘Q”的核心体验 —— 这也是同类工具（Rectangle Pro 之外的大多数键改/慢退类应用）
选择直接分发的原因。经确认，本项目仅提供 **DMG 直发完整版**（Developer ID 签名 + 公证）。
若未来需要上架，可在此基础上增加“沙盒热键版”目标，详见 [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md)。

## 许可

MIT © 2026 MeiQuitManage。行为设计致谢 [SlowQuitApps](https://github.com/dteoh/SlowQuitApps)（GPL-2.0，本项目未复制其代码）。
