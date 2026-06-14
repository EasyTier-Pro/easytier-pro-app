# 桌面端自动更新维护说明

本应用使用 `auto_updater` 接入桌面端自动更新。该插件在 macOS 侧基于 Sparkle，在 Windows 侧基于 WinSparkle，更新源必须是 appcast XML，不是普通的最新版本 JSON。

当前启用 macOS 和 Windows 自动更新。Linux 不在本说明范围内。

## 分发约定

- macOS 首次安装包优先使用 `.dmg`，符合桌面应用安装习惯。
- macOS 自动更新包优先使用 `.zip`，符合 Sparkle 更新包惯例，也便于签名和 appcast 分发。
- Windows 自动更新包使用安装器 `.exe`。
- macOS 与 Windows 可以共用同一个 appcast XML，但不同平台必须使用各自的 `sparkle:os` 和签名字段。

## 运行时配置

客户端内置以下 appcast feed 优先级，启动时会按顺序探测，选中第一个可访问且看起来像 appcast XML 的 feed 后交给 `auto_updater`：

1. Gitee：`https://gitee.com/EasyTier-Pro/easytier-pro-app/releases/download/latest/appcast.xml`
2. OSS：`https://easytier.net/releases/appcast.xml`
3. GitHub：`https://github.com/EasyTier-Pro/easytier-pro-app/releases/latest/download/appcast.xml`

发布构建默认不需要通过 dart-define 配置 appcast 地址：

```bash
flutter build macos --release
```

```powershell
flutter build windows --release
```

如需测试或发布到其他渠道，可以用 `EASYTIER_APPCAST_URLS` 覆盖内置列表。多个 URL 使用分号、逗号、空白或换行分隔，顺序即优先级：

```bash
flutter build macos --release --dart-define=EASYTIER_APPCAST_URLS='https://a.example/appcast.xml;https://b.example/appcast.xml'
```

```powershell
flutter build windows --release --dart-define=EASYTIER_APPCAST_URLS="https://a.example/appcast.xml;https://b.example/appcast.xml"
```

可选配置自动检查间隔，单位为秒：

```bash
flutter build macos --release --dart-define=EASYTIER_UPDATE_CHECK_INTERVAL_SECONDS=3600
```

```powershell
flutter build windows --release --dart-define=EASYTIER_UPDATE_CHECK_INTERVAL_SECONDS=3600
```

说明：

- 所有 appcast feed 都不可访问时，应用会跳过自动更新初始化。
- 客户端只在启动时选择 feed；下载包地址由选中的 appcast 决定，下载失败后不切换到下一个 feed。
- `EASYTIER_UPDATE_CHECK_INTERVAL_SECONDS=0` 表示禁用定时检查，但启动时仍会执行一次后台检查。
- Sparkle/WinSparkle 的检查间隔最小值是 3600 秒；小于 3600 的非 0 值会被应用归一化为 3600。

## macOS EdDSA Key

macOS 更新包必须使用 Sparkle EdDSA key 签名。

本仓库已在 `macos/Runner/Info.plist` 提交：

```xml
<key>SUPublicEDKey</key>
<string>jK9CM/sTpLGHjgWE0faLi4siziuu0uJ3P86goYsTkww=</string>
```

私钥由发布环境安全保存，不能提交到仓库。可以存放在 macOS Keychain 中，也可以导出为私钥文件并在 CI 中通过 secret 注入；如果私钥丢失，密钥轮换能力取决于 Sparkle 配置、更新包类型和 Developer ID 代码签名链，需要发布前用旧版本客户端实测。

首次生成 key：

```bash
flutter pub get
cd macos
pod install
cd ..
dart run auto_updater:generate_keys
```

如果使用私钥文件签名，建议在发布环境使用 Sparkle 2 的 `generate_keys -x private-key-file` 导出私钥，或使用同格式的 Ed25519 seed 文件，并将该文件作为受控 secret 保存。

## macOS Release Entitlements

本应用按非 Mac App Store 方式分发。Sparkle 自更新需要 release 构建关闭 App Sandbox，并允许客户端网络访问。

`macos/Runner/Release.entitlements` 应包含：

```xml
<key>com.apple.security.app-sandbox</key>
<false/>
<key>com.apple.security.network.client</key>
<true/>
```

如果改为 Mac App Store 分发，Sparkle 自动更新方案不适用，需要重新设计分发流程。

## Windows DSA Key

Windows 更新包必须使用 DSA key 签名。

本仓库应提交：

- `dsa_pub.pem`

本仓库绝不能提交：

- `dsa_priv.pem`
- `dsaparam.pem`

根目录 `.gitignore` 已忽略私钥文件。请将 `dsa_priv.pem` 存放在发布环境的安全密钥库或受控机密存储中，并做好备份。如果私钥丢失，已安装客户端将无法验证后续 Windows 更新。

首次生成 key：

