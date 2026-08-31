# StateTree 资产结构与类型（UStateTree · FCompactStateTree* · Link · Reference · 枚举）

> 版本基线：UE 5.8.0 (Release-5.8, CL 55116800) · 版本标记约定：**[UE 5.x+]**=该版本新增，**[仅 <5.x]**=已移除/旧行为，**[5.8 变更]**=本版变更；现行 API 判定标准=声明无 UE_DEPRECATED 标记。

## TL;DR

- `UStateTree : UDataAsset` 是双格式资产：`EditorData`（WITH_EDITORONLY_DATA，编辑期）+ 编译产物本体（Schema 实例、Frames/States/Transitions/Nodes、四套实例容器、三套 ID 映射、Parameters、Extensions、TaskCompletionDispatchers）。
- 运行可用判定只有 `IsReadyToRun()` = `States.Num()>0 && CompileStatus==Executable && PropertyBindings.IsValid()`；`ECompileStatus` 默认构造值是 **Link**（≠编译完成，是待链接信号）。
- `Nodes`（`FInstancedStructContainer`）是 Evaluators/Conditions/Considerations/Tasks/PropertyFunctions **混排容器**，切片常量（EvaluatorsBegin/Num 等）是唯一正确遍历方式。
- 三套 ID↔索引映射的运行时查询全是**线性 FindByPredicate（O(n)）**，高频调用必须缓存结果。
- `FCompactStateTreeState` 有 **18 个 `uint8:1` 位标志**（4 个 tick 位无 UPROPERTY，由 Link 阶段 `UpdateRuntimeFlags()` 重算以支持 hotfix）。
- Link 五步：`ValidateInstanceData` → `LinkExternalData`（`FStateTreeLinker`）→ `UpdateRuntimeFlags` → `PatchBindings` → Executable；`ExternalDataDescs` 是 Transient，不序列化。
- ⚠️ `FStateTreeReferenceOverrides` 运行时匹配实为 `MatchesTag` **层级匹配**，与结构注释 "exact match" 矛盾；首条命中生效、表序敏感。
- Parameters 四层：资产默认 → Reference 覆盖 → Start 注入 → InstanceStorage；**[5.8 变更]** 弃用 `SetGlobalParameters(FInstancedPropertyBag)` 与 `FCompactStateTreeParameters` 成员直访。
- `FStateTreeCustomVersion` 整体 UE_DEPRECATED 但 GUID 仍注册生效（20 枚举项，LatestVersion=19）；`LatestCustomAssetSavedVersion=1` 是资产级重存提示线。
- 枚举正名：树级 `EStateTreeRunStatus`、任务级 `UE::StateTree::ETaskCompletionStatus`；**`EStateTreeCompletionStatus` 在 5.8 源码中不存在**。

## 目录

