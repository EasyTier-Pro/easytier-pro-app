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
- 生成 release artifact 前，建议先运行 `.\scripts\verify_android_release_inputs.ps1 -RequireSigning`，确认签名文件、JNI ABI、正式 `applicationId`、VPN manifest 和 cleartext 策略都符合发布前置条件。

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

Debug/profile Android 构建会启用 cleartext HTTP，用于访问本地 E2E 控制台，例如 `http://10.147.223.128:14173/`。主 manifest 不启用该策略，release 分发仍应使用 HTTPS 控制台入口或由渠道侧明确配置网络安全策略。

## CI

`.github/workflows/android.yml` 会在 Windows runner 上检出 EasyTier 固定 commit，安装 Android NDK `28.2.13676358`，执行 `dart analyze`、`flutter test`、`scripts/build_android_jni.ps1 -SkipCopy` 验证 Dart/Flutter 与 JNI 均可构建，运行 `scripts/verify_android_release_inputs.ps1` 校验仓库随包 JNI ABI、release ABI filter、正式 `applicationId`、VPN manifest、cleartext 策略和签名文件忽略规则，构建 Android debug APK，并打包 `:app:assembleDebugAndroidTest` 以确保 JNI 基础集成测试可编译。CI 当前不改写仓库内已提交的 `.so` 文件，也不要求真实 release keystore；更新随包 JNI 产物仍需在本地运行构建脚本并提交结果。CI 打包 androidTest APK 不等同于真机执行，设备侧仍需运行 `connectedDebugAndroidTest` 或手动真机验证。

本地设备侧 smoke test 可执行：

```powershell
cd android
.\gradlew.bat :app:connectedDebugAndroidTest
```

当前 instrumented tests 会覆盖当前设备 ABI 随包 JNI library 存在性、JNI library 加载、`collectNetworkInfos` 返回 JSON、Android `machineId` 持久化、hostname 规范化、正式 `applicationId`、debug 本地 E2E cleartext HTTP、VPN manifest 声明、Android 14+ foreground service special-use subtype、原生 service 事件缓冲顺序和容量、config server callback JSON 关键字段解析、JNI 反射 native exception 解包、MethodChannel VPN config 到 service intent 的字段映射、VPN start intent 配置解析、VPN Builder non-blocking TUN 配置、自身 `applicationId` 自动进入 disallowed applications、系统 VPN revoke 清理 hook，以及 `VpnService.prepare(context)` 是否可进入系统 VPN 授权前置流程。该测试不覆盖用户实际点击授权、真实 config server 下发或 TUN 数据面连通性，这些仍需 emulator/真机手动 E2E 验证。

## VPN 权限与后台运行说明

Android 客户端通过 `VpnService` 创建系统 VPN interface，并把 TUN fd 注入 EasyTier core。应用需要向用户说明：