```powershell
dart run auto_updater:generate_keys
```

如果本机 `openssl` 不在 `PATH`，先安装 OpenSSL，或临时把 Git for Windows 自带的 OpenSSL 加入 `PATH`：

```powershell
$env:Path = 'C:\Program Files\Git\usr\bin;' + $env:Path
dart run auto_updater:generate_keys
```

生成后确认 `windows/runner/Runner.rc` 包含以下资源配置：

```rc
DSAPub      DSAPEM      "../../dsa_pub.pem"
```

## 密钥轮换发布顺序

更新签名公钥是客户端内置的信任根，不能直接用新私钥签署包含新公钥的第一个版本。正确顺序：

1. 先生成新公私钥，并将新公钥提交到 `macos/Runner/Info.plist` 和 `dsa_pub.pem`。
2. 构建包含新公钥的桥接版本，但 appcast 中的 macOS zip 和 Windows 安装包仍使用旧私钥签名。
3. 已安装客户端用旧公钥验证桥接版本并升级后，客户端才会内置新公钥。
4. 从桥接版本之后的更新开始，再改用新私钥签名。

如果旧 Windows DSA 私钥已经丢失，旧 Windows 客户端无法通过自动更新跨过这次信任根轮换，只能引导用户手动下载安装新版本。macOS 是否能在旧 EdDSA 私钥丢失后继续轮换，取决于 Sparkle 版本、更新包类型、`SUVerifyUpdateBeforeExtraction`/feed 签名配置，以及新旧应用是否使用同一 Developer ID 代码签名；没有完成旧版本客户端验证前，不要依赖该兜底路径。

## macOS 更新包签名

发布 macOS release 后，生成 zip 更新包：

```bash
flutter build macos --release
mkdir -p dist
ditto -c -k --keepParent "build/macos/Build/Products/Release/EasyTier Pro.app" "dist/EasyTierPro-1.0.1-macos.zip"
```

对 zip 更新包签名：

```bash
dart run auto_updater:sign_update --ed-key-file path/to/sparkle_private_key dist/EasyTierPro-1.0.1-macos.zip
```

命令会输出类似内容：

```text
sparkle:edSignature="pbdyPt92..." length="13400992"
```

将 `sparkle:edSignature` 和 `length` 写入 appcast 的 macOS `enclosure` 节点。

## Windows 更新包签名

发布 Windows 安装包后，对安装包签名：

```powershell
dart run auto_updater:sign_update path\to\EasyTierProSetup.exe
```

默认会读取仓库根目录的 `dsa_priv.pem`。如果私钥放在其他位置，传入第二个参数：

```powershell
dart run auto_updater:sign_update path\to\EasyTierProSetup.exe path\to\dsa_priv.pem
```

命令会输出类似内容：

```text
sparkle:dsaSignature="MEUCIQD..." length="0"
```

将 `sparkle:dsaSignature` 写入 appcast 的 Windows `enclosure` 节点。

## GitHub Actions 签名与 Appcast

`Desktop Packages` workflow 会在非 PR 构建中生成自动更新签名和 appcast feed XML。PR 构建不会注入仓库 secrets，因此只打包普通 artifact，不生成带真实签名的 appcast。

需要配置以下 GitHub Actions secrets：

- `MACOS_UPDATE_SPARKLE_PRIVATE_KEY`：Sparkle EdDSA 私钥文件内容，对应 `dart run auto_updater:sign_update --ed-key-file`。
- `WINDOWS_UPDATE_DSA_PRIVATE_KEY`：Windows `dsa_priv.pem` 文件内容。

非 PR 构建会上传 `easytier-pro-appcast` artifact，里面只包含聚合后的 feed XML：

- `appcast-gitee.xml`
- `appcast-oss.xml`
- `appcast-github.xml`
- `appcast.xml`

平台 job 之间会通过 `_easytier-pro-*-appcast-metadata` artifact 传递签名 metadata；这些是短期中间产物，保留 1 天，不需要在发布流程中使用。

发布到不同渠道时，将对应 XML 上传并命名为 `appcast.xml`：

- Gitee release 使用 `appcast-gitee.xml`。
- OSS `https://easytier.net/releases` 使用 `appcast-oss.xml`。
- GitHub release 使用 `appcast-github.xml`；默认 `appcast.xml` 也是 GitHub URL 版本。

如果正在发布包含新公钥的桥接版本，这两个 secrets 仍应填旧私钥；等用户升级到桥接版本后，再把 secrets 切换为新私钥。

## GitHub Draft Release

推送 `v*` tag 会触发 `Desktop Packages` workflow，并在所有桌面产物和 appcast XML 生成后自动创建 GitHub draft release：

```bash
git tag v1.0.0
git push origin v1.0.0
```

draft release job 会检查 tag 版本与 `pubspec.yaml` 的短版本一致。例如 `pubspec.yaml` 为 `version: 1.0.0+1` 时，tag 必须是 `v1.0.0`。不一致会直接失败，避免草稿 release 绑定错误版本。

