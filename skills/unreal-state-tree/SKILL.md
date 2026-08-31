---
name: unreal-state-tree
description: Unreal Engine StateTree 与 GameplayStateTree 全面参考（版本基线 UE 5.8，分层版本标记，支持后续引擎升级）。覆盖运行时执行模型与生命周期、全部事件/委托/通知、资产与编译产物、实例数据与内存布局、属性绑定与 PropertyRef、组件/AI/BT 集成、编辑器与编译管线、调试与 Trace、自定义扩展（Task/Condition/Evaluator/Consideration/PropertyFunction/Schema/宿主组件）以及已知坑与版本差异。Use when creating or editing StateTree assets, using UStateTreeComponent or StateTreeAIComponent, writing custom StateTree tasks/conditions/evaluators/considerations/property functions/schemas, wiring StateTree transitions/bindings/PropertyRefs/events, debugging StateTree (debugger/trace/RewindDebugger), integrating GameplayStateTree or custom host components, or answering how StateTree works in Unreal Engine 5.
---

# unreal-state-tree

> 版本基线：UE 5.8.0 (Release-5.8, CL 55116800) · 版本标记约定：**[UE 5.x+]**=该版本新增，**[仅 <5.x]**=已移除/旧行为，**[5.8 变更]**=本版变更；现行 API 判定标准=声明无 UE_DEPRECATED 标记。

本技能是 UE 5.x（基线 5.8）StateTree 与 GameplayStateTree 的完整参考，基于本机引擎源码逐文件取证（每条结论带源码路径）。所有 API 引用一律全名。

## 参考文档索引（references/）

| 文档 | 内容 |
|---|---|
| [runtime-execution.md](references/runtime-execution.md) | 执行模型：Start/Tick/Stop 全流程、状态选择与 Considerations 评分、转换请求、RAII Scope、重入防护、并行子树 |
| [assets-types.md](references/assets-types.md) | UStateTree 资产结构、FCompactStateTree* 编译产物、Link 流程、Reference/Overrides、Linked Tree、参数、关键枚举全集、CustomVersion |
| [instance-data.md](references/instance-data.md) | 实例数据三层抽象、Storage 字段、帧布局、评估作用域内存、序列化、并发约定、POD 宏、MaxStates=8 |
| [nodes-builtin.md](references/nodes-builtin.md) | 五类节点基类虚函数契约与调用时序、39 个内置节点（14 条件 + 3 consideration + 3 task + 19 property function）、Blueprint 包装、FinishTask 范式、5.6→5.8 签名变迁表 |
| [property-bindings.md](references/property-bindings.md) | 属性绑定数据流、CopyType 规则、PropertyRef 5.8 异步新模式、参数绑定链、编辑器↔运行时类名对照 |
| [events-async.md](references/events-async.md) | 事件队列语义、约 58 个通知点全集（触发时机/参数/线程）、Weak/Strong/Async 上下文、ScheduledTick 优先级链、ExecutionExtension |
| [gameplay-state-tree.md](references/gameplay-state-tree.md) | UStateTreeComponent 生命周期、ContextRequirements/CollectExternalData、Schema、内置 AI Task、BT 桥接、完成语义 |
| [editor.md](references/editor.md) | 编辑数据模型与两段编译管线、FCompilerManager、dirty 状态机、编辑器 UI 架构、蓝图边界、Diff/Find |
| [debugging-trace.md](references/debugging-trace.md) | Trace 链路、断点/步进/Scrub、RewindDebugger 扩展点、编译开关矩阵、RuntimeValidation |
| [integrations.md](references/integrations.md) | 9 个外部集成点档案（Mass 等）、宿主三形态、10 步自定义宿主接入清单 |
| [customization-guide.md](references/customization-guide.md) | **自定义扩展操作入口**：从零自定义 Task/Condition/Evaluator/Schema/宿主/外部数据/编辑器定制的步骤 |
| [version-deltas.md](references/version-deltas.md) | 5.6/5.7/5.8 版本差异与迁移动作、升级检查清单（引擎升级时优先更新本文件） |
| [pitfalls.md](references/pitfalls.md) | 全局坑索引（语义/线程/性能/编辑器）、疑似引擎缺陷清单、测试盲区 |

## 任务路由

| 你要做的事 | 先读 |
|---|---|
| 理解执行流程/Tick 时机/状态选择/转换语义 | runtime-execution.md |
| 资产结构/Linked Tree/参数覆盖/枚举语义 | assets-types.md |
| 实例数据/内存布局/并发 | instance-data.md |
| 写自定义节点：先拿步骤，再查契约 | customization-guide.md → nodes-builtin.md |
| 绑定/PropertyRef/参数注入 | property-bindings.md |
| 事件/委托/异步/定时调度 | events-async.md |
| 组件宿主/AI 集成/BT 桥接 | gameplay-state-tree.md |
| 编译管线/编辑器机制 | editor.md |
| 调试/断点/Trace/RewindDebugger | debugging-trace.md |
| Mass 等外部集成/自定义宿主参照 | integrations.md |
| 版本差异/引擎升级前核对 | version-deltas.md |
| 行为诡异/结果不符预期/查坑 | pitfalls.md |

## 版本标记与升级约定

- 全部文档头部声明同一版本基线；文内用 `**[UE 5.7+]**` 等行内标记标注版本敏感内容，`5.x` 可替换为具体版本号（如 **[UE 5.7+]**），仅用于有弃用标记/文档证据支撑的版本事实。
- 引擎升级时的更新顺序：先按 [version-deltas.md](references/version-deltas.md) 的「升级检查清单」核对新版本源码 → 更新该文件 → 全局搜索各 references 的行内版本标记做修订。
- 未证实的内容一律显式标注「未证实」并汇入各文档「开放问题」节，不得当作事实引用。

## 使用纪律

- 查 API 用全名在 references/ 内 grep（如 `grep -r "SelectState" references/`）。
- 涉及版本敏感结论时，先查 version-deltas.md；与本机引擎版本不一致时，以本机源码为准并更新标记。
- 写 StateTree 相关 C++ 前遵循 unreal-cpp-style；执行纪律按 unreal-development-workflow；BT 桥接对照可参考 unreal-behavior-trees。
- 文中 `XX §N` / `xx-*.md` 形式的引用指向开发期调研报告（~/.agents/tmp/state-tree-research/），属开发期佐证、非技能分发物，可删；相关结论均已同时内嵌源码路径。