1. [证据约定与文档分工](#1-证据约定与文档分工)
2. [UStateTree 资产结构全解](#2-ustatetree-资产结构全解)
3. [编译产物结构逐字段（FCompactStateTree\*）](#3-编译产物结构逐字段fcompactstatetree)
4. [Link 流程（UStateTree::Link）](#4-link-流程ustatetreelink)
5. [Linked / LinkedAsset / Subtree 机制](#5-linked--linkedasset--subtree-机制)
6. [FStateTreeReference 参数化引用](#6-fstatetreereference-参数化引用)
7. [Parameters 与 GlobalParameters 四层体系](#7-parameters-与-globalparameters-四层体系)
8. [序列化兼容锚点：FStateTreeCustomVersion 与 CustomAssetSavedVersion](#8-序列化兼容锚点fstatetreecustomversion-与-customassetsavedversion)
9. [关键枚举全集](#9-关键枚举全集)
10. [辅助类型与设置](#10-辅助类型与设置)
11. [弃用 API 单列表](#11-弃用-api-单列表)
12. [开放问题](#12-开放问题)

## 1. 证据约定与文档分工

- 源码根缩写（下文引用均相对此根）：
  - **RM** = `E:\UnrealEngine\UE_5.8\Engine\Plugins\Runtime\StateTree\Source\StateTreeModule`
  - **EM** = `E:\UnrealEngine\UE_5.8\Engine\Plugins\Runtime\StateTree\Source\StateTreeEditorModule`
- 证据标注：【源码】= 本机 5.8.0 源码直接证实（附相对路径+行号）；【推断】= 由证据合理推断；【未证实】= 无本地证据，汇入 §12。
- **本文档分工边界**：编译管线怎么跑（两段编译/FCompilerManager/dirty 状态机）→ `editor.md`；绑定编译细节 → `property-bindings.md`；节点基类虚函数契约 → `nodes-builtin.md`；实例数据序列化与运行时布局 → `instance-data.md`；执行语义 → `runtime-execution.md`。本文档写**数据契约与 Link**。

## 2. UStateTree 资产结构全解

### 2.1 双格式资产总览

`UStateTree : UDataAsset`（MinimalAPI + `UE_API` 细粒度导出，BlueprintType）【源码 RM\Public\StateTree.h】。编辑期数据存 `EditorData`（`UStateTreeEditorData`，WITH_EDITORONLY_DATA，模型详见 editor.md）；编译产物直接存在资产本体的私有字段上（注释明示 "Data created during compilation, source data in EditorData"）【源码 RM\Public\StateTree.h L432-644】。5.8 中 `UStateTree` 本体**没有** Start/Tick/Stop 入口，执行完全走 `FStateTreeExecutionContext`（friend 声明见 RM\Public\StateTree.h L675-681）。

### 2.2 编译产物字段（"Data created during compilation"）

| 字段 | 类型 | 语义 |
|---|---|---|
| `Schema` | `TObjectPtr<UStateTreeSchema>`，UPROPERTY(Instanced) | 编译用 Schema 的**实例**（非类引用）；编译期从 `EditorData->Schema` DuplicateObject 而来（editor.md 主写）【源码 EM\Private\StateTreeCompiler.cpp L534】 |
| `Frames` | `TArray<FCompactStateTreeFrame>` | 每棵"执行子树"一个 frame：树根 + 每个 Subtree 根各一个（编译器对 `Parent.IsValid()==false` 的状态建 frame）【源码 EM\Private\StateTreeCompiler.cpp L894-903】 |
| `States` | `TArray<FCompactStateTreeState>` | 运行时状态扁平数组，**root state at index 0**（`FStateTreeStateHandle::Root = handle(0)` 与之对应）【源码 RM\Public\StateTree.h L457、RM\Private\StateTreeTypes.cpp L52】 |
| `Transitions` | `TArray<FCompactStateTransition>` | 全树扁平转换表；状态经 `TransitionsBegin/Num` 切片引用 |
| `Nodes` | `FInstancedStructContainer` | 节点池：Evaluators/Conditions/Considerations/Tasks/PropertyFunctions 混排（**不含状态参数**）；切片常量见 §2.2 末行 |
| `DefaultInstanceData` | `FStateTreeInstanceData` | 默认节点实例数据，布局 = `[全局 Evaluators 实例 → 全局 Tasks 实例（共 NumGlobalInstanceData 个）→ 逐状态的 参数+EventData+任务实例]`【源码 EM\Private\StateTreeCompiler.cpp L579-616】 |
| `DefaultEvaluationScopeInstanceData` | `UE::StateTree::InstanceData::FInstanceContainer` | 评估作用域默认实例（条件/考虑度/PropertyFunction 共享内存布局模板） |
| `DefaultExecutionRuntimeData` | 同上 | 执行期运行时数据默认实例（tasks/conditions 的 ExecutionRuntimeData 模板） |
| `SharedInstanceData` | `FStateTreeInstanceData` | 共享节点实例数据（条件/考虑度旧路径）；运行时经 `GetSharedInstanceData()` 按线程惰性复制到 `PerThreadSharedInstanceData`（`FTransactionallySafeRWLock` 保护）【源码 RM\Private\StateTree.cpp L188-238、L472-488】 |
| `ContextDataDescs` | `TArray<FStateTreeExternalDataDesc>` | Schema 强制的上下文数据描述；`NumContextData` = Parameters(1) + ContextData 数【源码 EM\Private\StateTreeCompiler.cpp L550、L570】 |
| `PropertyBindings` | `FStateTreePropertyBindings`（: `FPropertyBindingBindingCollection`） | 绑定集合（SourceStructs + PropertyPathBindings + PropertyReferencePaths + PropertyAccesses）【源码 RM\Public\StateTreePropertyBindings.h L367-386】；细节 → property-bindings.md |
| `PropertyFunctionEvaluationScopeMemoryRequirements` | `TArray<FMemoryRequirement>` | **Link 阶段**在 `PatchBindings()` 末尾按 CopyBatch 计算【源码 RM\Private\StateTree.cpp L1308-1332】 |
| `TaskCompletionDispatchers` | `TArray<UE::StateTree::FTaskCompletionDispatcher>` | 任务完成广播表：{Dispatcher GUID, TaskNodeIndex, Condition(Succeeds/Fails/Completes)}【源码 RM\Public\StateTreeDelegate.h L107-127】 |
| `Extensions` | `TArray<TObjectPtr<UStateTreeExtension>>` | 资产扩展对象（Outer=UStateTree，DefaultToInstanced）；运行时模块无私有 Add API，注入走编辑器 `IStateTreeCompilerCallbacks::AddExtension`（→ editor.md/customization-guide.md） |
| `IDToStateMappings` / `IDToNodeMappings` / `IDToTransitionMappings` | `TArray<FStateTreeStateIdToHandle>` / `TArray<FStateTreeNodeIdToIndex>` / `TArray<FStateTreeTransitionIdToIndex>` | 三套 Guid↔运行时索引映射，编译期生成（→ §2.4 性能警告） |
| `Parameters` | `FInstancedPropertyBag` | 树级默认参数包；`GetDefaultParameters()` 返回它（→ §7）【源码 RM\Public\StateTree.h L519-525】 |
| `LastCompiledEditorDataHash` | `uint32` | 上次编译的 EditorData 哈希；用于 Trace 匹配与 `IsDataValid` 的"未编译"警告【源码 RM\Private\StateTree.cpp L442-450】 |
| `CompletionGlobalTasksMask`；`NumContextData` / `NumGlobalInstanceData` / `EvaluatorsBegin/Num` / `GlobalTasksBegin/Num` | `uint32` / `uint16` | 全局任务完成掩码 + Nodes 布局切片常量（Evaluators → GlobalTasks 顺序） |

### 2.3 Link 产物与运行标志字段

| 字段 | 语义 |
|---|---|
| `ExternalDataDescs` | `UPROPERTY(Transient)`，Link 阶段由 Linker 产出（节点 LinkExternalData 去重合并），**不序列化**，每次加载重算【源码 RM\Private\StateTree.cpp L867、RM\Private\StateTreeLinker.cpp L16-40】 |
| `bHasGlobalTransitionTasks` / `bHasGlobalTickTasks` / `bHasGlobalTickTasksOnlyOnEvents` / `bCachedRequestGlobalTick` / `bCachedRequestGlobalTickOnlyOnEvents` | 全局任务 tick 缓存位，`UpdateRuntimeFlags()` 重算【源码 RM\Private\StateTree.cpp L919-1026】 |
| `bScheduledTickAllowed`（来自 Schema）/ `StateSelectionRules`（缓存 Schema 规则）/ `CompletionGlobalTasksControl` / `ParameterDataType` | Schema 派生缓存，同函数回填 |

源码注释明示 tick 位在运行时重算的原因："Set the tick flags at runtime instead of compilation. This is to support hotfix"——同函数还回填每个 `FCompactStateTreeState` 的 4 个 tick 位与 `EnterCondition/ConsiderationEvaluationScopeMemoryRequirement`、每个 `FCompactStateTransition` 的 `ConditionEvaluationScopeMemoryRequirement`。

### 2.4 编译/脏状态机字段与关键判定

| 字段 | 语义 |
|---|---|
| `ECompileStatus CompileStatus`（私有枚举，非 UPROPERTY） | `Public`（导出依赖需编译）→ `Internal` → `Link`（已编未链）→ `Executable`（可用）。**默认构造值是 `Link`**【源码 RM\Public\StateTree.h L571-584】 |
| `EDirtyStatus EditorDataDirtyStatus`（WITH_EDITORONLY_DATA） | `Public/Internal/Link/None`；编译（成败均可）后回到 None；判定规则注释见 RM\Public\StateTree.h L587-606；与 CompileStatus 正交（编译失败不改 dirty） |
| `bCompilationPending`（WITH_EDITOR） | 资产在编译队列中；`IsReadyToRun()`/`IsDataValid()` 会触发 `CompileIfChanged()` 同步刷队列【源码 RM\Private\StateTree.cpp L48-60、L453-458】 |
| `OutOfDateStructs`（WITH_EDITORONLY_DATA） | 实例数据类型 reinstanced 后待替换集合；`ValidateInstanceData()` 在编辑器构建下不报错而是收集到这里【源码 RM\Private\StateTree.cpp L662-724】 |
| `CustomAssetSavedVersion`（WITH_EDITORONLY_DATA，UPROPERTY） | 资产级保存版本快照（→ §8.2） |

关键判定【源码 RM\Private\StateTree.cpp L48-60、L240-266】：

- `IsReadyToRun()` = `States.Num() > 0 && CompileStatus == Executable && PropertyBindings.IsValid()`——**唯一可信的"可运行"信号**。
- `HasCompatibleContextData(Other)`：逐项要求 Other 的 `ContextDataDescs.Struct` 是本树对应 Struct 的子类——LinkedAsset 覆盖校验用。

> ⚠️ **坑：`ECompileStatus` 默认值是 Link，不是 Public**。新建/未编译资产一上来就是 Link 态；`Link()` 遇 Public/Internal 直接失败。Link 态语义是"数据可能已编译、需要（重新）链接"，勿当"编译完成"信号，必须用 `IsReadyToRun()`。

### 2.5 三套 ID↔索引映射与线性查找代价（性能警告）

| 查询 API | 映射数组 | 查找方式 |
|---|---|---|
| `UStateTree::GetStateHandleFromId(FGuid)` ↔ `GetStateIdFromHandle` | `IDToStateMappings` | `FindByPredicate` 线性 O(n)【源码 RM\Private\StateTree.cpp L67-173】 |
| `UStateTree::GetNodeIndexFromId(FGuid)` / `GetNodeIdFromIndex(FStateTreeIndex16)` | `IDToNodeMappings` | 同上 |
| `UStateTree::GetTransitionIndexFromId(FGuid)` / `GetTransitionIdFromIndex(FStateTreeIndex16)` | `IDToTransitionMappings` | 同上 |
| `UStateTree::GetStateHandleFromGameplayTag(FGameplayTag, EStateGameplayTagQueryMethod)` | 遍历 `States` | BFS 兄弟链遍历（`GetNextSibling()`），匹配方式 `Includes` / `MatchesExact` 二选一（嵌套枚举 `UStateTree::EStateGameplayTagQueryMethod`） |

> ⚠️ **坑：全部是 O(n) 线性查找**。每帧按 Tag/Guid 找状态（如事件路由、调试查询）必须缓存结果；`GetStateHandleFromGameplayTag` 还要遍历兄弟链，代价更高。

## 3. 编译产物结构逐字段（FCompactStateTree\*）

全部定义于 RM\Public\StateTreeTypes.h。命名注意：状态结构是 `FCompactStateTreeState`，转换结构是 **`FCompactStateTransition`**（无 StateTree 中缀）。

### 3.1 FCompactStateTreeFrame（L752-768）

| 字段 | 类型 | 语义 |
|---|---|---|
| `RootState` | `FStateTreeStateHandle` | 帧根状态（树根或 Subtree 根） |
| `NumberOfTasksStatusMasks` | `uint8` | 本帧任务完成位掩码所需 int32 组数的最坏情况（含全局任务） |

### 3.2 FCompactStateTreeState（L773-1039，逐字段）

**引用/标识**：`RequiredEventToEnter`（FCompactEventDesc）、`Name`（FName）、`Tag`（FGameplayTag）、`LinkedAsset`（TObjectPtr<UStateTree>，仅 LinkedAsset 态）、`LinkedState`（FStateTreeStateHandle，仅 Linked 态）、`Parent`（FStateTreeStateHandle，根为 Invalid）。

**树形切片（uint16）**：`ChildrenBegin/End`（`GetNextSibling()` 即返回 `ChildrenEnd`——子状态按兄弟链遍历）、`EnterConditionsBegin`、`UtilityConsiderationsBegin`、`TransitionsBegin`、`TasksBegin`。

**参数/事件**：`ParameterTemplateIndex`（FStateTreeIndex16，指向 DefaultInstanceData 中本状态的 `FCompactStateTreeParameters`）、`ParameterDataHandle`（FStateTreeDataHandle；Subtree→`SubtreeParameterData`、其余→`StateParameterData`【源码 EM\Private\StateTreeCompiler.cpp L1177-1184】）、`ParameterBindingsBatch`（FStateTreeIndex16）、`EventDataIndex`（FStateTreeIndex16，进入所需事件实例）。

**效用/调度**：`Weight`（float，效用缩放）、`CustomTickRate`（float，须 ≥0；设置后状态不可睡眠）、`CompletionTasksMask`（uint32）、`CompletionTasksMaskBufferIndex`（uint8 = 最终任务位/32）、`CompletionTasksMaskBitsOffset`（uint8 = 最终任务位%32）、`CompletionTasksControl`（`EStateTreeTaskCompletionType`）。

**计数（uint8）**：`EnterConditionsNum`、`UtilityConsiderationsNum`、`TransitionsNum`、`TasksNum`、`EnabledTasksNum`（@todo 待删）、`InstanceDataNum`（参数+事件+任务条数）、`Depth`（超 `FStateTreeActiveStates::MaxStates` 编译报错【源码 EM\Private\StateTreeCompiler.cpp L1235-1241】）。

**类型/选择**：`Type`（EStateTreeStateType）、`SelectionBehavior`（EStateTreeStateSelectionBehavior；Linked/LinkedAsset 态编译期强制 `TryEnterState`【源码 EM\Private\StateTreeCompiler.cpp L922-926】）。

**位标志（18 个，`uint8:1`，源码 L964-1038 逐行核实）**：

| # | 位 | 默认 | 语义 |
|---|---|---|---|
| 1 | `bCanOverrideLinkedAssetAtRuntime` | true | LinkedAsset 态可被运行时覆盖；状态参数/目标被绑定时编译器置 false【源码 EM\Private\StateTreeCompiler.cpp L935-951】 |
| 2 | `bHasTransitionTasks` | false | 状态含转换处理期要调用的任务 |
| 3 | `bHasStateChangeConditions` | false | 状态含 enter/completed/exit 需求条件 |
| 4 | `bHasTickTasks` ★ | false | 任一任务 bShouldCallTick |
| 5 | `bHasTickTasksOnlyOnEvents` ★ | false | 任一任务 bShouldCallTickOnlyOnEvents（bHasTickTasks 为真时无效） |
| 6 | `bCachedRequestTick` ★ | false | 任务请求每帧 tick（睡眠判定） |
| 7 | `bCachedRequestTickOnlyOnEvents` ★ | false | 仅有事件时请求 tick |
| 8 | `bHasTickTriggerTransitions` | false | 含 OnTick 触发转换 |
| 9 | `bHasEventTriggerTransitions` | false | 含 OnEvent 触发转换 |
| 10 | `bHasDelegateTriggerTransitions` | false | 含 OnDelegate 触发转换 |
| 11 | `bHasCompletedTriggerTransitions` | false | 含 OnStateCompleted 触发转换 |
| 12 | `bHasSucceededTriggerTransitions` | false | 含 OnStateSucceeded 触发转换 |
| 13 | `bHasFailedTriggerTransitions` | false | 含 OnStateFailed 触发转换 |
| 14 | `bCheckPrerequisitesWhenActivatingChildDirectly` | false | 直接激活子状态时是否评估本状态事件/进条件前置 |
| 15 | `bEnabled` | true | 状态启用 |
| 16 | `bConsumeEventOnSelect` | true | 选中即消费所需事件 |
| 17 | `bHasCustomTickRate` | false | 设置了 CustomTickRate |
| 18 | `bCopyParameterBindingsOnTick` | false | 每次任务 tick 拷贝参数绑定（进/出状态总是拷贝） |

★ = 无 UPROPERTY 的 4 个 tick 位，Link 阶段 `UpdateRuntimeFlags()` 重算（hotfix 支持，见 §2.3）；其余 14 个 UPROPERTY 序列化。

**方法**：`GetNextSibling()` / `HasChildren()` / `DoesRequestTickTasks(bHasEvent)` / `ShouldTickTasks(bHasEvent)` / `ShouldTickTransitions(bHasEvent, bHasBroadcastedDelegates)` / `ShouldTickCompletionTransitions(bSucceeded, bFailed)`。

### 3.3 FCompactStateTransition（L667-747，逐字段）

| 字段 | 类型 | 语义 |
|---|---|---|
| `RequiredEvent` | `FCompactEventDesc` | 事件触发（Tag+PayloadStruct） |
| `RequiredDelegateDispatcher` | `FStateTreeDelegateDispatcher` | 委托触发（FGuid ID） |
| `ConditionEvaluationScopeMemoryRequirement` | `FEvaluationScopeMemoryRequirement` | **Link 阶段重算**（非 UPROPERTY） |
| `ConditionsBegin` | `uint16` | 条件切片起点（进 Nodes 全局条件池） |
| `State` | `FStateTreeStateHandle` | 目标状态 |
| `Delay` | `FStateTreeRandomTimeDuration` | 延迟（→ §3.5） |
| `Trigger` | `EStateTreeTransitionTrigger` | 触发位集（可组合；默认 None） |
| `Priority` | `EStateTreeTransitionPriority` | 默认 **Normal**；并发触发取最高优先级中第一条 |
| `Fallback` | `EStateTreeSelectionFallback` | 选不中目标时的回退（默认 None） |
| `ConditionsNum` | `uint8` | 条件数 |
| `ChangeTypeTargetStateRule` | `EStateTreeTransitionChangeTypeRules` | ForceChanged/ForceSustained/Default；经 `GetStateSelectionRulesForTransition()` 映射为 `ReselectedStateCreatesNewStates` 规则的加/减【源码 RM\Public\StateTreeTypes.h L683-695】 |
| `bTransitionEnabled:1` / `bConsumeEventOnSelect:1` | 位 | 启用开关（默认 true）；选中即消费事件（默认 true） |

### 3.4 FCompactStateTreeParameters（L1041-1088）**[5.8 变更]**

- 双载体：`Parameters`（FInstancedPropertyBag，状态参数包）**或** `InstancedParameters`（FInstancedStruct，LinkedAsset 覆盖包）。
- 成员 `Parameters` 直接访问已弃用：`UE_DEPRECATED_FORGAME(5.8)`，统一走 `GetValue()` / `GetMutableValue()`（返回 `FConstStructView` / `FStructView`，内部按哪个载体有效二选一）。
- 构造/拷贝/移动用 PRAGMA 包裹抑制弃用警告；`explicit` 构造分别收 PropertyBag 与 FInstancedStruct。

### 3.5 FCompactEventDesc（L610-650）与 FStateTreeRandomTimeDuration（L536-594）

- `FCompactEventDesc`：`PayloadStruct`（TObjectPtr<const UScriptStruct>）+ `Tag`；`IsSubsetOfAnotherDesc` 双向 Tag 匹配 + Payload `IsChildOf`；`DoesEventMatchDesc` 判定事件可用性【源码 RM\Private\StateTreeTypes.cpp L249-263】。
- `FStateTreeRandomTimeDuration`：`Duration`/`RandomVariance` 各 uint16，量化精度 0.01s（约 ±650s 上限）；`GetRandomDuration(FRandomStream)` 闭区间取整随机。

### 3.6 句柄与索引类型

- `FStateTreeStateHandle`（L274-323）：uint16 Index；保留值 `Invalid=-1 / Succeeded=-2 / Failed=-3 / Stopped=-4`；静态单例 Invalid/Succeeded/Failed/Stopped/Root；`IsCompletionState()` / `ToCompletionStatus()` / `FromCompletionStatus()`【源码 RM\Private\StateTreeTypes.cpp L63-99】。
- `FStateTreeDataHandle`（L406-515）：{`EStateTreeDataSourceType Source`, `uint16 Index`, `FStateTreeStateHandle StateHandle`}；`ActiveInstanceData*` 强制要求有效 StateHandle（check），`GlobalParameterData`/`ExternalGlobalParameterData` 允许 Index 无效。`Describe()` 调试名注意：`StateParameterData` 的调试名是 **"LinkedParam"**（如 `LinkedParam[2]`），勿被误导。
- `FStateTreeIndex16` / `FStateTreeIndex8`（RM\Public\StateTreeIndexTypes.h）：0xffff / 0xff 为 Invalid；`AsInt32()` 把 0xffff 映射回 `INDEX_NONE`；`FStateTreeIndex8` 上限 254；带 `SerializeFromMismatchedTag` 跨类型迁移兼容【源码 RM\Public\StateTreeIndexTypes.cpp L8-61】。

### 3.7 EStateTreeDataSourceType（绑定与实例数据的统一寻址键）

`None` + 19 个数据源值（共 20 枚举项，源码 L328-388 逐行核实）：Global/Active/Shared/EvaluationScope/ExecutionRuntime 五族各有 Struct/Object 双形态（10 值）+ `ExecutionRuntimeDataAny`（运行时探明形态）+ `ContextData` / `ExternalData` / `GlobalParameterData` / `SubtreeParameterData` / `StateParameterData` / `TransitionEvent` / `StateEvent` / `ExternalGlobalParameterData`。`EStateTreeParameterDataType`（L392-396）独立两值：`GlobalParameterData`（默认）/ `ExternalGlobalParameterData`（→ §7）。

## 4. Link 流程（UStateTree::Link）

运行时模块自含（不依赖编辑器模块）。前置：`CompileStatus` 必须已是 Link/Executable，Public/Internal 直接失败【源码 RM\Private\StateTree.cpp L783-917】。五步主链：

```
Link()
 ├─ 0. ResetLinked()                  // ExternalDataDescs 清空、PerThreadSharedInstanceData 清空、
 │                                    // Executable→Link、DirtyStatus None→Link
 ├─ 1. ValidateInstanceData()         // 逐节点比对 Default/Shared/EvaluationScope/ExecutionRuntime
 │                                    //   四容器实例类型 vs 节点期望类型；reinstanced 类型进 OutOfDateStructs
 │                                    //   （编辑器构建收集不报错）
 ├─ 2. LinkExternalData               // 构造 FStateTreeLinker(this)；逐节点 Node->Link(Linker)
 │                                    //   （典型：LinkExternalData(TStateTreeExternalDataHandle<T>)，
 │                                    //   Schema::IsExternalItemAllowed 校验 → 去重进 ExternalDataDescs）
 │                                    //   再 Schema->Link、Extensions[*]->Link
 ├─    UpdateRuntimeFlags()           // 回填 tick 位 + 评估内存要求 + Schema 派生缓存（§2.3）
 │                                    //   + 四容器 AreAllInstancesValid()（缺实例=加载不完整，报错）
 ├─ 3. PatchBindings()                // authoritative class 修正 → 状态参数/全局参数 bag 结构刷新 →
 │                                    //   DataViews 重建 → 逐绑定 UpdateSegmentsFromValue →
 │                                    //   PropertyFunctionEvaluationScopeMemoryRequirements
 │                                    //   + Linked/LinkedAsset 参数一致性校验（§5.1）
 ├─    PropertyBindings.ResolvePaths()
 └─ 4. CompileStatus = Executable     // EditorDirtyStatus Link→None
```

**触发时机**：`PostLoad`（先触发 `UE::StateTree::Delegates::Private::OnStateTreeAssetLoaded` 委托让编辑器排队编译；若无人编译且 `LastCompiledEditorDataHash != 0` 则同步 Link）【源码 RM\Private\StateTree.cpp L490-570】、`Serialize(ModifyingWeakAndStrongReferences)`（BP 重编译重绑定，L594-613）、`IsDataValid`。

**失败语义**：统一 `Failure()` = `MarkAsModified(false)` + return false（编辑器构建，允许重试）；打包/Shipping 构建下 Link 失败的资产直接不可用（PostLoad 只打 Warning，无自动重编）【源码 RM\Private\StateTree.cpp L560-569】。

## 5. Linked / LinkedAsset / Subtree 机制

### 5.1 三种链接形态与编译期数据契约

`EStateTreeStateType`：`State`（任务+子状态）/ `Group`（仅子状态）/ `Linked`（链树内 Subtree）/ `LinkedAsset`（链另一 UStateTree 资产根）/ `Subtree`（被链目标）【源码 RM\Public\StateTreeTypes.h L152-169】。

| 形态 | 编译期契约 | 产物 |
|---|---|---|
| Linked | 禁止链到自身祖先（死循环检测）；目标必须是 Subtree | `CompactState.LinkedState = GetStateHandle(SourceState->LinkedSubtree.ID)`【源码 EM\Private\StateTreeCompiler.cpp L1501-1553】 |
| LinkedAsset | 禁止链自身（递归）；目标资产必须有 Schema 且 **Schema 类必须相同** | `CompactState.LinkedAsset`【源码 EM\Private\StateTreeCompiler.cpp L1554-1593】 |
| 两者共性 | 不允许有子状态（编译 Warning）；`SelectionBehavior` 强制 `TryEnterState` | — 【源码 EM\Private\StateTreeCompiler.cpp L860-866、L922-926】 |

Link 阶段再验参数一致性【源码 RM\Private\StateTree.cpp L1100-1172（PatchBindings）】：Linked 态要求本状态与被链状态的 `FCompactStateTreeParameters` 结构相同；LinkedAsset 态要求本状态参数包 == 目标资产 `Parameters.GetPropertyBagStruct()`；Subtree/Linked/LinkedAsset 的 `ParameterTemplateIndex` 必须有效。

### 5.2 FStateTreeStateLink（编辑态链接描述，L1291-1347）

WITH_EDITORONLY_DATA：`Name`（链接时状态名，报错用）/ `ID`（FGuid）/ `LinkType`（编辑期 `EStateTreeTransitionType` 描述，NextState 等目标是编译期解析）；运行时字段 `StateHandle` + `Fallback`。`Type_DEPRECATED` 弃用(all) → `LinkType`，带结构化序列化 + PostSerialize 迁移（< `AddedExternalTransitions` 时 LinkType = Type_DEPRECATED，见 §8.1）。

### 5.3 运行时 LinkedAsset 覆盖（FStateTreeReferenceOverrides）

- 载体：`FStateTreeReferenceOverrides { TArray<FStateTreeReferenceOverrideItem> OverrideItems }`；Item = {`StateTag`（匹配锚）, `FStateTreeReference`}【源码 RM\Public\StateTreeReference.h L172-255】。
- 注入：宿主经 `FStateTreeExecutionContext::SetLinkedStateTreeOverrides(FStateTreeReferenceOverrides)`（传拷贝而非指针；指针重载 UE_DEPRECATED(5.6)，其替代品即本按值版，两重载并存于 RM\Public\StateTreeExecutionContext.h L348-359）。注入校验：覆盖树 `IsReadyToRun()`、`HasCompatibleContextData`、有 Schema、**Schema 类与根树相同**；任一失败整体清空【源码 RM\Private\StateTreeExecutionContext.cpp L1197-1282】。⚠ 防混淆注：组件宿主层（`UStateTreeComponent::SetLinkedStateTreeOverrides`）的校验是 `IsChildOf`——放行当前树 Schema 的**子类**（StateTreeComponent.cpp L523-533）；本处执行上下文层是 `GetClass()==` **严格同类**（StateTreeExecutionContext.cpp L1251），两层语义不同，勿混用预期。
- 生效点：状态选择进入 LinkedAsset 态时 `GetLinkedStateTreeOverrideForTag(NextState.Tag)` 线性遍历 override 表；仅当 `bCanOverrideLinkedAssetAtRuntime` 才生效；覆盖同时替换参数包【源码 RM\Private\StateTreeExecutionContext.cpp L1284-1295、L7143-7158】。
- 组件宿主透传字段 `LinkedStateTreeOverrides`（GameplayStateTreeModule → gameplay-state-tree.md）。

> ⚠️ **坑：运行时覆盖是 `MatchesTag` 层级匹配，不是结构注释声称的 "exact match"**
> `FStateTreeReferenceOverrides` 结构注释（RM\Public\StateTreeReference.h L172-175）与 `FStateTreeReferenceOverrideItem::StateTag` 成员注释（L161，"Exact tag used to match"）都写 exact match，但执行路径实际调用 `StateTag.MatchesTag(Item.StateTag)`（GameplayTag 层级匹配，RM\Private\StateTreeExecutionContext.cpp L1288）。后果：
> 1. 挂**父 Tag** 的 override 会吞掉所有**子 Tag** 的 LinkedAsset 状态；
> 2. `GetLinkedStateTreeOverrideForTag` 取**第一个**命中项——`OverrideItems` 表内顺序敏感（`AddOverride` 对同 Tag 是替换语义，不同 Tag 先入先命中）；
> 3. 依赖"精确匹配"假设的宿主必须用父/子 Tag 设计自行保证语义。
>
> 另一静默坑：状态参数或目标被绑定时编译器把 `bCanOverrideLinkedAssetAtRuntime` 置 false，覆盖不生效且**无报错**【源码 EM\Private\StateTreeCompiler.cpp L935-951、RM\Private\StateTreeExecutionContext.cpp L7142-7143】——LinkedAsset 模板 + 参数覆盖场景优先用 `FStateTreeReference` 的参数覆盖而不是绑定向导。

## 6. FStateTreeReference 参数化引用

定义于 RM\Public\StateTreeReference.h（L1-138 区段）。字段：`StateTree`（TObjectPtr<UStateTree>）、`Parameters`（FInstancedPropertyBag，FixedLayout 语义）、`PropertyOverrides`（TArray<FGuid>，决定哪些属性不随资产默认回填）。

| API | 语义 |
|---|---|
| `IsValid()` / `SetStateTree(UStateTree*)` / `GetStateTree()` / `GetMutableStateTree()` | 资产引用管理 |
| `GetGlobalParameters()` / `GetMutableGlobalParameters()`（返回 `FConstStructView`/`FStructView`） | 取同步后的参数包视图 |
| `GetParameters()` / `GetMutableParameters()` | 原始 PropertyBag |
| `SyncParameters()` | `Parameters.MigrateToNewBagInstanceWithOverrides(StateTree->GetDefaultParameters(), PropertyOverrides)` 并剔除失效覆盖 Guid【源码 RM\Private\StateTreeReference.cpp L8-34】 |
| `RequiresParametersSync()` / `ConditionallySyncParameters()` | 逐属性 `Identical()` 比对非覆盖项；不匹配自动修复并打日志 |
| `IsPropertyOverridden(FGuid)` / `SetPropertyOverridden(FGuid, bool)` | 覆盖标记管理 |

序列化迁移：包版本 < `OverridableParameters` 时所有属性都算覆盖（旧行为全量覆盖）【源码 RM\Private\StateTreeReference.cpp L120-138】。`HasNativeMake` 元数据指向 `UStateTreeFunctionLibrary::MakeStateTreeReference`（BP Make 节点直通）。

## 7. Parameters 与 GlobalParameters 四层体系

数据流：**资产默认 → Reference 覆盖 → 启动注入 → 实例存储**。

| 层 | 载体 | 关键点 |
|---|---|---|
| 1. 资产默认 | `UStateTree::Parameters`（FInstancedPropertyBag，UPROPERTY） | 编译期整包拷贝自 EditorData 根参数；`StateTree->ParameterDataType` 由 `Schema->GetGlobalParameterDataType()` 决定（`EStateTreeParameterDataType`）。`ExternalGlobalParameterData` 模式下参数值由执行上下文外部提供，绑定源 DataHandle 用 `ExternalGlobalParameterData`；5.8 引擎内唯一 Schema 先例是实验插件 UAFStateTree 的 `UAnimNextStateTreeSchema`【源码 E:\UnrealEngine\UE_5.8\Engine\Plugins\Experimental\UAF\UAFStateTree\Source\UAFStateTree\Private\AnimNextStateTreeSchema.cpp L50】 |
| 2. 引用覆盖 | `FStateTreeReference::Parameters` + `PropertyOverrides` | `SyncParameters()` 迁移 bag 保留覆盖（→ §6）；`GetGlobalParameters()` 惰性 `ConditionallySyncParameters()` 自动修复 |
| 3. 启动注入 | `FStartParameters.InitialGlobalParameters`（执行模块） | 组件宿主传 `StateTreeRef.GetGlobalParameters()`；此处只记锚点 → runtime-execution.md |
| 4. 实例存储 | `FStateTreeInstanceStorage::GlobalParameters`（FInstancedStruct，Transient，RM\Public\StateTreeInstanceData.h L424-426） | `SetGlobalParameters(FConstStructView)` 存拷贝；**[5.8 变更]** `SetGlobalParameters(const FInstancedPropertyBag&)` 重载弃用【源码 RM\Public\StateTreeInstanceData.h L335-351】。并树任务 `FStateTreeRunParallelStateTreeTask` 启动子树前校验 bag 结构一致再注入 |

## 8. 序列化兼容锚点：FStateTreeCustomVersion 与 CustomAssetSavedVersion

### 8.1 FStateTreeCustomVersion——弃用但必须继续注册

- struct 整体 `UE_DEPRECATED(all, "Use a stream custom version...")`，但**仍在使用**：`StateTree.cpp L34-40` 以 `FCustomVersionRegistration` 注册 GUID `{0x28E21331, 0x501F4723, 0x8110FA64, 0xEA10DA1E}`（友好名 "StateTreeAsset"）；`UStateTree::Serialize` / `FStateTreeReference::Serialize` / `FStateTreeStateLink::Serialize` 都调 `UsingCustomVersion(GUID)`【源码 RM\Public\StateTree.h L23-81、RM\Private\StateTree.cpp L594-613】。删除该"弃用"struct 会破坏全部旧资产读取。
- 版本值序列（枚举顺序即历史；20 个枚举项，LatestVersion=19）：BeforeCustomVersionWasAdded=0 → SharedInstanceData → GlobalEvaluators → InstanceDataArrays → IndexTypes → AddedEvents → AddedFoo（"Testing mishap" 占位事故值）→ TransitionDelay → AddedExternalTransitions → ChangedBindingsRepresentation → AddedTransitionIds → AddedDataHandlesIds → AddedLinkedAssetState → ChangedExternalDataAccess → OverridableParameters → OverridableStateParameters → StoringGlobalParametersInInstanceStorage → AddedBindingToEvents → AddedCheckingParentsPrerequisites → TickParameterBindings=19。
- 版本感知迁移代码（本模块仅两处）：① `FStateTreeStateLink::PostSerialize`：< `AddedExternalTransitions` 时 `LinkType = Type_DEPRECATED`（NotSet→None）【源码 RM\Private\StateTreeTypes.cpp L131-149】；② `FStateTreeReference::PostSerialize`：< `OverridableParameters` 时全部参数记为 overridden【源码 RM\Private\StateTreeReference.cpp L120-138】。

### 8.2 CustomAssetSavedVersion 与 LatestCustomAssetSavedVersion（资产级，另一条线）

- `UStateTree::LatestCustomAssetSavedVersion = 1`（WITH_EDITOR 静态常量，注释 `// 0 default / 1 with DefaultGlobalParameters`）【源码 RM\Private\StateTree.cpp L42-46】。
- `PreSave` 中非 CDO/Archetype 且非 AutoSave 时写 `CustomAssetSavedVersion = LatestCustomAssetSavedVersion`【源码 RM\Private\StateTree.cpp L392-401】；`GetAssetSavedVersion()` 返回保存值，与 Latest 不匹配时 UI 建议重存。
- **与 §8.1 正交**：`FStateTreeCustomVersion` 是包级（FArchive 维度）序列化版本；`CustomAssetSavedVersion` 是资产级"最后保存时的最新值"快照（UPROPERTY 维度）。5.8 源码内后者无其它消费方。

## 9. 关键枚举全集

> ⚠️ **枚举正名**：树级运行状态是 `EStateTreeRunStatus`（RM\Public\StateTreeExecutionTypes.h L52-69：Running/Stopped/Succeeded/Failed/Unset）；任务级完成状态是 `UE::StateTree::ETaskCompletionStatus`（RM\Public\StateTreeTasksStatus.h L26-41：Running=0/Stopped=1/Succeeded=2/Failed=3，每任务 2 bit 双位面打包——位打包细节 → runtime-execution.md）。**`EStateTreeCompletionStatus` 在 5.8 源码中不存在**，检索或编写代码时勿使用该名。

| 枚举 | 值与语义（全部【源码 RM\Public\StateTreeTypes.h】） |
|---|---|
| `EStateTreeTransitionType`（L75-106） | None / Succeeded（停树或子树，成功）/ Failed / GotoState / Parent / NextState / NextSelectableState / NextParent / NextSelectableParent；`NotSet` 弃用(all)→None。编辑期用于 `FStateTreeStateLink::LinkType`，Next\* 目标编译期解析 |
| `EStateTreeStateSelectionRules`（L109-133，uint32 位集） | None（注释 "Previous (UE 5.6) rules"）/ CompletedTransitionStatesCreateNewStates / CompletedStateBeforeTransitionSourceFailsTransition / ReselectedStateCreatesNewStates；`Default` = 前两者。`UStateTreeSchema::GetStateSelectionRules()` 默认返回前两者（CVar `StateTree.SelectState.*` 可关） |
| `EStateTreeExpressionOperand`（L136-150） | Copy（Hidden）/ And（条件 AND、考虑度 Min）/ Or（条件 OR、考虑度 Max）/ Multiply（仅考虑度 a*b） |
| `EStateTreeStateType`（L152-169） | State / Group / Linked / LinkedAsset / Subtree（→ §5.1） |
| `EStateTreeStateSelectionBehavior`（L171-198） | None（不可直接选中）/ TryEnterState / TrySelectChildrenInOrder / TrySelectChildrenAtRandom / TrySelectChildrenWithHighestUtility / TrySelectChildrenAtRandomWeightedByUtility / TryFollowTransitions；旧名 `TrySelectChildrenAtUniformRandom`/`TrySelectChildrenBasedOnRelativeUtility` 弃用(all)（UENUM 按名序列化需永久保留）。辅助 `IsSelectionBehaviorUsingUtility()` |
| `EStateTreeTransitionTrigger`（L217-242，位集） | None=0(Hidden) / OnStateSucceeded=0x1 / OnStateFailed=0x2 / OnStateCompleted=0x3 / OnTick=0x4 / OnEvent=0x8 / OnDelegate=0x10 |
| `EStateTreeTransitionPriority`（L246-272） | None(Hidden) / Low / Normal / Medium / High / Critical + 全套比较运算符（数值越大优先级越高） |
| `EStateTreeSelectionFallback`（L597-605） | None / NextSelectableSibling |
| `EStateTreeTransitionChangeTypeRules`（L656-662） | ForceChanged / ForceSustained / Default（转换目标"重激活 vs 维持"规则，编辑器 UI 名 "Reactivation"） |
| `EStateTreeExternalDataRequirement`（L1090-1095） | Required（缺数据不能执行）/ Optional |
| `EStateTreePropertyUsage`（L1098-1106） | Invalid / Context / Input / Parameter / Output（属性 Category 元数据 → 绑定用途，编辑器用） |
| `EStateTreeDataSourceType` / `EStateTreeParameterDataType` | → §3.7 / §7 |
| `UE::StateTree::EComparisonOperator`（L59-68）**[5.8 变更]** | Less / LessOrEqual / Equal / NotEqual / GreaterOrEqual / Greater——取代 `EGenericAICheck`（去 AIModule 化；条件节点侧迁移见 version-deltas.md） |
| `EStateTreeTaskCompletionType`（RM\Public\StateTreeTasksStatus.h L16-22） | All（全部完成才算完成）/ Any（任一完成即完成） |
| `UE::StateTree::ETaskCompletionStatus` / `EStateTreeRunStatus` | 见本节正名框 |

## 10. 辅助类型与设置

| 类型 | 要点 |
|---|---|
| `UStateTreeSettings`（RM\Public\StateTreeSettings.h；config=StateTree, defaultconfig） | 极薄：仅 `static UStateTreeSettings& Get()` + `bAutoStartDebuggerTracesOnNonEditorTargets`（非编辑器目标自动起 debugger trace）。**没有**项目级执行参数配置位 |
| `UStateTreeFunctionLibrary`（RM\Public\StateTreeFunctionLibrary.h；Abstract） | BP 库：`SetStateTree(FStateTreeReference&, UStateTree*)` / `MakeStateTreeReference(UStateTree*)`（NativeMakeFunc）/ `K2_SetParametersProperty(Reference, FGuid PropertyID, const int32&)` / `K2_GetParametersProperty(...)`（CustomThunk + CustomStructureParam，按属性 ID 读写引用参数） |
| `FStateTreeAnyEnum`（RM\Public\StateTreeAnyEnum.h） | `uint32 Value` + `TObjectPtr<UEnum> Enum`；`Initialize(UEnum*)` 置为首值；==/!=。绑定 UI 的"任意枚举"载体 |
| `UStateTreeSchema`（RM\Public\StateTreeSchema.h；Abstract） | 虚 `IsStructAllowed/IsClassAllowed/IsExternalItemAllowed/IsStateTypeAllowed/IsStateSelectionAllowed/IsScheduledTickAllowed/GetContextDataDescs/Link(FStateTreeLinker&)`；UE_API 虚 `GetGlobalParameterDataType()/GetStateSelectionRules()`；资产过滤契约 `RequiredAssetDataTags="Schema=<ClassPath>"` + `SchemaCanBeOverriden` 元标签 + `IStateTreeSchemaProvider::GetSchema()`。自定义步骤 → customization-guide.md |
| `UStateTreeExtension`（RM\Public\StateTreeExtension.h；Abstract, DefaultToInstanced, Within=StateTree） | 资产级扩展位：虚 `bool Link(FStateTreeLinker&)`；读取 `UStateTree::GetExtension<T>()` / `K2_GetExtension(TSubclassOf<UStateTreeExtension>)`。注入走编辑器回调 → editor.md |
| `FStateTreeLinker`（RM\Public\StateTreeLinker.h） | Link 阶段解析器：`explicit FStateTreeLinker(TNotNull<const UStateTree*>)` **[UE 5.7+]**（Schema 构造弃用）；模板 `LinkExternalData(T&)`（UObject/UStruct/IInterface 三分发）+ 非模板重载；`EStateTreeLinkerStatus { Succeeded, Failed }`。节点声明外部数据契约 → nodes-builtin.md |
| `FStateTreeStructRef`（RM\Public\StateTreeTypes.h L1198-1276） | `BaseStruct` 元标签约束的属性引用（大结构零拷贝/可写边界）；`Get<T>/GetMutable<T>/GetPtr<T>` 族 + ExportTextItem |
| `FStateTreeDataView`（L1283-1286） | `FPropertyBindingDataView` 别名继承——过渡别名 |
| 实例数据宏（L1357-1386） | `UE_STATETREE_CONSTRUCTED_TRIVIALLY_COPIED_NO_DESTRUCTOR_INSTANCEDATA(Type)` / `UE_STATETREE_ZEROED_...`（现行）；`STATETREE_POD_INSTANCEDATA` 弃用 **[5.8 变更]**（→ §11） |

## 11. 弃用 API 单列表

| API | 弃用标记 | 替代品 | 来源 |
|---|---|---|---|
| `FStateTreeCustomVersion`（整个 struct） | UE_DEPRECATED(all) | "Use a stream custom version"（但 GUID 必须继续注册，§8.1） | RM\Public\StateTree.h L24-27 |
| `EStateTreeTransitionType::NotSet` | UE_DEPRECATED(all) | `None` | RM\Public\StateTreeTypes.h L105 |
| `EStateTreeStateSelectionBehavior::TrySelectChildrenAtUniformRandom` / `::TrySelectChildrenBasedOnRelativeUtility` | UE_DEPRECATED(all)（UENUM 按名序列化需保留） | `TrySelectChildrenAtRandom` / `TrySelectChildrenAtRandomWeightedByUtility` | RM\Public\StateTreeTypes.h L196-197 |
| `FCompactStateTreeParameters::Parameters`（成员直访） | UE_DEPRECATED_FORGAME(5.8) | `GetValue()` / `GetMutableValue()` | RM\Public\StateTreeTypes.h L1080 |
| `FStateTreeStateLink::Type_DEPRECATED` | UE_DEPRECATED(all) | `LinkType` | RM\Public\StateTreeTypes.h L1325-1327 |
| `STATETREE_POD_INSTANCEDATA(Type)` 宏 | UE_DEPRECATED_MACRO(5.8) | `UE_STATETREE_CONSTRUCTED/ZEROED_TRIVIALLY_COPIED_NO_DESTRUCTOR_INSTANCEDATA` | RM\Public\StateTreeTypes.h L1388 |
| `FStateTreeLinker::FStateTreeLinker(const UStateTreeSchema*)` | UE_DEPRECATED(5.7) | 带 `UStateTree*` 的构造 | RM\Public\StateTreeLinker.h L28-31 |
| `UStateTree::OnPreBeginPIE` + 字段 `OnObjectsReinstancedHandle/OnUserDefinedStructReinstancedHandle/OnPreBeginPIEHandle` | UE_DEPRECATED(5.7) | compiler manager（`UE::StateTree::Compiler::FCompilerManager`） | RM\Public\StateTree.h L360-391 |
| `UE::StateTree::Delegates::FOnRequestCompile/OnRequestCompile` | UE_DEPRECATED(5.8) | `UStateTreeEditingSubsystem` 触发编译 | RM\Public\StateTreeDelegates.h L70-76 |
| `FStateTreeEditorPropertyPath`（struct） | UE_DEPRECATED(all) | `FPropertyBindingPath` | RM\Public\StateTreePropertyBindings.h L104 |
| `FStateTreePropertyPathBinding` 两个无 bIsOutputBinding 的构造 | UE_DEPRECATED(5.7) | 带 `bInIsOutputBinding` 版本 | RM\Public\StateTreePropertyBindings.h L141-158 |
| `FStateTreeInstanceStorage::SetGlobalParameters(const FInstancedPropertyBag&)` | UE_DEPRECATED(5.8) | `FConstStructView` 版本 | RM\Public\StateTreeInstanceData.h L338-339 |

## 12. 开放问题

1. 【未证实】`FStateTreeCustomVersion` 各枚举值与 UE 引擎版本号的精确映射（仅 `AddedExternalTransitions`、`OverridableParameters` 两个值有迁移代码可锚定；对照需历史源码）。
2. 【未证实】`LatestCustomAssetSavedVersion=1`（"1 with DefaultGlobalParameters"）的确切行为变化；重存建议 UI 的具体消费方在 5.8 源码内未定位（全插件 grep 仅 4 处）。
3. 【未证实】弃用注释所称 "stream custom version" 替代物：5.8 的 StateTreeModule 内未找到新的 stream custom version 注册（全模块仅旧 GUID 一处注册）。
4. 【未证实/存疑】`CalculateEstimatedMemoryUsage` 把 `DefaultInstanceData.GetStruct(0)` 注释为 "Exec state"，但编译布局索引 0 是首个 Evaluator 实例；运行态执行状态实际存于 `FStateTreeInstanceStorage::ExecutionState`。疑为陈旧注释，对内存估算精度影响未验证【源码 RM\Private\StateTree.cpp L442-450 对照 EM\Private\StateTreeCompiler.cpp L579-616】。
5. 【未证实】非弃用类型（`EStateTreeStateSelectionRules`、`EStateTreeTransitionPriority`、`EStateTreeSelectionFallback`、`FCompactEventDesc` 等）的精确引入版本（仅能确认 5.8 现行形态；版本标记升级时需对照旧版源码）。
6. 【已核实修正记录】本文档四处数字与调研输入不同，以源码为准：`FCompactStateTreeState` 位标志实为 **18**（输入写 17）；其中无 UPROPERTY 的 tick 位实为 **4**（输入写 6）；UPROPERTY 序列化位实为 **14**（输入写 12）；`EStateTreeDataSourceType` 实为 **None+19 值 = 20 枚举项**（输入写 18 值）。其他文档交叉校验时同步修正。
