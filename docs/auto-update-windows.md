# Windows 自动更新维护说明

本应用使用 `auto_updater` 接入 Windows 自动更新。该插件在 Windows 侧基于 WinSparkle，更新源必须是 appcast XML，不是普通的最新版本 JSON。

当前只启用 Windows 自动更新。macOS 和 Linux 不在本说明范围内。

## 运行时配置

发布构建需要通过 dart-define 配置 appcast 地址：

```powershell
flutter build windows --release --dart-define=EASYTIER_APPCAST_URL=https://your-domain/path/appcast.xml
```

可选配置自动检查间隔，单位为秒：

```powershell
flutter build windows --release --dart-define=EASYTIER_APPCAST_URL=https://your-domain/path/appcast.xml --dart-define=EASYTIER_UPDATE_CHECK_INTERVAL_SECONDS=3600
```

说明：

- `EASYTIER_APPCAST_URL` 为空时，应用会跳过自动更新初始化。
- `EASYTIER_UPDATE_CHECK_INTERVAL_SECONDS=0` 表示禁用定时检查，但启动时仍会执行一次后台检查。
- WinSparkle 的检查间隔最小值是 3600 秒；小于 3600 的非 0 值会被应用归一化为 3600。

## DSA Key

Windows 更新包必须使用 DSA key 签名。

本仓库应提交：

- `dsa_pub.pem`

本仓库绝不能提交：

- `dsa_priv.pem`
- `dsaparam.pem`

根目录 `.gitignore` 已忽略私钥文件。请将 `dsa_priv.pem` 存放在发布环境的安全密钥库或受控机密存储中，并做好备份。如果私钥丢失，已安装客户端将无法验证后续更新。

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

## 签名发布包

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

## Appcast 示例

`sparkle:version` 应与 Windows 构建版本可比较。建议使用 `pubspec.yaml` 的 `version` 值，例如 `1.0.0+1`。

```xml
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>EasyTier Pro</title>
    <description>EasyTier Pro Windows releases</description>
    <language>zh-CN</language>
    <item>
      <title>Version 1.0.1</title>
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

- `url` 必须是客户端可访问的安装包地址。
- `sparkle:dsaSignature` 必须来自对应安装包和当前私钥。
- `sparkle:os="windows"` 必须保留。
- 如果控制台要托管 appcast，应新增或适配专门的 appcast 输出，不要直接复用 `/api/v1/releases/latest` 的普通 JSON。

## 本地验证

可以先用本地 HTTP 服务托管 appcast 和安装包：

```powershell
flutter build windows --release --dart-define=EASYTIER_APPCAST_URL=http://127.0.0.1:5002/appcast.xml
```

启动静态文件服务：

```powershell
cd dist
python -m http.server 5002
```

验证时请确认：

- 当前安装版本低于 appcast 中的 `sparkle:version`。
- appcast XML 可以被客户端访问。
- 安装包 URL 可以被客户端下载。
- 安装包签名与 `dsa_pub.pem` 匹配。
- `windows/runner/Runner.rc` 中的 `DSAPub` 资源已进入最终 exe。

## 发布检查清单

每次发布前检查：

- `pubspec.yaml` 的 `version` 已更新。
- 使用正确的 `EASYTIER_APPCAST_URL` 构建 release 包。
- 使用受控的 `dsa_priv.pem` 对安装包签名。
- appcast 中的 `sparkle:version`、`url`、`sparkle:dsaSignature` 已更新。
- appcast 和安装包均已上传到 HTTPS 可访问地址。
- 不要提交或上传 `dsa_priv.pem` 到公开位置。
