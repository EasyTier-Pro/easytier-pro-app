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
- 生成 release artifact 前，建议先运行 `.\scripts\verify_android_release_inputs.ps1 -RequireSigning`，确认签名文件、keystore 可被 `keytool` 打开、`keyAlias` 存在、JNI ABI、正式 `applicationId`、VPN manifest 和 cleartext 策略都符合发布前置条件。

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

`.github/workflows/android.yml` 会在 Ubuntu runner 上使用 EasyTier 固定 commit `48ccc56a1aa4a63ec5192f71e85b330b155f0136` + `scripts/mobile_core.patch`、Rust toolchain `1.95` 和 Android NDK `28.2.13676358`。CI 会先按 commit、Rust toolchain、NDK、脚本及补丁 hash 和 cache version 恢复 `android/app/src/main/jniLibs` 中的 JNI `.so` cache；cache miss 时才检出 EasyTier、安装 Protocol Buffers compiler，并按 EasyTier 的 Rust toolchain 安装 `aarch64-linux-android` 和 `x86_64-linux-android` targets。随后 CI 执行 `dart analyze`、`flutter test`；cache miss 时执行 `scripts/build_android_jni.ps1` 构建 JNI 并复制到临时工作区。无论 cache hit 还是 miss，CI 都会运行 `scripts/verify_android_release_inputs.ps1` 校验 JNI ABI、ELF machine、JNI symbol、release ABI filter、正式 `applicationId`、VPN manifest、cleartext 策略和签名文件忽略规则；只有校验通过后，cache miss 才保存 JNI cache。最后 CI 使用固定 Gradle `9.1.0` 构建 Android debug APK，并打包 `:app:assembleDebugAndroidTest` 以确保 JNI 基础集成测试可编译。CI 不要求真实 release keystore；更新仓库内随包 JNI 产物仍需在本地运行构建脚本并提交结果。CI 打包 androidTest APK 不等同于真机执行，设备侧仍需运行 `connectedDebugAndroidTest` 或手动真机验证。

本地设备侧 smoke test 可执行：

```powershell
cd android
gradle :app:connectedDebugAndroidTest --no-daemon
```

当前 instrumented tests 会覆盖当前设备 ABI 随包 JNI library 存在性、JNI library 加载、`listInstances` 返回 JSON、JSON RPC JNI 入口可用性、Android `machineId` 持久化、hostname 规范化、正式 `applicationId`、debug 本地 E2E cleartext HTTP、VPN manifest 声明、Android 14+ foreground service special-use subtype、原生 service 事件缓冲顺序和容量、config server callback JSON 关键字段解析、JNI 反射 native exception 解包、MethodChannel VPN config 到 service intent 的字段映射、VPN start intent 配置解析、VPN Builder non-blocking TUN 配置、自身 `applicationId` 自动进入 disallowed applications、系统 VPN revoke 清理 hook，以及 `VpnService.prepare(context)` 是否可进入系统 VPN 授权前置流程。该测试不覆盖用户实际点击授权、真实 config server 下发或 TUN 数据面连通性，这些仍需 emulator/真机手动 E2E 验证。

## VPN 权限与后台运行说明

Android 客户端通过 `VpnService` 创建系统 VPN interface，并把 TUN fd 注入 EasyTier core。应用需要向用户说明：

