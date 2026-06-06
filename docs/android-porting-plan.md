# Android 移植可行性与实现方案

本文记录基于上游 EasyTier Android JNI 与 config server client 能力，将 EasyTier Pro Flutter 客户端移植到 Android 平台的调研结论与实施方案。

调研日期：2026-06-06

## 结论

Android 移植可行。上游 EasyTier 已经提供 JNI 层的 config server client、网络实例管理、运行信息采集和 TUN fd 注入能力，可以支撑 Android 客户端不再依赖 `easytier-cli` 或桌面 installer，而是通过 Android 原生层直接运行 EasyTier core。

但这不是简单启用 Flutter Android 构建。当前本应用的核心生命周期是桌面模型，主要依赖 `Process.start` 调用 `easytier-pro-installer` 和 `easytier-cli`。Android 需要新增一套运行时后端：

```text
Flutter Dart
  -> CoreLifecycleService
  -> Android runtime bridge
  -> MethodChannel / EventChannel
  -> Kotlin bridge
  -> EasyTier Android JNI
  -> Android VpnService
```

建议 MVP 目标定义为：

- 复用现有控制台登录和 enrollment 流程。
- Android 端通过 JNI 连接 config server。
- 支持一个活跃 VPN 网络实例。
- 能展示基础连接状态、节点状态和路由/peer 信息。
- 桌面端现有 installer/CLI 路径保持不变。

完整桌面能力对齐需要额外处理多网络、流量统计、后台保活、Android 权限合规、ABI 构建和发布签名等问题。

## 事实来源

### 本应用

- `android/` 目录已存在，但仍接近 Flutter 模板工程。
- `android/app/src/main/kotlin/com/example/easytier_pro_app/MainActivity.kt` 当前仅继承 `FlutterActivity`。
- `android/app/src/main/AndroidManifest.xml` 当前没有声明 VPN service、foreground service 等 Android 网络运行所需组件。
- `lib/src/core/core_lifecycle_service.dart` 当前使用桌面 installer/CLI 管理 EasyTier core。
- `lib/src/auth/console_auth_http_service.dart` 当前负责获取 release、config server base URL、device enrollment key 和 bootstrap token。

### EasyTier core

调研时上游 EasyTier master 最新提交为：

```text
13f2ebfe12f9a0a0d8294dbe325503da62381a40
feat(ffi): add config server client bindings (#2320)
```

关键文件：

- `easytier-contrib/easytier-android-jni/kotlin/com/easytier/jni/EasyTierJNI.kt`
- `easytier-contrib/easytier-android-jni/src/lib.rs`
- `easytier-contrib/easytier-android-jni/src/config_server_api.rs`
- `easytier-contrib/easytier-android-jni/src/network_api.rs`
- `easytier-contrib/easytier-ffi/src/config_server.rs`
- `easytier/src/web_client/mod.rs`
- `easytier/src/common/machine_id.rs`
- `easytier/src/proto/api_manage.proto`

上游 JNI 当前提供的关键接口包括：

```kotlin
EasyTierJNI.startConfigServerClient(url, hostname, machineId, secureMode, callback)
EasyTierJNI.stopConfigServerClient()
EasyTierJNI.isConfigServerClientConnected()
EasyTierJNI.setTunFd(instanceName, fd)
EasyTierJNI.retainNetworkInstance(instanceNames)
EasyTierJNI.collectNetworkInfos(maxLength)
EasyTierJNI.getLastError()
```

### 中心控制台

调研时中心控制台仓库提交为：

```text
76676a855fc8f6a63df4e8d1ed4e6eaab2d107f7
fix(console): keep validate-token config build alive
```

关键事实：

- `/api/v1/releases/latest` 返回 `web_config_server_url`。
- device enrollment key 创建和查询接口会提供 `bootstrap_token`。
- 控制台生成 EasyTier config server 命令时使用的格式是：

```text
<config_server_base>/<bootstrap_token>
```

因此 Android 调用 `startConfigServerClient` 时也应传完整 URL，不能只传 base URL。

### Android 平台

Android VPN 能力必须通过 `android.net.VpnService` 获取用户授权并建立 VPN interface。建立成功后，应用获得 TUN fd，再通过 `EasyTierJNI.setTunFd(instanceName, fd)` 交给 EasyTier core。

