# Android 发布准备说明

本文档记录 EasyTier Pro Android 构建发布前需要完成的本地配置、验证步骤和权限说明。密钥、生产地址和渠道专用配置不应提交到仓库。

## Release 签名

Release 构建读取 `android/key.properties`。该文件已被 `android/.gitignore` 忽略，禁止提交。

示例：

```properties
storeFile=../keystores/easytier-pro-upload.jks
storePassword=<store-password>
keyAlias=easytier-pro
keyPassword=<key-password>
```

说明：

- `storeFile` 相对 `android/` 目录解析，也可以使用绝对路径。
- 未提供 `android/key.properties` 时，release 构建会失败；release 变体不会使用 debug key 签名。
- Debug 构建不依赖该文件。

常用命令：

```powershell
flutter build apk --debug
flutter build apk --release
flutter build appbundle --release
```

`flutter build apk --release` 和 `flutter build appbundle --release` 必须在签名配置存在后执行。

## ABI 与 JNI

Android MVP 当前随包包含：

- `arm64-v8a`
- `x86_64`

这分别覆盖主流真机和本地 Android emulator。发布前应先运行 JNI 构建脚本，确认 `android/app/src/main/jniLibs/<abi>/libeasytier_android_jni.so` 已更新到目标 EasyTier commit。

```powershell
.\scripts\build_android_jni.ps1
flutter build apk --debug
```

正式渠道包如需进一步降低包体积，可以使用 Flutter/Gradle 的 ABI split 或按渠道分别产出 ABI 包；不要把未包含 JNI 的 ABI 发布给用户。

## VPN 权限与后台运行说明

Android 客户端通过 `VpnService` 创建系统 VPN interface，并把 TUN fd 注入 EasyTier core。应用需要向用户说明：

- EasyTier Pro 会创建一个用户可见的 VPN 连接，用于接入已授权的零信任网络。
- VPN 连接会显示常驻通知；用户可以点击通知返回应用，也可以通过通知动作、系统 VPN 设置或应用内退出/断开操作停止连接。
- 应用不会在客户端硬编码只适用于生产环境的控制面地址；控制台和本地 E2E 环境应继续通过上层配置或控制台接口提供。
- Android 13+ 需要通知权限；拒绝通知权限不应绕过 VPN 授权流程。

## 发布前验证

最小验证清单：

- `dart analyze`
- `flutter test`
- `flutter build apk --debug`
- `flutter build apk --release`
- Android emulator 或真机登录控制台。
- 完成 VPN 授权。
- 控制台下发 `run_network_instance` 后，日志出现 `vpn_started` 或 native `Injected TUN fd`。
- 退出登录后，config server client 和 VPN 均停止。

仍需产品确认：

- 正式 `applicationId`。
- 上传签名证书归属和保管流程。
- 国内渠道 VPN 权限说明文案。
- Android 流量统计是继续弱化展示，还是等待 EasyTier JNI 暴露等价 stats API。
