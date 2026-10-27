# 多工作区与移动端多网络

## 目标与授权范围

2026-10-28 确认：桌面端和移动端提供顶栏工作区切换入口；切换仅改变
浏览范围，原工作区的网络保持连接，允许多个工作区的网络同时运行。
移动端使用一个系统 VPN 承载多个 EasyTier 实例。

实现涉及本 App 和 EasyTier 核心的移动端桥接；复用 Console 现有设备
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

桌面顶栏常驻“工作区名称 ▾”；移动端直接点击顶栏工作区名称打开
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

## 移动端运行时

核心仓库为现有聚合配置和批量 TUN attach 增加薄桥接接口，保持路由
选择、冲突判断和成员所有权在核心内。App 原生 VPN 服务维护实例
集合并安装核心返回的地址、路由和 DNS，不在 Dart/Swift/Kotlin 重写
路由算法，也不为每个网络建立一个系统 VPN。

新增或移除成员时更新聚合配置；最后一个成员退出才关闭系统 VPN。
权限撤销、退出账号等全局操作停止全部成员。实例删除或被拒绝的
处理不得错误关闭仍有成员的 VPN。

Android 保留一个 VpnService，按聚合结果更新系统接口。iOS 保留
一个 PacketTunnelProvider 和 packetFlow 数据桥。系统设置和 FD
交接串行执行，沿用现有代次/释放确认，避免旧回调释放新接口。
就绪按实例 ID 判断，不能把全局 VPN 已启动当成所有网络成功。

升级 Android 原生核心，并核对 iOS 固定核心及本地补丁。保留必要的
事件、就绪确认和 Darwin FD 行为；不将全部补丁上游化或无关核心
重构作为本需求的前置条件。

## 实施与验收顺序

1. 完成设计审查、设备绑定与浏览工作区解耦、共享授权和入口。
2. 补齐核心桥接，接入 Android 多实例运行时，优先完成 Android E2E。
3. 完成 Windows 桌面 E2E，接入和验证 iOS 原生多实例路径。
4. 冻结候选，完成代表性回归、完整 diff 审查和最终证据记录。

使用 `casdoor-rehearsal-android` Docker 模拟器及本机 Console
`http://10.147.223.128:14173/`。Windows 测试机为
`codexdiag@10.147.223.237`；Mac 为 `admin@10.144.0.2`，iOS 数据面
需连接的 iPhone 真机，模拟器只能验证 UI 和非 VPN 原生行为。
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

- 2026-10-28：方案经用户确认；优先 Android Docker 模拟器及本机
  Console E2E。Android 容器在运行，Windows/Mac SSH 可达；代码尚未修改。