- EasyTier Pro 会创建一个用户可见的 VPN 连接，用于接入已授权的零信任网络。
- Android config server client 由原生前台 `VpnService` 启动并保持运行，Flutter 负责发起启动/停止命令和展示状态。
- 原生 service 对相同 config server 启动命令保持幂等；若收到相同配置，会重新发出带 `alreadyStarted=true` 的 `config_server_started` 事件，保证诊断日志能证明 client 仍在运行；若收到不同 URL/hostname/machineId/secureMode 配置，会先静默停止旧 client 再启动新 client，避免系统重投递命令时重复启动 JNI client。
- 原生服务事件会在 Flutter `EventChannel` 暂未监听时短暂缓存，避免回前台或 engine 重建期间丢失 config server/VPN 状态事件。
- Android Dart runtime 在本轮进程尚未确认 `VpnService.prepare()` 已授权前，不会仅凭 config server client 在线就报告 running；这会强制重新进入 VPN 授权/恢复路径，避免控制面在线但系统 VPN route 未恢复时出现假阳性。
- Android runtime 主动停止时会清空 Dart 侧本轮 VPN 授权确认状态，避免退出登录、工作区失效或登录态失效后的 stop 过程中继续凭旧状态报告 running。
- Android VPN 会从 `my_node_info.virtual_ipv4` 派生虚拟网自身路由，并从 `routes[].proxy_cidrs`、`peer_route_pairs`、按 peer/route id 分组的 map 形路由、runtime config 的 `routes`/`proxy_networks` 和常见子网路由别名下发虚拟网/子网路由；如果子网路由使用 `real_cidr->mapped_cidr` 映射，Android 系统 VPN route 使用右侧 mapped CIDR。如果 native 运行态同时返回嵌套 `vpn_config` 和外层 route 信息，Android runtime 会合并两侧配置，避免只拿到虚拟 IP 而丢失外层路由。原生层在建立 VPN 前会再次把 route 规范为网络 CIDR，例如 `10.10.0.42/24` 会进入系统 VPN route 表为 `10.10.0.0/24`；本机地址仍保留主机 IP 传给 `addAddress`。
- Android VPN interface 会以 non-blocking TUN fd 建立后再交给 EasyTier core，保持与上游 mobile launcher 对 raw fd 的使用方式一致，降低 Rust/tokio 数据面读写被阻塞 fd 卡住的风险。
- Android MVP 只保留一个活跃 VPN 网络实例；Android UI 会阻止在已有 joined/joining/leaving 网络时加入第二个网络。若授权前连续收到多个 `run_network_instance`，最新下发会覆盖旧的 pending 配置，避免授权恢复后回切到旧网络。
- Android VPN 建立后会先以 3 秒间隔刷新路由配置，随后降为 15 秒间隔；若虚拟 IP、子网路由、DNS 或 MTU 变化，会重新建立 VPN interface 并重新注入 TUN fd。
- Android `START_VPN` 建立失败会带 `action`、`instanceName`、addresses、routes、DNS、已归一化的 disallowed applications、`packageName`、数量统计和 `selfDisallowed` 上报错误，并只清理本次 VPN 启动状态；即使配置解析失败，失败 payload 也会补上 EasyTier Pro 自身包名，便于排查路由回环防护是否生效。如果 config server client 仍在运行，原生 service 会保持前台等待下一次配置刷新，避免路由/地址错误直接中断控制面连接。
- Dart 侧收到 Android runtime error 时会写入 `Android runtime error` 诊断日志，保留 action、instance、addresses、routes、DNS、disallowed applications 和 `self_disallowed`，便于在 `Android VPN established` 缺失时反查失败前的 VPN 配置。
- Android VPN 后续收到原生 `vpn_started` 后，Dart 运行态会把此前的 VPN 运行时错误恢复为 running，避免诊断错误在已恢复连接后继续占据首页状态；Dart 侧 `vpn_config_refreshed` 只表示已请求原生服务刷新配置，不作为 TUN 注入成功证据。
- Android 通知权限或 VPN 授权请求已在系统弹窗中等待时，重复启动不会进入运行时错误；通知权限 pending 会继续后续流程，VPN 授权 pending 会继续展示 `needsVpnPermission` 等待用户处理。
- 用户拒绝系统 VPN 授权时，Dart 运行态会继续展示 `needsVpnPermission`，并在诊断状态中记录授权被拒绝，避免被误判为 config server 或 JNI 运行时错误。
- Android 节点运行态会从 `my_node_info`、`routes` 和 `peer_route_pairs` 映射到现有 peer/status 展示模型。
- Android 运行态信息轮询采用 15 秒间隔和 15 秒 `collectNetworkInfos` 缓存，降低 JNI 轮询压力；随包 JNI 通过本仓库构建脚本的本地补丁释放 `collectNetworkInfos` 返回的 FFI 字符串。
- Android bridge 会区分 JNI library/class/method 缺失和 JNI 方法已加载后的 native status 失败；前者按 `JNI_UNAVAILABLE` 处理，后者按运行时错误上报，避免停止或 retain 实例失败被误当作库缺失而吞掉。
- Android 导出诊断日志会写入应用缓存日志目录，并通过 `FileProvider` 拉起系统分享面板；导出聚合时会跳过旧的 `diagnostics-*.log` 文件，避免重复导出导致日志自我嵌套膨胀。
- 随包 JNI 构建会给 config server callback 补充 `instance_name` 和 `network_name`；Dart 使用 `instance_id` 匹配 `collectNetworkInfos` 中以 UUID 为 key 的 running info，使用 `instance_name` 调用 `retainNetworkInstance`、`START_VPN` 和 `setTunFd`，并使用 `network_name` 关联首页 readiness、peer status、流量统计和后续删除事件，避免把 UUID 或控制台网络名误当 EasyTier instance name 导致 TUN 注入、路由刷新或停止失败。
- 已登录且运行中的 Android runtime 收到 `config_server_stopped` 事件时会自动重新连接；退出登录和工作区重建期间不会被该事件反向拉起。
- workspace 切换会强制重建 runtime；如果当前账号失去 workspace 绑定，会先停止 runtime，避免继续保持旧 workspace 的控制面/VPN 连接。
- 本地 token 过期或控制台 bootstrap 返回 401/403 时会停止 runtime，并提示用户重新登录，避免旧控制面/VPN 连接继续运行。
- Android bootstrap 会优先复用当前 workspace 中未撤销、未过期且可复用的 `Android Auto Key`；如果只存在 `Desktop Auto Key`、一次性 key 或其他平台 key，会创建新的 Android 平台注册密钥，避免 Android 设备注册审计混用桌面密钥。
- 退出登录、工作区失效、登录态失效、常驻通知 Disconnect、系统 VPN 设置撤销连接或 Android 销毁原生 service 时，会由原生 `STOP_RUNTIME` 路径按顺序停止 config server client，调用 `retainNetworkInstance(null)` 清理 EasyTier core 网络实例，再停止 Android VPN interface；常驻通知 Disconnect 和系统撤销路径会在 `config_server_stopped`/`vpn_stopped` 事件中带 stop reason，Dart 运行态进入 stopped 且不会自动重连。
- VPN 会通过 `addDisallowedApplication(packageName)` 排除 EasyTier Pro 自身，避免控制面连接和 EasyTier 底层传输被自己的 VPN 路由回环；因此连通性验证应使用浏览器、Termux、ping 工具等未排除的应用发起，不应用 EasyTier Pro 自己访问虚拟网作为判断依据。
- VPN 连接会显示常驻通知；用户可以点击通知返回应用，也可以通过通知动作、系统 VPN 设置或应用内退出/断开操作停止连接。
- 应用不会在客户端硬编码只适用于生产环境的控制面地址；控制台和本地 E2E 环境应继续通过上层配置或控制台接口提供。
- Android 13+ 需要通知权限；拒绝通知权限不应绕过 VPN 授权流程。