参考：

- Android `VpnService`: https://developer.android.com/reference/android/net/VpnService
- Android `VpnService.Builder`: https://developer.android.com/reference/android/net/VpnService.Builder
- Flutter platform channels: https://docs.flutter.dev/platform-integration/platform-channels

## 当前应用现状

### 可复用能力

- Flutter 页面、状态模型和控制台认证流程可以继续作为上层应用逻辑。
- `ConsoleAuthHttpService.prepareCoreBootstrap` 已经能获取：
  - EasyTier release version
  - `web_config_server_url`
  - bootstrap token
- 桌面 tray 和 window manager 逻辑已经有平台判断，不应进入 Android 路径。

### 需要替换的桌面假设

当前 `CoreLifecycleService` 中有大量桌面运行时假设：

- 使用 `Process.start` 执行 `easytier-pro-installer`。
- 使用 `easytier-cli status/install/stats/node info/peer` 读取运行状态。
- Windows 修复路径依赖 PowerShell 和管理员权限。
- CLI 路径解析依赖桌面 bundle 或系统安装目录。

这些能力在 Android 上不能直接使用，需要抽象成平台运行时。

## 上游 JNI 能力分析

### config server client

上游 FFI/JNI 已支持启动 config server client。它会连接控制台提供的 config server，并根据控制面下发的配置管理网络实例。

关键约束：

- `machineId` 不能为空。
- Android 上必须显式传入 `machineId`，不能依赖默认 state dir。
- config server URL 最后一个 path segment 必须是 token。
- callback 会上报 `run_network_instance` 和 `delete_network_instance` 事件。
- config server client 与部分 FFI data-plane 管理能力存在互斥关系，Android app 应优先走 config server client 模式。

### TUN fd 注入

Android VPN interface 由 app 通过 `VpnService.Builder.establish()` 创建。创建后获得的 fd 需要传给 EasyTier：

```kotlin
EasyTierJNI.setTunFd(instanceName, fd)
```

上游 mobile launcher 会等待 TUN fd 并使用该 fd 构建 mobile 虚拟网卡上下文。

### 运行信息采集

`collectNetworkInfos(maxLength)` 返回网络实例运行信息的 JSON。该信息来自 `NetworkInstanceRunningInfoMap`，可以用于实现：

- 网络实例是否 running
- 当前节点信息
- peer 列表
- route 列表
- peer-route pair
- 错误信息

当前应用构建脚本会在构建固定 EasyTier Android JNI commit 前临时应用本地补丁，确保 `collectNetworkInfos` 读取 FFI 返回的 key/value 后调用 `free_string` 释放字符串，再构建随包 `.so`。该事实来源属于 EasyTier Android JNI 源侧；上游合并等价修复后可移除本地补丁。

## 推荐架构

新增平台运行时抽象，将核心生命周期从具体运行方式中解耦：

```text
CoreLifecycleService
  -> CorePlatformRuntime
      -> DesktopCoreRuntime
          -> easytier-pro-installer
          -> easytier-cli
      -> AndroidCoreRuntime
          -> MethodChannel / EventChannel
          -> Kotlin EasyTierBridge
          -> EasyTierJNI
          -> EasyTierVpnService
```

建议 Dart 接口覆盖当前业务实际需要的能力：

```dart
abstract interface class CorePlatformRuntime {
  Future<void> ensureRunning(CoreBootstrapConfig bootstrap);
  Future<void> stop();
  Future<bool> isConfigServerConnected();
  Future<CoreTrafficTotals?> readTrafficTotals();
  Future<bool> isNetworkInstanceRunning(String instanceName);
  Future<List<CorePeerStatus>> readPeerStatuses(String instanceName);
  Stream<CoreRuntimeEvent> get events;
}
```

桌面端实现保留现有 CLI/installer 行为。Android 端实现通过 channel 调用 Kotlin。

## Android 实现方案

### 1. 原生桥接层

在 Android 工程中新增 Kotlin bridge，负责：

