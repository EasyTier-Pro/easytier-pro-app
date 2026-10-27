# 多工作区与 Android 多网络

## 目标与授权范围

2026-10-28 确认：桌面端和 Android 提供顶栏工作区切换入口；切换仅改变
浏览范围，原工作区的网络保持连接，允许多个工作区的网络同时运行。
Android 使用一个系统 VPN 承载多个 EasyTier 实例。

用户随后明确取消 iOS：本次不实现或验证 iOS 多网络，不升级其核心、
补丁或原生运行时；共享 Flutter 修改须保留 iOS 原有单网络限制。

实现涉及本 App 和 EasyTier 核心的 Android 桥接；复用 Console 现有设备
跨工作区授权，不新增控制面模型。先记录方案，再实现并提交可审查的
逻辑改动。完成后对完整最终 diff 做一次独立审查。

用户要求自行完成桌面和移动端 E2E，优先 Android Docker 模拟器，
Console 使用本机 E2E 环境。允许构建、安装测试包及创建专用测试资源；
不部署生产，不上传应用商店，不修改现有审核服务。

## 事实来源

- App：`ConsoleUser.currentWorkspace` 当前固定取第一项；
  `CoreLifecycleService.bindSession` 把工作区变化视为重装引擎。
- App：Android 在加入网络时停止旧 VPN 并 retain 单个实例；iOS
  PacketTunnel 同样保留一个实例，移除它会停止整个隧道。
- Console：`CONTEXT.md` 的 Device Workspace Authorization 及
  `docs/adr/0047-member-default-keys-and-device-sharing.md` 定义设备共享。
  一台设备保留唯一源工作区和 EasyTier Target，授权不复制设备或建立
  另一条控制连接。目标工作区拥有独立审批与节点管理权限。
- 核心：`easytier/src/instance/factory/mobile_tun.rs` 已有
  `get_mobile_tun_config` 和 `attach_mobile_tun_fd`；聚合地址、路由、
  DNS，返回实际接受的实例及拒绝原因。调查时远端 main 为
  `48ccc56a1aa4a63ec5192f71e85b330b155f0136`，移动 FFI 尚未导出这些能力。

以上为源码调查事实，部署状态及数据面行为以 E2E 记录为准。

## 交互

桌面顶栏常驻“工作区名称 ▾”；Android 直接点击顶部工作区名称打开
选择面板。两次点击完成切换，不进入设置或头像菜单，优先使用 ForUI。
记住同一 Console、同一 Account 上次浏览的工作区；无权访问后清理
选择并显示仍可访问的工作区，不据此重新注册本机。

显示跨工作区连接摘要与各网络独立状态，使后台网络仍可发现和断开。
切换工作区不申请授权、不变更网络节点，也不启动或停止引擎。

首次连接目标工作区网络时，复用已有设备授权；没有授权才提交申请。
目标审批未通过时显示等待批准，不把源设备已批准当成目标已批准。
单个网络连接失败或发生路由冲突时，显示该网络的原因。

## 状态与设备身份

分开管理 Account 登录态、当前浏览工作区、本机源设备绑定和网络状态：

- 本机绑定保存源 workspace ID 和 canonical device ID，凭据沿用当前
  安全存储路径。恢复时验证现有登记，不能因工作区排序变化换绑。
- 工作区选择按 Console 与稳定 Account ID 隔离；不依赖显示名称。
- 页面查询按工作区隔离，切换后旧请求不得覆盖新页面。
- 网络操作和运行状态不依赖当前工作区页面的存活，离开页面不取消
  已授权的连接意图；UI 以本机实例实际接入结果展示成功。
- 不增加第二份控制台网络配置事实来源，实例仍由现有配置连接下发。

Console 现有接口：

| 用途 | 路径 |
| --- | --- |
| Account 与工作区权限 | `GET /api/v1/auth/me` |
| 目标默认注册密钥 | `/api/v1/tenants/{target}/device-enrollment-keys` |
| 源设备授权列表与创建 | `/api/v1/tenants/{source}/devices/{deviceId}/shares` |
| 目标设备与授权状态 | `GET /api/v1/tenants/{target}/devices` |
| 加入目标网络 | `POST /api/v1/tenants/{target}/networks/{networkId}/nodes` |

