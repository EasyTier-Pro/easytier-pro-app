# 项目指南

## 产品背景
本仓库是 EasyTier Pro 的 Flutter 客户端应用。
该产品属于零信任组网系统，能力范围对齐 Tailscale，但需要满足中国大陆的合规化要求。
在实现功能时，可以参考 Tailscale 类似的产品行为，但应优先使用 EasyTier Pro 自身的术语、流程和合规约束，避免直接照搬。

## 关联系统
- 中心控制台仓库：https://github.com/EasyTier-Pro/easytier-console
- 中心控制台线上环境：https://console.easytier.net/
- 本地 E2E 测试环境：http://10.147.223.128:14173/
- EasyTier 核心仓库：https://github.com/EasyTier/EasyTier

## 架构指引
- 将本仓库视为客户端应用层，不要在这里发明本应由控制台或后端定义的控制面行为。
- 如果后端契约、认证流程、设备生命周期或网络编排逻辑不清楚，优先查看中心控制台仓库。
- 如果隧道行为、节点互联、路由或 Mesh 组网实现细节不清楚，优先查看 EasyTier 核心仓库。
- 产品语言尽量与零信任组网概念保持一致，例如设备、用户、网络、策略、路由、中继等。

## 构建与测试
- 安装依赖：`flutter pub get`
- 静态分析：`dart analyze`
- 运行测试：`flutter test`
- 运行 Windows 桌面端：`flutter run -d windows`

## Flutter 桌面端无障碍与语义树
- Windows 桌面端已在 `lib/main.dart` 中对应用子树使用 `ExcludeSemantics`，以避免 Flutter/ForUI 的动态 `Tooltip`、`OverlayPortal`、滚动区域和动画语义树反复触发 Windows `accessibility_bridge.cc` / `Failed to update ui::AXTree` 日志。
- 该策略会牺牲 Windows 屏幕阅读器语义支持，但可以从源头避免向 Windows AXTree 提交复杂动态 semantics update；不要再为这类日志做局部猜测式修复，例如反复调整列表 key、局部包裹 `Semantics` 或过滤日志。
- 如果未来明确要恢复 Windows 无障碍能力，必须先撤销全局 `ExcludeSemantics`，再基于可复现步骤系统验证 `Tooltip`、`FTooltip`、`FPopoverMenu`、`OverlayPortal`、`ListView`、`GridView`、`AnimatedSwitcher`、图表和动态表单的语义树稳定性。
- 这类 native/engine 层日志通常无法通过 `FlutterError.onError` 或 `runZonedGuarded` 捕获，不要优先用 Dart 异常处理兜底。

## 约定
- 优先做最小且聚焦的改动，并保持与现有 Flutter 项目结构一致。
- 除非任务明确要求，否则不要把只适用于生产环境的地址硬编码进代码；应优先保留对本地 E2E 和线上环境都友好的可配置路径。
- 在增加 UI 或网络能力时，保持对桌面端工作流的兼容性。
- 本项目 UI 基于 ForUI。新增或替换交互控件、导航、表单、弹窗、菜单、提示等 UI 时，应优先选用 ForUI 已提供的组件和样式；只有 ForUI 缺少对应能力或业务布局需要自定义时，才使用 Flutter/Material 基础组件，并尽量将 Material 使用限制在 `Text`、`Icon`、`Color`、布局等基础层。
- 本项目包含中文文案，源码与文档按 UTF-8 处理。在 Windows/PowerShell 环境中，允许用 PowerShell 查看文件，但不要用 `Get-Content | ... | Set-Content`、PowerShell 正则替换或其他隐式编码写回方式修改包含中文的文件；手工小改优先使用 `apply_patch`，批量机械替换应使用明确指定 UTF-8 的 Node/Dart 脚本。修改后如涉及中文文案，应通过明确 UTF-8 读取校验真实文件内容，不以 PowerShell 终端显示为准。
- 每次完成代码或文档改动后，都要执行一次 `git commit`，提交信息应准确描述本次改动。
- 如果某个需求需要跨仓库协同，明确指出真实的事实来源属于哪一侧：本应用、中心控制台仓库，还是 EasyTier 核心仓库。