自动创建的 draft release 会附带公开发布所需的最终产物：

- Windows installer `.exe`
- Windows portable `.zip`
- macOS arm64/x64 `.dmg`
- macOS arm64/x64 `.zip`
- `appcast.xml`、`appcast-gitee.xml`、`appcast-oss.xml`、`appcast-github.xml`

如果同 tag 已存在 draft release 或已发布 release，workflow 会拒绝覆盖。需要重跑生成草稿时，先手动删除已有 draft release，再重新运行 workflow。

## Appcast 示例

macOS 的 `sparkle:version` 应对应 `CFBundleVersion`，建议使用 `pubspec.yaml` 中 `version` 的 build number，例如 `1.0.1+2` 对应 `sparkle:version` 为 `2`，`sparkle:shortVersionString` 为 `1.0.1`。

Windows 的 `sparkle:version` 应与 Windows 构建版本可比较，建议使用完整的 `pubspec.yaml` 版本值，例如 `1.0.1+2`。

```xml
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>EasyTier Pro</title>
    <description>EasyTier Pro desktop releases</description>
    <language>zh-CN</language>
    <item>
      <title>Version 1.0.1 for macOS</title>
      <sparkle:version>2</sparkle:version>
      <sparkle:shortVersionString>1.0.1</sparkle:shortVersionString>
      <sparkle:releaseNotesLink>https://your-domain/path/release-notes.html</sparkle:releaseNotesLink>
      <pubDate>Sun, 07 Jun 2026 12:00:00 +0800</pubDate>
      <enclosure
        url="https://your-domain/path/EasyTierPro-1.0.1-macos.zip"
        sparkle:edSignature="pbdyPt92..."
        sparkle:os="macos"
        length="13400992"
        type="application/octet-stream" />
    </item>
    <item>
      <title>Version 1.0.1 for Windows</title>
      <sparkle:releaseNotesLink>https://your-domain/path/release-notes.html</sparkle:releaseNotesLink>
      <pubDate>Sun, 07 Jun 2026 12:00:00 +0800</pubDate>
      <enclosure
        url="https://your-domain/path/EasyTierProSetup-1.0.1.exe"
        sparkle:dsaSignature="MEUCIQD..."
        sparkle:version="1.0.1+2"
        sparkle:os="windows"
        length="0"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
```

注意事项：

- `url` 必须是客户端可访问的更新包地址。
- macOS 必须使用 `sparkle:edSignature`，Windows 必须使用 `sparkle:dsaSignature`。
- macOS 必须使用 `sparkle:os="macos"`，Windows 必须使用 `sparkle:os="windows"`。
- macOS 自动更新包建议使用签名后的 `.zip`；首次安装包可以另行提供 `.dmg`。
- 如果控制台要托管 appcast，应新增或适配专门的 appcast 输出，不要直接复用 `/api/v1/releases/latest` 的普通 JSON。

## 本地验证

可以先用本地 HTTP 服务托管 appcast 和更新包：

```bash
flutter build macos --release --dart-define=EASYTIER_APPCAST_URLS=http://127.0.0.1:5002/appcast.xml
```

```powershell
flutter build windows --release --dart-define=EASYTIER_APPCAST_URLS=http://127.0.0.1:5002/appcast.xml
```

启动静态文件服务：

```bash
cd dist
python -m http.server 5002
```

验证时请确认：

- 当前安装版本低于 appcast 中的平台版本。
- appcast XML 可以被客户端访问。
- 更新包 URL 可以被客户端下载。
- macOS zip 的 `sparkle:edSignature` 与 `SUPublicEDKey` 匹配。
- Windows 安装包签名与 `dsa_pub.pem` 匹配。
- `windows/runner/Runner.rc` 中的 `DSAPub` 资源已进入最终 exe。

## 发布检查清单

每次发布前检查：

- GitHub Actions 的 `Desktop Packages` workflow 已为 Windows 生成 Inno Setup `.exe` 安装器和 portable zip，为 macOS 生成 `.dmg` 与 `.zip` artifact，并在非 PR 构建中生成自动更新签名和 appcast XML。
- `pubspec.yaml` 的 `version` 已更新。
- 如需自动生成 GitHub draft release，推送的 tag 已匹配 `pubspec.yaml` 短版本，例如 `version: 1.0.0+1` 对应 `v1.0.0`。
- 如果发布渠道不同于内置 feed 列表，使用正确的 `EASYTIER_APPCAST_URLS` 构建 release 包。
- macOS release 构建已完成签名和 notarization。
- `easytier-pro-appcast` artifact 中的 XML 已匹配本次要发布的渠道。
- appcast 已按 Gitee、OSS、GitHub 优先级发布，且更新包均已上传到 HTTPS 可访问地址。
- 不要提交或上传任何私钥到公开位置。
