# 分发与签名指南

## 当前状态

- DMG 内的 `MeiQuitManage.app` 为 **ad-hoc 签名**（Hardened Runtime 已开启）。
  本机自用没问题；分发给其他用户时 Gatekeeper 会拦截，需要用户右键打开或在
  系统设置中放行。
- 本机钥匙串当前**没有 Developer ID 证书**。正式分发按下面步骤补齐即可，
  应用代码无需任何改动。

## 正式分发（Developer ID + 公证）

### 1. 创建证书（一次性）

1. 在 https://developer.apple.com/account → Certificates → "+" 创建：
   - `Developer ID Application` 证书（签名用）
   - `Apple Worldwide Developer Relations (WWDR)` 中间证书一般会自动获得
2. Xcode → Settings → Accounts → 你的团队 → Manage Certificates → 导入，
   或直接双击 `.p12` 导入登录钥匙串。
3. 验证：`security find-identity -v -p codesigning` 应出现
   `"Developer ID Application: YOUR NAME (TEAMID)"`。

### 2. 签名 + 公证 + 打 DMG

```bash
export SIGN_IDENTITY="Developer ID Application: YOUR NAME (TEAMID)"
export SIGN_TEAM="TEAMID"

# 方式 A：公证凭据用 App Store Connect API Key（推荐，CI 友好）
#   在 appstoreconnect.apple.com → Users and Access → Integrations → Team Keys 创建
export NOTARY_PROFILE="notary-meiquit"   # xcrun notarytool store 的 profile 名
xcrun notarytool store-credentials "$NOTARY_PROFILE" \
  --key AuthKey_XXXXXXXXXX.p8 --key-id KEYID --issuer ISSUER

./scripts/sign_and_notarize.sh
```

脚本做的事：Release 构建 → Developer ID 签名 → `notarytool submit` 公证 →
`stapler` 装订 → 打 DMG → 签名 DMG。产物在 `dist/`。

（方式 B：用 Apple ID 双因子公证：`xcrun notarytool store-credentials
meiquit --apple-id you@example.com --team-id TEAMID --password app-specific-password`）

### 3. 分发校验

```bash
spctl -a -t exec --verbose=4 dist/MeiQuitManage-1.0.0.dmg/MeiQuitManage.app  # 应显示 accepted
xcrun notarytool history --keychain-profile notary-meiquit
```

## 为什么没有 Mac App Store 版本（决策记录）

- App Store 强制 **App Sandbox**；沙盒环境下 `CGEvent.tapCreate` 无法创建
  （即使授予辅助功能权限也不行），而事件监听是“按住 ⌘Q”体验的核心。
- 用户已确认：本项目只做 **DMG 完整版**，放弃 MAS 上架。

若将来要恢复上架，技术路径（保留在本仓库的扩展点）：

1. `InterceptPolicy`/`HoldEngine` 均为纯逻辑，可直接复用；
2. 新增 "MeiQuitManageLite" 沙盒 target：用 Carbon `RegisterEventHotKey`
   注册 ⌘Q 热键（沙盒允许），按住检测依赖按键 auto-repeat 信号推断；
3. 退出动作改用 Apple Event + `NSAppleEventsUsageDescription`（带用户授权弹窗）；
4. 该版本无法 100% 复刻 keyUp 精确检测，体验有损 —— 这正是当初放弃的原因。

## 关键命令速查

```bash
# 构建
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project MeiQuitManage.xcodeproj -scheme MeiQuitManage \
  -configuration Release -derivedDataPath build/DerivedData build

# 测试
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project MeiQuitManage.xcodeproj -scheme MeiQuitManage \
  -configuration Debug -derivedDataPath build/DerivedData test

# 打 DMG（不签名，快速验证）
./scripts/make_dmg.sh
```