- EasyTier Pro 会创建一个用户可见的 VPN 连接，用于接入已授权的零信任网络。
- Android config server client 由原生前台 `VpnService` 启动并保持运行，Flutter 负责发起启动/停止命令和展示状态。
- 原生 service 对相同 config server 启动命令保持幂等；若收到相同配置，会重新发出带 `alreadyStarted=true` 的 `config_server_started` 事件，保证诊断日志能证明 client 仍在运行；若收到不同 URL/hostname/machineId/secureMode 配置，会先静默停止旧 client 再启动新 client，避免系统重投递命令时重复启动 JNI client。
- 原生服务事件会在 Flutter `EventChannel` 暂未监听时短暂缓存，避免回前台或 engine 重建期间丢失 config server/VPN 状态事件。
- Android Dart runtime 在本轮进程尚未确认 `VpnService.prepare()` 已授权前，不会仅凭 config server client 在线就报告 running；这会强制重新进入 VPN 授权/恢复路径，避免控制面在线但系统 VPN route 未恢复时出现假阳性。
- Android runtime 主动停止时会清空 Dart 侧本轮 VPN 授权确认状态，避免退出登录、工作区失效或登录态失效后的 stop 过程中继续凭旧状态报告 running。
- Android VPN 的地址、路由和 DNS 直接使用核心 `MobileTunConfig` 的聚合结果；核心负责虚拟网、子网映射和地址冲突判断。系统地址保留主机 IP，路由使用网络 CIDR，支持 IPv4 与 IPv6。
- `Android VPN established` 诊断日志同时记录核心聚合 `routes` 和实际传给 `VpnService.Builder.addRoute()` 的 `builder_routes`；如果两者不一致，优先用 `builder_routes` 判断系统接口设置。
- Android VPN interface 会以 non-blocking TUN fd 建立后再交给 EasyTier core，保持与上游 mobile launcher 对 raw fd 的使用方式一致，降低 Rust/tokio 数据面读写被阻塞 fd 卡住的风险。
- Android 使用一个系统 VPN 承载多个核心实例，允许同工作区及跨工作区网络同时连接；工作区切换只改变浏览范围，不裁剪运行实例。系统授权前收到的所有网络配置由核心保留，授权后一起接入。
- 系统地址、路由或 DNS 变化时，Service 串行更新聚合 VPN interface；成员变化但接口配置相同时复用系统 fd。新 fd 挂接成功并确认旧借用释放后才关闭旧 fd；整体停止则先 detach。移除单个成员不会停止其他核心实例。
- 原生聚合或挂接失败通过 `vpn_config_error` 记录；`getVpnState` 返回具体错误及仍就绪的实例。冲突由核心决定，逐实例保留 `rejected` 原因，不把新网络失败显示为全部网络失败。
- Dart 等待目标实例 ID 出现在已接入集合且获得虚拟地址后才显示连接成功。原生 Service 的维护独立于 Flutter 页面，页面关闭或进入后台不会取消其他网络。
- `vpn_started` 表示系统接口已建立且核心挂接成功，诊断记录实际 Builder 配置；`vpn_config_refreshed` 表示在同一接口上更新了已接入成员。
- Android 通知权限或 VPN 授权请求已在系统弹窗中等待时，重复启动不会进入运行时错误；通知权限 pending 会继续后续流程，VPN 授权 pending 会继续展示 `needsVpnPermission` 等待用户处理。
- 用户拒绝系统 VPN 授权时，Dart 运行态会继续展示 `needsVpnPermission`，并在诊断状态中记录授权被拒绝，避免被误判为 config server 或 JNI 运行时错误。
- Android 节点运行态会从 `my_node_info`、`routes` 和 `peer_route_pairs` 映射到现有 peer/status 展示模型。
- Android 流量统计采用 2 秒间隔轮询 JSON RPC stats，peer/status 采用 5 秒间隔刷新节点详情状态；系统 VPN 由原生 Service 的串行任务维护全部实例；配置事件立即触发刷新，Service 每 3 秒读取核心聚合配置以处理地址和路由变化，不依赖 Flutter 后台计时器。随包 JNI 固定到 EasyTier main commit `48ccc56a1aa4a63ec5192f71e85b330b155f0136` + `scripts/mobile_core.patch`，共享补丁提供 `getMobileTunConfig` 和 `attachMobileTunFd` 桥接，核心返回聚合地址、路由、DNS 及逐实例拒绝原因。
- Android bridge 会区分 JNI library/class/method 缺失和 JNI 方法已加载后的 native status 失败；前者按 `JNI_UNAVAILABLE` 处理，后者按运行时错误上报，避免停止或 retain 实例失败被误当作库缺失而吞掉。
- Android 导出诊断日志会写入应用缓存日志目录，并通过 `FileProvider` 拉起系统分享面板；导出聚合时会跳过旧的 `diagnostics-*.log` 文件，避免重复导出导致日志自我嵌套膨胀。
- 核心 config server callback 包含 `instance_id`、`instance_name` 和 `network_name`。Service 使用实例 ID 聚合和挂接 TUN；Dart 使用 callback 与 JSON RPC 名称映射关联各网络的 readiness、peer status 和流量。移除实例后不能用剩余的唯一实例替代已移除网络。
- 已登录且运行中的 Android runtime 收到 `config_server_stopped` 事件时会自动重新连接；退出登录和工作区重建期间不会被该事件反向拉起。
- 工作区切换不重建 runtime。浏览范围与本机源设备绑定分离；目标工作区首次连接复用 Console 的设备共享授权，源设备和凭据不随浏览选择变化。
- 本地 token 过期或控制台 bootstrap 返回 401/403 时会停止 runtime，并提示用户重新登录，避免旧控制面/VPN 连接继续运行。
- Android bootstrap 使用源工作区当前成员的默认注册密钥，沿用 Console 自动取钥契约。目标工作区授权使用其独立默认密钥及审批状态，不替换源设备凭据。
- 退出登录、源设备授权失效、登录态失效、通知 Disconnect 或系统 VPN 撤权通过原生 `STOP_RUNTIME` 停止整个 VPN、控制连接及全部实例。借用 fd 必须在核心串行 detach 完成后关闭。通知 Disconnect 与系统撤权带 stop reason，Dart 不自动重连；系统异常销毁 Service 时带 `service_destroyed`，会话有效时按现有恢复流程重连。目标授权撤销只移除对应网络，不走全局停止路径。
- MagicDNS 的系统设置来自 native 聚合配置：启用 DNS 的已接入成员提供 DNS 服务器、对应主机路由及 `search_domains`，Android 分别调用 `addDnsServer` 和 `addSearchDomain`，使 `ixx-nas` 这样的短名称使用网络的 DNS 域。默认域为 `et.net`，自定义域沿用该成员的 `tld_dns_zone`；多网络域去重后一起安装。搜索域变化也会重建 VPN，移除最后一个启用 DNS 的成员后清除 DNS 和搜索域。`vpn_started`/`vpn_config_refreshed` 原生事件的 `builderDnsServers`、`builderSearchDomains` 记录实际传给 Builder 的设置。
- `EasyTierMobileTunConfigInstrumentedTest` 覆盖默认/自定义 DNS 域、关闭 DNS、成员移除，以及用户态协议栈开关两种配置下各 10 次 TUN fd 交接后的真实 TCP 数据包收发；同时检查 detach 后 fd 仍由 Android 调用方持有。socketpair 回归验证 JNI 和核心收发，不代替未排除应用通过系统 VPN 访问远端 Web 服务的验收。
- VPN 会通过 `addDisallowedApplication(packageName)` 排除 EasyTier Pro 自身，避免控制面连接和 EasyTier 底层传输被自己的 VPN 路由回环；如果未来 EasyTier core、控制面客户端或保活组件拆到独立 Android package，也应把对应 package 加入 disallowed applications。不要默认排除浏览器、Termux、ping 工具等诊断应用，它们需要走 VPN 才能验证虚拟网和子网连通性；不应用 EasyTier Pro 自己访问虚拟网作为判断依据。
- VPN 连接会显示常驻通知；用户可以点击通知返回应用，也可以通过通知动作、系统 VPN 设置或应用内退出/断开操作停止连接。
- 应用不会在客户端硬编码只适用于生产环境的控制面地址；控制台和本地 E2E 环境应继续通过上层配置或控制台接口提供。
- Android 13+ 需要通知权限；拒绝通知权限不应绕过 VPN 授权流程。