## Android 路由排查

如果手机已加入网络但无法访问虚拟网或子网，优先按以下顺序判断：

- 先看应用内“设置 -> 诊断日志”的 `Android VPN established`。该日志只会在 `VpnService.Builder.establish()` 成功且 `EasyTierJNI.setTunFd(instanceName, fd)` 返回后出现，`tun_fd` 应为非空；`addresses` 应包含本机 `my_node_info.virtual_ipv4`，`routes` 应至少包含虚拟网 CIDR，并包含控制台授权的子网 CIDR；如果控制台配置了映射子网，日志里应出现 mapped CIDR，而不是 `real_cidr->mapped_cidr` 原始字符串。`disallowed_applications` 应包含 `net.easytier.pro`，`self_disallowed` 应为 `true`。`Android VPN config refresh requested` 只能说明 Dart 已解析到新路由并请求原生服务刷新，不能单独证明系统 VPN interface 和 TUN fd 已经建立成功。
- 如果没有 `Android VPN established`，先看同一时间附近的 `Android runtime error`，其中的 `action`、addresses、routes 和 `disallowed_applications` 可以判断是 VPN 配置缺失、route 解析失败、TUN 建立失败，还是 JNI `setTunFd` 失败。
- 如果日志缺少虚拟网 CIDR 或子网 CIDR，问题在 Dart 对 `collectNetworkInfos` / config server 下发结果的解析或路由刷新链路。
- 如果日志 routes 正确但未被排除的浏览器、Termux 或 ping 工具仍无法访问虚拟 IP/子网，问题更可能在系统 VPN interface、TUN fd 注入或 EasyTier data-plane 转发链路。
- 不要用 EasyTier Pro 自己访问虚拟网作为连通性判断，因为应用自身会被 `addDisallowedApplication(packageName)` 排除在 VPN 外，用来避免控制面和 EasyTier 底层传输路由回环。
- 导出诊断日志后，可以用 `.\scripts\verify_android_e2e_diagnostics.ps1 -LogPath <diagnostics.log> -ExpectedRoute <虚拟网CIDR>,<子网CIDR>` 自动检查 config server 启动、TUN fd、routes、mapped route 归一化和自身应用排除是否满足。该脚本不证明数据面已通，虚拟 IP/子网访问仍需用未被排除的应用实际验证。
- 本地 debug 包可以直接运行 `.\scripts\collect_android_e2e_evidence.ps1 -ExpectedRoute <虚拟网CIDR>,<子网CIDR> -PingTarget <虚拟IP或子网地址>`，脚本会通过 `adb run-as net.easytier.pro` 拉取应用日志，收集 `ip route`、`ip rule`、`dumpsys connectivity`、包信息和可选 ping 输出，并调用诊断校验脚本；如果要把系统 route table 缺少期望 CIDR 视为失败，可加 `-RequireSystemRoute`。release 包无法使用 `run-as`，应改用应用内分享面板导出诊断日志。

