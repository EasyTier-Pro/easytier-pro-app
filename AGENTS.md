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
- 如果桌面端反复输出 `accessibility_bridge.cc`、`Failed to update ui::AXTree` 或 `Nodes left pending by the update`，优先按 Flutter Engine accessibility/semantics 树更新问题排查，不要当作 Dart 层业务异常处理。
- 优先定位日志出现时正在 rebuild、滚动或动画刷新的 Widget，重点检查 `ListView`、`GridView`、`ReorderableListView`、`AnimatedList`、树形控件、菜单、动态表单、`Overlay`、`Tooltip`、`SelectableText`、`TextField`、自定义 `RenderObject` 和图表刷新区域。
- 动态列表、网格或可重排区域的 item 必须使用业务稳定 ID 作为 key，例如 `ValueKey(item.id)`；不要使用 `UniqueKey()`、`DateTime.now()`、随机数 key；发生插入、删除、重排的列表也不要只使用 `ValueKey(index)`。
- 对频繁变化且不需要逐节点无障碍读取的复杂展示区域，可以局部使用 `ExcludeSemantics(child: ...)` 验证并降低语义树抖动，例如装饰性图表、过渡动画或非交互状态装饰。
- 对需要保留无障碍能力的复杂区域，优先使用 `Semantics(container: true, label: ..., child: ...)` 建立稳定语义边界，避免滚动、切换或动画时语义节点被频繁插入、删除、重排。
- 这类 native/engine 层日志通常无法通过 `FlutterError.onError` 或 `runZonedGuarded` 捕获，不要优先用 Dart 异常处理兜底。
- 升级 Flutter stable 后，执行 `flutter clean && flutter pub get` 重新验证；如果只是本地开发日志噪音，可临时在 IDE、logcat 或 CI 日志采集侧过滤 `accessibility_bridge.cc` 或 `Failed to update ui::AXTree`，但最终仍应定位触发 UI。

## 约定
- 优先做最小且聚焦的改动，并保持与现有 Flutter 项目结构一致。
- 除非任务明确要求，否则不要把只适用于生产环境的地址硬编码进代码；应优先保留对本地 E2E 和线上环境都友好的可配置路径。
- 在增加 UI 或网络能力时，保持对桌面端工作流的兼容性。
- 本项目包含中文文案，源码与文档按 UTF-8 处理。在 Windows/PowerShell 环境中，允许用 PowerShell 查看文件，但不要用 `Get-Content | ... | Set-Content`、PowerShell 正则替换或其他隐式编码写回方式修改包含中文的文件；手工小改优先使用 `apply_patch`，批量机械替换应使用明确指定 UTF-8 的 Node/Dart 脚本。修改后如涉及中文文案，应通过明确 UTF-8 读取校验真实文件内容，不以 PowerShell 终端显示为准。
- 每次完成代码或文档改动后，都要执行一次 `git commit`，提交信息应准确描述本次改动。
- 如果某个需求需要跨仓库协同，明确指出真实的事实来源属于哪一侧：本应用、中心控制台仓库，还是 EasyTier 核心仓库。
