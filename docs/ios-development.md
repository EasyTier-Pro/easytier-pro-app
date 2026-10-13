# iOS 开发与验证

iOS 15 及以上（当前 Flutter 工具链的最低版本）；真机和 Apple Silicon Mac 上的 ARM64 模拟器。
Flutter Runner 是前台界面，`PacketTunnel.appex` 独立运行 EasyTier 控制面与
数据面。退出前台界面不会停止 VPN；应用内断开连接、退出账号会停止扩展。
一个设备同时连接一个网络，与 Android 当前限制一致。

## 构建

需要 macOS、Xcode、Flutter、Rust 和 `protoc`。Flutter 版本及当前语义树
回归补丁与 `.github/workflows/ios.yml` 保持一致。

```bash
brew install protobuf
flutter pub get
./scripts/build_ios_core.sh
flutter build ios --simulator --debug
flutter build ios --release --no-codesign
```

脚本从 EasyTier 官方仓库检出 `scripts/ios_core_revision` 指定的提交，使用
Cargo.lock 构建真机与 ARM64 模拟器静态库，生成
`ios/Frameworks/EasyTierCore.xcframework`。生成的框架和版本信息不提交。
可通过 `EASYTIER_REPO=/path/to/checkout` 使用已有的干净、相同提交的检出。
升级内核时修改固定提交并重建；内核随应用更新，不在 iOS 上下载或替换代码。
界面展示框架实际编译版本，不使用控制台期望版本代替。

在 Xcode 中打开 `ios/Runner.xcworkspace`，选择 Runner 与真机。
`ios/Flutter/Signing.xcconfig` 默认公司 Team 为 `M2G6355ZK7`，Bundle ID 为
`net.easytier.pro`。可在 Xcode 的构建设置中覆盖 `EASYTIER_BUNDLE_ID`、
`EASYTIER_APP_GROUP` 和 `DEVELOPMENT_TEAM`。Runner 与 PacketTunnel 必须
使用同一 Team，分别注册主应用 ID 和 `.PacketTunnel` 扩展 ID，并启用：

- Network Extensions：Packet Tunnel。
- App Groups：`group.net.easytier.pro`，或覆盖后的同一组。
- Keychain Sharing：同一 `$(AppIdentifierPrefix)$(EASYTIER_BUNDLE_ID)`。

签名、归档与上架使用公司账号的 Xcode 自动签名与 Organizer 流程；CI 编译
未签名真机产物，模拟器测试使用本地临时签名，不上传 App Store。已经上架的 EasyTier 本体应用是
独立 Bundle ID，本应用使用自己的 VPN 配置。

## 运行行为

- 使用公开 `NEPacketTunnelFlow` 读写数据包，通过 datagram socketpair 接入
  EasyTier 原有 iOS TUN 适配；不读取私有 utun fd，也不修改核心仓库。
- 登录后由主应用维持前台控制连接，进行设备注册并保持设备在线；没有启用网络时
  不启动系统 VPN。收到控制台下发的网络实例后，串行停止前台核心，再启动 VPN
  扩展，两边复用共享 Keychain 中的 machine ID。交接允许控制连接短暂重连。
- VPN 扩展收到网络配置与虚拟 IP、完成网络设置和数据桥挂接后才报告启动成功。
  启动阶段 30 秒内没有可用网络则失败并释放 VPN，前台恢复控制连接并提示重试。
  最后一个选中实例被控制台移除时，扩展停止并释放 VPN；主应用在前台接回控制
  连接。普通实例替换保留 VPN，不按删除处理。
- 没有启用网络时，主应用进入后台会停止前台控制连接，返回前台后重新连接；
  此期间控制台可能显示设备离线。已启用网络的 VPN 扩展独立运行。
- 扩展查询运行实例的 IPv4 地址、路由和配置，刷新 DHCP 地址、对端虚拟 IP、
  映射子网与手动路由。移除网络或切换实例时撤销旧路由。
- Magic DNS 启用时，使用固定核心的 `100.100.100.101` 与控制台当前默认
  `et.net` 域，添加 DNS 主机路由并配置分域解析；关闭时恢复系统 DNS。
  自定义核心 TOML DNS 域和 IPv6 虚拟地址目前未适配。IPv6 传输由核心管理。
- Wi-Fi/蜂窝变化由扩展中的 Network path monitor 与核心连接逻辑处理；
  Flutter 的轮询不参与维持隧道。系统手动断开 VPN 后不主动重新连接。
- OAuth 凭据、设备令牌、运行配置及稳定 machine ID 存入共享 Keychain，使用
  `AfterFirstUnlockThisDeviceOnly`；旧 SharedPreferences 凭据在写入成功后删除。
- 设备授权回跳仍为 `easytierpro://auth/device-complete`。iOS 暂时保留控制台
  已识别的 `Desktop Auto Key` 名称，避免改变默认 enrollment key 的配额与
  权限语义；来源是控制台 `internal/module/networking/enrollment_key_app.go`。
- 分享诊断会合并应用日志、前台控制核心日志、扩展日志及核心日志；扩展日志轮转并隐藏 bootstrap
  token。VPN 配置不包含令牌，App Group 的状态文件不存储凭据。

## 验证

```bash
dart analyze
flutter test
xcodebuild test -project ios/Runner.xcodeproj -scheme Runner \
  -destination 'platform=iOS Simulator,id=<simulator-id>' \
  -only-testing:RunnerTests CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

Dart 测试验证 MethodChannel 启停、配置匹配、版本展示、实例查询、流量统计、
原生事件转发及 Keychain 迁移；XCTest 验证原生 Keychain 读写、machine ID
持久化、诊断脱敏、协议格式的地址、映射路由、手动路由和 Magic DNS 设置。
Keychain 测试需要签名所声明的共享权限；完全禁用签名会返回 `-34018`。
模拟器可验证登录界面、回跳及原生接口；系统不提供 VPN 服务，点击连接时
应用会提示使用真机，不会在模拟器中报告虚假的 VPN 连接。
模拟器不能替代真机 Packet Tunnel 数据面验证；首次未加入网络时的空网络
设置、数据包转发、后台保活与网络切换仍需签名真机确认。

2026-10-12 已在本地完成以下验证：

- Flutter 静态分析与 234 项测试通过。
- Mac 上构建固定核心的真机、ARM64 模拟器 XCFramework；实际核心版本为 2.7.0。
- Xcode 26.6、iOS 26.5 的 iPhone 17 Pro 模拟器上，8 项 XCTest 通过。
- 模拟器 Debug 应用与扩展、未签名真机 Release 应用与扩展均编译通过。
- 模拟器登录界面启动正常，原生状态查询不会调用不存在的系统 VPN 服务。
- 额外 UI 自动化完成授权回跳的系统确认，应用重新进入前台且保留登录界面。

公司账号签名后的真机需要验证以下实际行为，并保存分享诊断与探测结果：

1. 控制台登录、浏览器回跳、VPN 授权，未加入网络时设备能完成注册。
2. 加入网络后能访问对端虚拟 IP 与授权子网，解析 `et.net` 域。
3. DHCP 地址、子网路由和网络切换更新系统配置，旧路由撤销。
4. 退到后台、锁屏和退出前台界面后保持连通；从系统设置断开后应用正确显示。
5. Wi-Fi 与蜂窝切换后恢复连通，离开网络与退出账号后撤销 VPN。
6. 本地 E2E 与线上控制台分别完成验证。使用已有控制台 URL 配置入口；
   本地 HTTP E2E 构建可通过 Xcode 的本地网络/ATS 调试配置测试，正式分发
   保持 HTTPS。