## 发布前验证

最小验证清单：

- `dart analyze`
- `flutter test`
- `.\scripts\verify_android_release_inputs.ps1`
- `flutter build apk --debug`
- `cd android; .\gradlew.bat :app:assembleDebugAndroidTest`
- `flutter build apk --release --split-per-abi`
- `flutter build appbundle --release`
- Android emulator 或真机登录控制台。
- 完成 VPN 授权。
- 控制台下发 `run_network_instance` 后，日志出现 `vpn_started` 或 native `Injected TUN fd`。
- 应用内“设置 -> 诊断日志”出现 `Android VPN established`，且 `routes` 包含虚拟网 CIDR 与已授权子网 CIDR，`disallowed_applications` 至少包含 `net.easytier.pro`。
- debug 包运行 `.\scripts\collect_android_e2e_evidence.ps1 -ExpectedRoute <虚拟网CIDR>,<子网CIDR> -RequireSystemRoute -PingTarget <虚拟IP或子网地址>`，确认诊断日志、系统路由表和可选 ping 证据均已采集。
- 在 Android 上导出诊断日志时通过系统分享面板发送文件；拿到文件后运行 `.\scripts\verify_android_e2e_diagnostics.ps1 -LogPath <diagnostics.log> -ExpectedRoute <虚拟网CIDR>,<子网CIDR>`。
- 使用未被排除的应用访问虚拟 IP 和子网地址，确认系统 VPN route 能承载数据面流量。
- 退出登录后，应用内诊断日志出现 `Android VPN stopped` 和 `Android config server client stopped`，确认 config server client 与 VPN 均停止。

仍需产品确认：

- 上传签名证书归属和保管流程。
- 国内渠道 VPN 权限说明文案。
- Android 流量统计是继续弱化展示，还是等待 EasyTier JNI 暴露等价 stats API。