创建授权传入 `target_workspace_id` 和 `enrollment_key_id`；加入网络
使用同一源 `device_id`。默认注册密钥复用 Console 当前自动获取语义，
不自行挑选其他成员的密钥。设备模型解析 `workspace_authorization`
及 `permissions`，操作使用明确设备 ID，不依赖 machine ID 首项匹配。

目标授权或目标凭据撤销只影响目标节点；源设备、源凭据或源成员权限
失效可能影响全部节点。不得擅自复制设备、切换源归属来掩盖失效。
退出账号停止该账号的全部本机连接。

## Android 运行时

核心仓库为现有聚合配置和批量 TUN attach 增加薄桥接接口，保持路由
选择、冲突判断和成员所有权在核心内。App 原生 VPN 服务维护实例
集合并安装核心返回的地址、路由和 DNS，不在 Dart/Kotlin 重写
路由算法，也不为每个网络建立一个系统 VPN。

新增或移除成员时更新聚合配置；最后一个成员退出才关闭系统 VPN。
权限撤销、退出账号等全局操作停止全部成员。实例删除或被拒绝的
处理不得错误关闭仍有成员的 VPN。

Android 保留一个 VpnService，按聚合结果更新系统接口。系统设置和
FD 交接串行执行，确保核心释放借用的 FD 后再关闭系统接口，避免旧
回调释放新接口。
就绪按实例 ID 判断，不能把全局 VPN 已启动当成所有网络成功。

升级 Android 原生核心，保留必要的事件与就绪确认；不把无关核心
重构作为本需求的前置条件。iOS 原有固定版本和补丁保持不变。

## 实施与验收顺序

1. 完成设计审查、设备绑定与浏览工作区解耦、共享授权和入口。
2. 补齐核心桥接，接入 Android 多实例运行时，优先完成 Android E2E。
3. 完成 Windows 桌面 E2E。
4. 冻结候选，完成代表性回归、完整 diff 审查和最终证据记录。

使用 `casdoor-rehearsal-android` Docker 模拟器及本机 Console
`http://10.147.223.128:14173/`。Windows 测试机为
`codexdiag@10.147.223.237`。iOS 不在本次验收范围。
凭据从已授权本地记录取用，不写入文档、日志或提交。

先检查登录、设备注册、VPN 授权、探测节点以及收尾能力，再跑多网络：

- 工作区 A/B 各至少一个不同网段网络，两端同时访问各自的虚拟 IP
  HTTP 服务并保留服务端来源地址、原始响应和运行版本。
- A→B→A 切换不重装引擎，原连接持续传输；返回原页面状态正确。
- 断开 A 后 B 持续可用，再加入 A 可恢复；同工作区多网络同样验证。
- 目标授权 pending、撤销和冲突结果显示正确，不误报全局连接成功。
- 后台/前台、进程恢复、系统网络变化、VPN 撤权和退出登录覆盖
  对应平台完整生命周期；重启后检查设备身份及网络实际恢复。
- Flutter analyze/test、相关原生测试及构建通过；核心检查使用主
  仓库 target 缓存，避免 worktree 中新增大目录。

同一候选、配置与输入的有效结果复用；只因代码变化、新失败或明确
疑点重跑。原始结果放在忽略的 build 目录，提交文档记录命令、版本、
配置、关键结果及未完成项，不把未执行的真机验证记为通过。

## 实施记录

- 2026-10-28：方案经用户确认，先记录设计，再实施 Android 与桌面端。

- 用户后续要求“别搞 ios”：停止并撤出 iOS 专属变更，继续 Android
  与 Windows 实现和 E2E。此前 iOS 预研结果不计入本次交付。

- App 保存浏览工作区和源设备绑定，连接状态由 `CoreLifecycleService`
  持有。桌面顶栏及 Android 首页顶部提供 ForUI 切换器和所有连接摘要。
  目标工作区沿用 Console 的设备共享申请、审批与节点权限。
