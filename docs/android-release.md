# Android 发布准备说明

本文档记录 EasyTier Pro Android 构建发布前需要完成的本地配置、验证步骤和权限说明。密钥、生产地址和渠道专用配置不应提交到仓库。

## Release 签名

Android 正式安装身份为 `net.easytier.pro`。当前 Kotlin `namespace` 仍保留在 `com.example.easytier_pro_app`，仅作为源码命名空间；应用商店包身份、安装升级路径和系统 VPN 归属以 `applicationId` 为准。

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
flutter build apk --release --split-per-abi
flutter build appbundle --release
```

`flutter build apk --release --split-per-abi` 和 `flutter build appbundle --release` 必须在签名配置存在后执行。

## ABI 与 JNI

Android MVP 当前随包包含：

- `arm64-v8a`
- `x86_64`

这分别覆盖主流真机和本地 Android emulator。发布前应先运行 JNI 构建脚本，确认 `android/app/src/main/jniLibs/<abi>/libeasytier_android_jni.so` 已更新到目标 EasyTier commit。

```powershell
.\scripts\build_android_jni.ps1
flutter build apk --debug
```

Release APK 构建会启用 ABI split，只产出 `arm64-v8a` 和 `x86_64` 包；debug 构建保持单包，方便 `flutter run` 和本地模拟器调试。不要把未包含 JNI 的 ABI 发布给用户。

## CI

`.github/workflows/android.yml` 会在 Windows runner 上检出 EasyTier 固定 commit，安装 Android NDK `28.2.13676358`，执行 `scripts/build_android_jni.ps1 -SkipCopy` 验证 JNI 可构建，并构建 Android debug APK。CI 当前不改写仓库内已提交的 `.so` 文件；更新随包 JNI 产物仍需在本地运行构建脚本并提交结果。

## VPN 权限与后台运行说明

Android 客户端通过 `VpnService` 创建系统 VPN interface，并把 TUN fd 注入 EasyTier core。应用需要向用户说明：

- EasyTier Pro 会创建一个用户可见的 VPN 连接，用于接入已授权的零信任网络。
- Android config server client 由原生前台 `VpnService` 启动并保持运行，Flutter 负责发起启动/停止命令和展示状态。
- 原生服务事件会在 Flutter `EventChannel` 暂未监听时短暂缓存，避免回前台或 engine 重建期间丢失 config server/VPN 状态事件。
- Android VPN 会从 `my_node_info.virtual_ipv4` 派生虚拟网自身路由，并从 `routes[].proxy_cidrs` 下发子网路由。
- Android 节点运行态会从 `my_node_info`、`routes` 和 `peer_route_pairs` 映射到现有 peer/status 展示模型。
- Android 运行态信息轮询采用 15 秒间隔和 15 秒 `collectNetworkInfos` 缓存，降低 JNI 轮询压力；JNI 返回字符串释放仍应在 EasyTier Android JNI 源侧确认或修复。
- 已登录且运行中的 Android runtime 收到 `config_server_stopped` 事件时会自动重新连接；退出登录和工作区重建期间不会被该事件反向拉起。
- workspace 切换会强制重建 runtime；如果当前账号失去 workspace 绑定，会先停止 runtime，避免继续保持旧 workspace 的控制面/VPN 连接。
- 本地 token 过期或控制台 bootstrap 返回 401/403 时会停止 runtime，并提示用户重新登录，避免旧控制面/VPN 连接继续运行。
- VPN 会通过 `addDisallowedApplication(packageName)` 排除 EasyTier Pro 自身，避免控制面连接和 EasyTier 底层传输被自己的 VPN 路由回环。
- VPN 连接会显示常驻通知；用户可以点击通知返回应用，也可以通过通知动作、系统 VPN 设置或应用内退出/断开操作停止连接。
- 应用不会在客户端硬编码只适用于生产环境的控制面地址；控制台和本地 E2E 环境应继续通过上层配置或控制台接口提供。
- Android 13+ 需要通知权限；拒绝通知权限不应绕过 VPN 授权流程。

## 发布前验证

最小验证清单：

- `dart analyze`
- `flutter test`
- `flutter build apk --debug`
- `flutter build apk --release --split-per-abi`
- `flutter build appbundle --release`
- Android emulator 或真机登录控制台。
- 完成 VPN 授权。
- 控制台下发 `run_network_instance` 后，日志出现 `vpn_started` 或 native `Injected TUN fd`。
- 退出登录后，config server client 和 VPN 均停止。

仍需产品确认：

- 上传签名证书归属和保管流程。
- 国内渠道 VPN 权限说明文案。
- Android 流量统计是继续弱化展示，还是等待 EasyTier JNI 暴露等价 stats API。