## 权限与通知文案草案

以下文案用于国内渠道上架材料、权限说明页和系统权限弹窗前的应用内说明，最终表述仍需产品、法务或渠道运营确认。

### VPN 权限说明

EasyTier Pro 需要创建系统 VPN 连接，用于把本设备安全接入你已授权的零信任网络。连接建立后，系统会把虚拟网和已授权子网的流量交给 EasyTier Pro 处理；应用不会接管与当前网络无关的流量，也不会在客户端内硬编码生产控制台地址。你可以在应用内、常驻通知或系统 VPN 设置中随时断开连接。

### 后台常驻通知说明

EasyTier Pro 在连接期间会显示常驻通知，用于保持控制面连接、接收网络配置变化并维持 VPN 隧道。关闭通知权限不会跳过系统 VPN 授权；如果系统限制后台运行，连接可能中断，应用会在会话仍有效时尝试重新连接。

### 路由回环说明

EasyTier Pro 会把自身应用排除在 Android VPN 路由之外，避免控制面连接和 EasyTier 底层传输被自己的 VPN 路由回环。验证虚拟 IP 或子网连通性时，应使用浏览器、Termux 或 ping 工具等未被排除的应用发起访问。

## Android 路由排查

如果手机已加入网络但无法访问虚拟网或子网，优先按以下顺序判断：