- Android Service 持有全部实例并串行更新共享 TUN；Flutter 只查询
  逐实例就绪状态。配置事件与定时刷新均由原生 Service 处理。
  单实例配置错误不再将仍在联网的整个引擎标为失败。
- EasyTier 核心基线 `48ccc56a` 加共享补丁，最终源码 `99699427`。
  导出聚合配置和批量 attach，等待旧成员释放借用的 FD，使用已有
  mutation lock 串行化 attach 与删除。被拒绝或移除的成员释放自身
  TUN 关联；`Created` / `Starting` 暂不列为接受或拒绝，等待启动完成。
  App 的 `scripts/mobile_core.patch` 与核心最终 diff 逐字节一致。

## 验证记录

原始证据位于忽略目录 `build/multi-network-e2e/`，原生测试证据位于
`build/e2e/multi-workspace/android/`。认证文件仅保存在本地，不提交。

### 环境与候选

- Android 14 x86_64，Docker `casdoor-rehearsal-android`，ADB
  `127.0.0.1:5557`。使用应用自己的设备授权登录流程，未向 App 注入
  token。专用 A/B 工作区及不同网段的 HTTP 探测节点用于验收。
- 最终 Android APK 对应 App `9d74800`，SHA256
  `68a3324bf352122a5bf7f4957e9fd727df65d10676417bbd4fabd304812cea78`。
  x86_64 库 SHA256 为
  `c1c12b22e30323e078733c61718af56889e7f34f93a60ccba3365a6ce9104952`，
  arm64 库为
  `6ee2d7f06bda1fbdf10251468c015465fbf35beafd0c4a29b6b92e4d4698a40e`。
- 本地 Console 自签名 HTTPS 不被核心默认根证书信任。经用户同意，
  测试期间独占 E2E 部署配置，将公共 API 地址临时改为本机 HTTP；
  不在客户端绕过 TLS。测试中发现共享环境被其他任务重建，已隔离
  此干扰；随后复核并纠正了临时配置误用旧镜像的问题，最终使用
  独占前的 `local-permission-limit-691183646` 镜像。
- 同工作区多网使用专用 B fixture，临时提高其网络/节点配额；不改变
  原有 A 工作区或默认套餐。收尾恢复环境和临时配额。

### 已完成检查

- `scripts/flutter_docker.sh dart analyze` 无问题；
  `scripts/flutter_docker.sh flutter test --no-pub --reporter expanded`
  最终候选全量 253 项通过。单实例错误隔离另通过 Android Dart
  33 项及定向静态分析。最终日志为
  `build/e2e/multi-workspace/android/final-*.log`。
- Android Kotlin 编译及最终核心 JNI instrumentation 4 项通过：真实
  双实例启动、启动阶段不误拒绝、聚合地址、删除一员保留另一员，
  以及空集合 detach、非法 ID 和配置映射。
- 核心使用主仓库 `CARGO_TARGET_DIR=/data/project/EasyTier/target`：
  `cargo test --locked -p easytier --lib member_shutdown_waits_for_cleanup_and_keeps_other_members`
  1 项、`cargo test --locked -p easytier-ffi mobile_tun` 2 项、
  `cargo test --locked -p easytier --lib factory::mobile_tun::tests` 5 项通过。
  `cargo clippy --locked -p easytier -p easytier-ffi -p easytier-android-jni --lib --tests -- -D warnings`
  通过。上述宿主检查覆盖 `24aa19e7`；最后的 mobile 启动状态修正
  `99699427` 通过 fmt、双 ABI release 构建及上述真实 JNI 回归。
- Android A/B 同时访问 `10.253.81.1:8080`、`10.253.82.1:8080`
  返回 HTTP 200；A/B 切换及后台/前台期间 70 次请求全部成功，
  PID 保持 9621。断开并重连 A 时，B 的 35 次请求全部成功。
  HTTP 服务端分别记录来源 `10.253.81.2` 和 `10.253.82.2`。
