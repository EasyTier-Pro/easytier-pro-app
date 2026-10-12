# EasyTier Pro App

EasyTier Pro App 是 EasyTier Pro 的跨平台客户端，用于把桌面和移动设备接入已授权的零信任网络。它负责登录控制台、选择工作区与网络、启动本机 EasyTier runtime、展示节点状态与路由信息，并在支持的平台上提供自动更新和系统集成。

本仓库只包含客户端应用层。控制台、设备生命周期、策略编排等后端能力由 EasyTier Pro 控制台提供；隧道、组网、路由和数据面能力由 EasyTier core 提供。

## 功能概览

- 控制台登录、设备授权和本地登录态保存。
- 工作区、网络、设备和节点状态展示。
- 加入或断开已授权网络，查看虚拟 IP、路由、流量和连接状态。
- Windows 和 macOS 桌面客户端随包携带 `easytier-pro-installer`，用于安装和管理本机 EasyTier runtime。
- Android 客户端通过系统 `VpnService` 建立可见 VPN 连接，把授权网络和子网路由交给 EasyTier 处理。
- iOS 客户端通过独立 Packet Tunnel 扩展运行 EasyTier，支持应用退到后台后继续连接。
- 桌面端使用 `auto_updater` 接入自动更新；macOS 使用 Sparkle appcast，Windows 使用 WinSparkle appcast。
- 诊断日志覆盖认证、控制面连接、runtime 启停、VPN 授权、路由下发和更新检查等关键路径。

## 下载

正式构建会发布到以下位置：

- GitHub Releases: <https://github.com/EasyTier-Pro/easytier-pro-app/releases>
- Gitee Releases: <https://gitee.com/EasyTier-Pro/easytier-pro-app/releases>

常见发布产物：

- Windows: `easytier-pro-windows-x64-setup-*.exe` 和 `easytier-pro-windows-x64.zip`
- macOS: `easytier-pro-macos-arm64.dmg`、`easytier-pro-macos-x64.dmg` 以及 Sparkle 更新用 `.zip`
- Android: `easytier-pro-android-arm64-v8a.apk` 和 `easytier-pro-android-x86_64.apk`

macOS 首次安装的 `.dmg` 需要完整的 Apple Developer ID 代码签名、公证和 stapling，才能在普通浏览器下载后稳定通过 Gatekeeper。Sparkle 的 EdDSA 签名只用于自动更新包校验，不能替代 Apple 的签名与公证。

## 开发环境

基础依赖：

- Flutter stable，包含匹配的 Dart SDK。
- Windows 桌面开发需要 Visual Studio Build Tools 和 Windows 桌面组件。
- macOS 桌面开发需要 Xcode、CocoaPods 和可用的 macOS runner 环境。
- Android 开发需要 Android SDK、Android NDK 和 JDK 17。
- 如需重建随包 installer 或 EasyTier JNI/core，需要 Rust toolchain 和对应 target。

安装依赖：

```bash
flutter pub get
```

静态分析和测试：

```bash
dart analyze
flutter test
```

本地运行：

```bash
flutter run -d windows
flutter run -d macos
flutter run -d android
```

## 构建

桌面 release 构建：

```bash
flutter build macos --release
flutter build windows --release
```

Android release 构建：

```bash
flutter build apk --release --target-platform android-arm64,android-x64 --split-per-abi
```

仓库内提供了一组发布辅助脚本：

- `scripts/package_windows_installer.ps1` 生成 Windows 安装器。
- `scripts/package_macos_dmg.sh` 生成 macOS `.dmg`。
- `scripts/package_android_release_apks.ps1` 整理 Android split APK。
- `scripts/generate_appcast.dart` 生成桌面自动更新使用的 appcast XML。
- `scripts/verify_android_release_inputs.ps1` 和 `scripts/verify_android_porting_readiness.ps1` 用于 Android 发布前检查。

更完整的说明见 [桌面自动更新](docs/auto-update-desktop.md)、[Android 发布](docs/android-release.md) 与 [iOS 开发与验证](docs/ios-development.md)。

## 自动更新

桌面端内置 appcast feed 优先级：

1. Gitee: `https://gitee.com/EasyTier-Pro/easytier-pro-app/releases/download/latest/appcast.xml`
2. OSS: `https://easytier.net/releases/appcast.xml`
3. GitHub: `https://github.com/EasyTier-Pro/easytier-pro-app/releases/latest/download/appcast.xml`

如需在测试环境覆盖 feed，可以在构建时传入：

```bash
flutter build macos --release --dart-define=EASYTIER_APPCAST_URLS=https://example.com/appcast.xml
flutter build windows --release --dart-define=EASYTIER_APPCAST_URLS=https://example.com/appcast.xml
```

多个 URL 可以使用分号、逗号、空白或换行分隔。客户端启动时会探测并选择第一个可访问且看起来像 appcast XML 的 feed。

## 发布流程

推送 `vX.Y.Z` tag 会触发 `Desktop Packages` workflow。workflow 会构建 Windows、macOS、Android 产物，生成 appcast XML，并创建 GitHub draft release。

```bash
git tag v1.0.7
git push origin v1.0.7
```

发布前请确认：

- `pubspec.yaml` 中的短版本号与 tag 一致。
- Windows installer、Windows portable zip、macOS `.dmg`、macOS `.zip`、Android APK 和 appcast XML 都已生成。
- macOS 正式分发包已经完成 Developer ID 签名、公证和 stapling。
- appcast 中的下载 URL 指向对应发布渠道，并且所有文件都可以通过 HTTPS 下载。
- 私钥、keystore、notarization 凭据和生产环境密钥没有提交到仓库。

## 仓库结构

```text
lib/        Flutter 应用代码
android/    Android runner、VpnService 与 JNI 集成
ios/        iOS runner、Packet Tunnel 扩展与共享 Keychain
macos/      macOS runner 与 Sparkle 配置
windows/    Windows runner、安装器资源与 WinSparkle 配置
linux/      Linux runner
assets/     图标、图片和字体资源
docs/       发布、自动更新和 Android 移植说明
scripts/    构建、打包、签名和验证脚本
test/       Dart 单元测试与 widget 测试
```

## 相关项目

- EasyTier core: <https://github.com/EasyTier/EasyTier>
- EasyTier Pro installer: <https://github.com/EasyTier-Pro/installer>
- EasyTier Pro console: <https://github.com/EasyTier-Pro/easytier-console>
- 控制台: <https://console.easytier.net/>

## 许可证

EasyTier Pro App 使用 GNU Affero General Public License v3.0 发布。详见 [LICENSE](LICENSE)。

第三方依赖、字体、图标和平台 SDK 仍遵循其各自的许可证。