- 先看应用内“设置 -> 诊断日志”的 `Android VPN established`。该日志只会在 `VpnService.Builder.establish()` 成功且 `EasyTierJNI.setTunFd(instanceName, fd)` 返回后出现，`tun_fd` 应为非空；`addresses` 应包含本机 `my_node_info.virtual_ipv4`，`routes` 应至少包含虚拟网 CIDR，并包含控制台授权的子网 CIDR；`builder_routes` 表示原生层实际传给 Android `VpnService.Builder.addRoute()` 的归一化路由，也应包含这些 CIDR。如果控制台配置了映射子网，日志里应出现 mapped CIDR，而不是 `real_cidr->mapped_cidr` 原始字符串。`disallowed_applications` 和 `builder_disallowed_applications` 应包含 `net.easytier.pro`，用于避免控制面和 EasyTier 底层传输路由回环；`self_disallowed` 和 `builder_self_disallowed` 应为 `true`。`Android VPN config refresh requested` 只能说明 Dart 已解析到新路由并请求原生服务刷新，不能单独证明系统 VPN interface 和 TUN fd 已经建立成功。
- 如果没有 `Android VPN established`，先看同一时间附近的 `Android runtime error`，其中的 `action`、addresses、routes 和 `disallowed_applications` 可以判断是 VPN 配置缺失、route 解析失败、TUN 建立失败，还是 JNI `setTunFd` 失败。
- 如果日志缺少虚拟网 CIDR 或子网 CIDR，问题优先在 Dart 对 JSON RPC `show_node_info` / `list_route` 的解析、实例名定位或路由刷新链路。
- 如果日志 routes 正确但未被排除的浏览器、Termux 或 ping 工具仍无法访问虚拟 IP/子网，问题更可能在系统 VPN interface、TUN fd 注入或 EasyTier data-plane 转发链路。
- 不要用 EasyTier Pro 自己访问虚拟网作为连通性判断，因为应用自身会被 `addDisallowedApplication(packageName)` 排除在 VPN 外，用来避免控制面和 EasyTier 底层传输路由回环。
- debug 构建会设置 `allow_bypass`/`builder_allow_bypass=true`，允许 Flutter/ADB 这类显式绑定底层网络的调试链路绕过 VPN；release 构建不启用该调试逃逸能力。排查 VPN 数据面时应使用 Termux、浏览器或其他未排除应用做 UID route probe。
- 导出诊断日志后，可以用 `.\scripts\verify_android_e2e_diagnostics.ps1 -LogPath <diagnostics.log> -ExpectedRoute <虚拟网CIDR>,<子网CIDR>` 自动检查 config server 在最新 VPN 建立前已启动且未被 stop 覆盖、最新 VPN 建立后未出现 VPN stopped、config server 最终未停在 stopped、TUN fd、routes、存在时的 builder_routes、mapped route 归一化和自身应用排除是否满足。`-ExpectedRoute` 会按 Android 系统 route 语义归一化，例如 `10.10.0.42/24` 会按 `10.10.0.0/24` 校验，`real_cidr->mapped_cidr` 会按右侧 mapped CIDR 校验。该脚本不证明数据面已通，虚拟 IP/子网访问仍需用未被排除的应用实际验证。
- 本地 debug 包连接中可以直接运行 `.\scripts\collect_android_e2e_evidence.ps1 -EnvironmentName local -ExpectedRoute <虚拟网CIDR>,<子网CIDR> -RequireSystemRoute -PingTarget <虚拟IP或子网地址> -RequirePingSuccess -ProbePackageName com.termux -RequireProbePackageRoute -RequireSelfExcludedRoute`，脚本会通过 `adb run-as net.easytier.pro` 拉取应用日志，收集 `ip route`、`ip rule`、`ip addr`、`ip link`、`dumpsys connectivity`、`dumpsys netpolicy`、`dumpsys netd`、包信息、route probe 和 ping 输出，并调用诊断校验脚本；`route_probes.txt` 会对 `PingTarget` 和从 `ExpectedRoute` 推导出的目标运行普通 `ip route get`，并分别用 EasyTier Pro 自身 UID 与 `-ProbePackageName` 指定的未排除应用 UID 运行 `ip route get <target> uid <uid>`，前者用于确认自排除不会回环，后者用于判断诊断应用流量是否会进入 VPN 规则/接口。开启 `-RequireProbePackageRoute` 后，脚本会从系统 route table 中提取 `ExpectedRoute` 对应的 VPN interface，并要求未排除应用 UID 的 route probe 命中该 interface；开启 `-RequireSelfExcludedRoute` 后，脚本会要求 EasyTier Pro 自身 UID 的 route probe 不命中这些 VPN interface。系统 route table 检查会归一化 `-ExpectedRoute`。`-RequireSystemRoute` 必须配至少一个 `-ExpectedRoute`，`-RequirePingSuccess` 必须配至少一个 `-PingTarget`，`-RequireProbePackageRoute` 必须配至少一个 `-ExpectedRoute` 和 `-ProbePackageName`，`-RequireSelfExcludedRoute` 必须配至少一个 `-ExpectedRoute`，避免空目标误判通过。脚本会写入 `summary.json`，其中 `passed=true` 表示诊断日志、系统 route、未排除应用 route probe、自排除 route probe 和 ping 的强制项全部通过，`environment_name` 会记录 `local` 或 `online`，`diagnostics_builder_routes` 和 `diagnostics_builder_self_disallowed` 会记录最新 `Android VPN established` 中实际传给 Android VPN Builder 的路由和自排除状态，供最终 readiness gate 校验。如果只是排查失败现场，可以临时去掉 `-RequireSystemRoute`、`-RequirePingSuccess`、`-RequireProbePackageRoute` 或 `-RequireSelfExcludedRoute` 以保留失败证据；发布前数据面验收必须保留这四个开关。release 包无法使用 `run-as` 拉取应用日志，应先用应用内分享面板导出诊断日志，再运行同一脚本并追加 `-DiagnosticsLogPath <diagnostics.log>`，系统 route、probe 和 ping 证据仍会通过 adb 采集。
- 本地 debug 包退出登录或断开连接后，可以运行 `.\scripts\collect_android_e2e_evidence.ps1 -EnvironmentName local -ExpectedRoute <虚拟网CIDR>,<子网CIDR> -RequireStop -RequireConfigServerStop`，脚本会复用已导出的应用日志并确认此前存在 `Android VPN established`，且最新一次 `Android VPN established` 之后出现 `Android VPN stopped` 和 `Android config server client stopped`。断开后的系统 route table 通常已清理，因此该步骤不应加 `-RequireSystemRoute` 或 `-RequirePingSuccess`。