- 在 B 工作区再加入 C（`10.253.83.0/24`），同一个 `tun0` 持有
  三个地址，三个网段均 HTTP 200。尝试加入与 A 重叠的 D 时显示
  `shared virtual NIC destination ... overlaps ...`，已有三网仍
  HTTP 200。最终 APK 和纠正后的 Console 环境再次通过三网 HTTP。
- Android 强制停止进程后重新打开，三网恢复 HTTP 200。模拟器重启
  改变 boot ID，网络就绪后打开 App 并按系统提示重新授权 VPN，
  三网恢复且 source device ID、machine ID 不变。重启最初的尝试
  早于 Wi-Fi 就绪，登录页正确显示网络不可达；保留该原始失败记录，
  不将这项测试记为无交互自启动。系统设置“忘记 VPN”后引擎显示
  “VPN 已由系统断开”、`tun0` 消失、全部 HTTP 不可达。
- Windows 真机真实 UI + AuthService + CorePlatformRuntime 测试通过：
  已有 A 节点自动恢复 HTTP 200，切 B 后 A 仍可访问；目标审批前
  显示 pending，审批后 A/B 均 HTTP 200。切换保持 canonical device
  ID 和服务 PID 51064，断 A 后 B 仍 HTTP 200，退出后 PID 为 0、B
  不可达。核心版本 `2.7.0-8b7f1f01`。证据为
  `windows-results.json`、`windows-integration-test.log`；测试后删除
  专用服务及远端测试凭据，恢复原 preferences。`9d74800` 又完整
  复验通过（PID 51512），证据为 `windows-final-results.json` 和
  `windows-final-integration-test.log`。
- 最终独立审查与 Android 撤权实测共同发现：Console 已正确切断
  B/C 流量、保留 A，但页面刷新后仍显示旧 B/C 连接。该问题属于
  本次引入的连接缓存对账遗漏，已在 `9d74800` 修复：常规网络和
  节点读取同步现有缓存，保留并发操作保护；实例统计缺失时重新
  检查就绪，普通刷新不覆盖明确的实例错误。审查定向复核通过，
  无其余高置信 blocker/major。
- Android 最终候选先通过三网 HTTP 200，再撤销目标 B 的设备共享。
  无需重启 App，普通刷新即清除 B/C 旧 IP，连接数 3→1，B 页显示
  尚未加入网络；A 仍 HTTP 200、B/C 不可达。设置页退出登录后回到
  登录页，`tun0` 消失、三个网段均不可达。对应原始证据为
  `android-final-target-revoked*`、`android-final-signed-out*`。
- Android Wi-Fi 关闭再打开后，原 A 网络约 20 秒恢复 HTTP；保留
  恢复前失败请求，未删除样本或将网络中断期间记为连接成功。

### 收尾

测试后按原始 Compose 文件恢复 Console，逐项比较容器环境变量和
镜像与独占前快照完全一致，公共地址恢复为本地 HTTPS，登录端点
GET 返回 302。仅恢复本任务改动的 `download_stable_version` 和
`web_config_server_url` 两个发布字段，均回到原空值。

删除专用探测容器、测试网络与 B 工作区，移除四个测试设备，撤销
探测注册密钥；临时配额恢复，未发布的测试套餐归档，专用管理及
owner 会话删除。原 A 工作区保留。Android 留下最终 APK，但清除
本次测试账号的本地状态；Windows 无残留测试服务、进程或凭据。
恢复核验见 `environment-restored.json`、`cleanup-results.json`。

交付仅含本 App 和随附 Android 核心补丁；未修改 Console 产品代码，
未发布生产或推送远端。arm64 完成构建及符号校验，实际 Android E2E
运行于 x86_64 模拟器，未将其表述为 arm64 真机验证。

### 已发现的范围外问题

- Windows 现有安装器向核心 service install 传递 `--` 参数，而
  测试环境提供的核心要求 `--core-args`；首次安装被错误归类为需要
  提权。该路径在本次修改前已存在，本任务不夹带安装器修复。
  Windows 多工作区测试使用正确 CLI 参数预装的真实专用服务，再
  由 App 原有 `readStatus` 路径接管；不把此结果算作首次安装通过。