- 加载 `libeasytier_android_jni.so`。
- 暴露 MethodChannel 命令。
- 通过 EventChannel 推送 config server callback 和 VPN 状态。
- 管理 `VpnService.prepare()` 的授权流程。
- 管理 `VpnService` 的启动、停止和 fd 生命周期。

建议暴露的方法：

```text
startConfigServerClient(url, hostname, machineId, secureMode)
stopConfigServerClient()
isConfigServerClientConnected()
collectNetworkInfos(maxLength)
retainNetworkInstance(instanceNames)
prepareVpn()
startVpn(instanceName, vpnConfig)
stopVpn()
getLastError()
```

### 2. machineId 策略

Android 上使用 `SharedPreferences` 持久化一个随机 UUID 作为设备级 machine id。

要求：

- 安装后首次启动生成。
- 后续启动保持稳定。
- 用户清除应用数据后允许重新生成。
- 不使用 IMEI、Android ID 等敏感或不稳定标识作为默认值。

### 3. config server URL 拼接

Dart 层从控制台拿到：

- `configServer`
- `bootstrapToken`

Android runtime 启动前拼接：

```text
configServer.trimRight("/") + "/" + Uri.encodeComponent(bootstrapToken)
```

需要兼容：

- `tcp://host:22020`
- `tcp://host:22020/`
- `tcp://host:22020/base-path`
- 本地 E2E 和线上环境

不要把生产地址硬编码进 Android 原生层。

### 4. VPN 生命周期

推荐流程：

1. Dart 调用 `prepareCoreBootstrap`。
2. Android runtime 调用 `startConfigServerClient(fullUrl, hostname, machineId, true)`。
3. Kotlin 收到 `run_network_instance` callback。
4. Kotlin 或 Dart 调用 `collectNetworkInfos` 获取实例、虚拟 IP、路由和 DNS。
5. 若尚未授权 VPN，Dart 展示需要授权状态并触发 `VpnService.prepare()`。
6. 授权后启动 `EasyTierVpnService`。
7. `VpnService.Builder.establish()` 成功后获得 fd。
8. 调用 `EasyTierJNI.setTunFd(instanceName, fd)`。
9. 实例状态变更或路由变化时刷新 VPN。
10. 退出登录或停止连接时，先 stop config server client，再 stop VPN。

### 5. Android manifest 和权限

需要在 Android manifest 中增加：

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />

<service
    android:name=".EasyTierVpnService"
    android:permission="android.permission.BIND_VPN_SERVICE"
    android:exported="false">
    <intent-filter>
        <action android:name="android.net.VpnService" />
    </intent-filter>