## 发布前验证

最小验证清单：

- `dart analyze`
- `flutter test`
- `.\scripts\verify_android_release_inputs.ps1`
- `.\scripts\verify_android_porting_readiness.ps1`
- `flutter build apk --debug`
- `cd android; gradle :app:assembleDebugAndroidTest --no-daemon`
- `flutter build apk --release --split-per-abi`
- `flutter build appbundle --release`
- Android emulator 或真机登录控制台。
- 完成 VPN 授权。
- 控制台下发 `run_network_instance` 后，日志出现 `vpn_started` 或 native `Injected TUN fd`。
- 应用内“设置 -> 诊断日志”出现 `Android VPN established`，且 `routes` 包含虚拟网 CIDR 与已授权子网 CIDR，`disallowed_applications` 至少包含 `net.easytier.pro`。
- debug 包连接中运行 `.\scripts\collect_android_e2e_evidence.ps1 -EnvironmentName local -ExpectedRoute <虚拟网CIDR>,<子网CIDR> -RequireSystemRoute -PingTarget <虚拟IP或子网地址> -RequirePingSuccess -ProbePackageName <未排除应用包名> -RequireProbePackageRoute -RequireSelfExcludedRoute`，确认诊断日志、系统路由表、route probe、ping 成功证据和 `summary.json` 的 `passed=true`、`environment_name=local` 均已采集；线上控制台验收同样采集一份 `-EnvironmentName online` 的连接证据。
- 在 Android 上导出诊断日志时通过系统分享面板发送文件；拿到文件后可运行 `.\scripts\verify_android_e2e_diagnostics.ps1 -LogPath <diagnostics.log> -ExpectedRoute <虚拟网CIDR>,<子网CIDR>` 单独校验日志，也可以在 release 包或 `run-as` 不可用时把该文件传给 `.\scripts\collect_android_e2e_evidence.ps1 -DiagnosticsLogPath <diagnostics.log>`，继续采集系统 route、route probe 和 ping 证据。
- 使用未被排除的应用访问虚拟 IP 和子网地址，确认系统 VPN route 能承载数据面流量。
- 退出登录后，debug 包运行 `.\scripts\collect_android_e2e_evidence.ps1 -EnvironmentName local -ExpectedRoute <虚拟网CIDR>,<子网CIDR> -RequireStop -RequireConfigServerStop`，或对导出的诊断日志运行 `.\scripts\verify_android_e2e_diagnostics.ps1 -LogPath <diagnostics.log> -ExpectedRoute <虚拟网CIDR>,<子网CIDR> -RequireStop -RequireConfigServerStop`，确认最新一次 VPN 建立之后 config server client 与 VPN 均停止；线上控制台断开验收同样采集一份 `-EnvironmentName online` 的 stop 证据。
- 宣布 Android 移植完成或准备 release sign-off 前，运行 `.\scripts\verify_android_porting_readiness.ps1 -RequireSigning -RequireE2E -RequireStopEvidence -LocalConnectedSummaryPath <local-connected-summary.json> -OnlineConnectedSummaryPath <online-connected-summary.json> -LocalStoppedSummaryPath <local-stopped-summary.json> -OnlineStoppedSummaryPath <online-stopped-summary.json>`，确认 release signing、本地/线上连接证据和断开证据都已满足；传入的 connected summary 必须证明 `diagnostics_routes` 与 `diagnostics_builder_routes` 覆盖全部 `expected_routes`，`diagnostics_builder_disallowed_applications` 包含 `package_name`，`diagnostics_builder_self_disallowed=true`，并保留 `files.diagnostics`、`files.routes`、`files.route_probes`、`files.connectivity` 和 `files.metadata` 指向的原始证据文件。

仍需产品确认：

- 上传签名证书归属和保管流程。
- 国内渠道 VPN 权限说明和后台常驻通知文案终审。
- Android 流量统计已优先使用 EasyTier JSON RPC stats；仍需产品确认展示口径是否需要标注、弱化或与桌面完全对齐。