</service>
```

Android 14 及以上还需要根据 target SDK 和实际 foreground service 类型补齐声明，并准备面向应用商店审核的 VPN 使用说明。

### 6. ABI 与 native library

上游 Android JNI README 声明支持：

- `arm64-v8a`
- `armeabi-v7a`
- `x86`
- `x86_64`

但调研时上游 `build.sh` 默认只构建 `arm64-v8a`。建议：

- MVP 先支持真实设备主流 ABI：`arm64-v8a`。
- 调试模拟器补充 `x86_64`。
- 正式发布使用 ABI split 降低包体积。
- CI 中固定 Rust、Android NDK、`cargo-ndk` 和 EasyTier commit。

## 功能适配策略

### MVP 支持范围

- 登录控制台。
- 获取 workspace 和 device enrollment bootstrap token。
- 启动 Android config server client。
- 请求 VPN 授权。
- 建立一个活跃 VPN 网络实例。
- 展示连接状态、基础 peer 状态和错误信息。
- 退出登录时停止 config server client 和 VPN。

### 延后处理范围

- 多网络实例同时在线。
- 与桌面完全一致的流量统计。
- 高级路由诊断。
- Android 后台长期保活的精细策略。
- 国内应用商店多渠道合规文案。

## 风险与待确认问题

### 上游 JNI 稳定性

JNI config server client 能力非常新，应固定到明确 commit，并准备本地补丁或上游 PR。

### collectNetworkInfos 轮询

JNI 层释放 FFI 返回字符串的问题已通过本仓库 JNI 构建脚本的本地补丁处理；Android 首页仍不应高频轮询该接口，当前实现采用 15 秒运行态轮询和 15 秒 `collectNetworkInfos` 缓存，VPN 路由刷新仅在启动后短时加速。

### 单 VPN 接口限制

Android 系统模型更接近一个 app 一个活跃 VPN interface。桌面端如果允许多个网络实例并行，Android MVP 应先限制为一个活跃网络，或由控制台/核心侧明确提供路由合并方案。

### 流量统计差异

当前桌面端通过 `easytier-cli stats` 获取流量统计。JNI `collectNetworkInfos` 不一定提供完全等价数据。可选方案：

- MVP 阶段隐藏或弱化 Android 流量图。
- 从 peer connection stats 派生近似值。
- 新增 EasyTier FFI/JNI stats API，保持与 CLI 输出一致。

推荐正式版采用第三种。

### Android 后台与权限合规

需要处理：

- VPN 用户授权。
- Android 13+ 通知权限。
- Android 14 foreground service 类型。
- VPN 常驻通知。
- 用户明确可见的连接/断开控制。
- 不在客户端硬编码只适用于生产的控制面地址。

## 实施阶段

### Phase 0: 技术 spike

目标：验证 JNI 在 Flutter Android debug 包中可用。

任务：

- 构建上游 `libeasytier_android_jni.so` 和依赖库。
- 放入 `android/app/src/main/jniLibs/<abi>/`。
- 增加最小 MethodChannel。
- 验证 `System.loadLibrary`、`isConfigServerClientConnected`、`getLastError`。
- 使用本地 E2E 控制台验证 `startConfigServerClient` 和 callback。

### Phase 1: MVP 连接闭环

目标：Android 设备可以通过控制台下发配置并建立 VPN。

任务：

- 新增 `CorePlatformRuntime` 抽象。
- 拆出 `DesktopCoreRuntime`。
- 实现 `AndroidCoreRuntime`。
- 持久化 Android `machineId`。
- 拼接完整 config server URL。
- 实现 VPN 授权和 `setTunFd`。
- 首页展示 Android 运行状态。

### Phase 2: 体验和稳定性补齐

目标：达到可内部测试的产品体验。

任务：

- 映射 `NetworkInstanceRunningInfoMap` 到现有 peer/status 模型。
- 补齐路由变化后的 VPN 刷新逻辑。
- 降低轮询频率并修复 JNI 字符串释放问题。
- 处理断线重连、控制台 token 失效、workspace 切换。
- 适配手机屏幕布局。
- 增加 Android 日志和错误上报。

### Phase 3: 发布准备

目标：达到可分发构建标准。

任务：

- 改正式 `applicationId` 和签名配置。
- 配置 ABI split。
- 建立 JNI 构建 CI。
- 编写 VPN 权限和后台运行说明。
- 使用本地 E2E 与线上控制台分别验证。
- 完成 `dart analyze`、`flutter test`、Android 真机测试。

## 验证计划

### Dart 单元测试

- config server URL 拼接：
  - base 无 trailing slash
  - base 有 trailing slash
  - base 带 path
  - token 需要 URL encode
- Android runtime JSON parser：
  - running instance
  - error instance
  - peers
  - routes
  - peer-route pairs
- 生命周期状态：
  - 未登录
  - VPN 未授权
  - config server connected
  - instance running
  - logout cleanup

### Android 集成测试

- `flutter build apk --debug`
- `flutter run -d <android-device>`
- 验证 JNI library 加载。
- 验证 config server callback 到达 Dart。
- 验证 `VpnService.prepare()` 授权和拒绝路径。
- 验证 `setTunFd` 后网络实例 running。
- 验证退出登录后 VPN 和 config server client 均停止。

### 回归测试

- 桌面端 `dart analyze`。
- 桌面端 `flutter test`。
- Windows installer/CLI 路径不受 Android runtime 改动影响。

## 待产品确认

- Android MVP 是否只允许一个活跃网络。
- Android 设备名称显示规则。
- Android enrollment key 名称是否从 `Desktop Auto Key` 改成平台相关名称。
- Android 流量统计在 MVP 中是隐藏、近似展示，还是要求 core 补 API。
- 国内渠道分发时 VPN 权限说明和后台常驻通知文案。
