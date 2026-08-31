# StateTree 内置节点参考：节点基类契约 · 内置节点逐个 · Blueprint 包装 · FinishTask 范式

> 版本基线：UE 5.8.0 (Release-5.8, CL 55116800) · 版本标记约定：**[UE 5.x+]**=该版本新增，**[仅 <5.x]**=已移除/旧行为，**[5.8 变更]**=本版变更；现行 API 判定标准=声明无 UE_DEPRECATED 标记。

## TL;DR

- 节点体系 = `FStateTreeNodeBase`（实例数据别名 + Link/Compile/描述契约）+ 5 个领域基类：`FStateTreeConditionBase`、`FStateTreeConsiderationBase`（实验特性）、`FStateTreeEvaluatorBase`、`FStateTreeTaskBase`（11 个行为位）、`FStateTreePropertyFunctionBase`；各域另有空壳 `FStateTree*CommonBase`，作为 Schema 可安全批量收录的命名空间。
- 运行时统一节奏：**复制输入绑定 → 调虚函数 → 复制输出绑定**；每帧主循环 TickPrelude → Evaluators/GlobalTasks → Tasks（+StateCompleted）→ TriggerTransitions（≤5 轮 ExitState→EnterState→StateCompleted）→ TickPostlude。
- 遍历方向：`EnterState` 正向（条件先于任务）；`ExitState`/`StateCompleted` 反向（任务先于条件）。
- 内置节点 **39 个类**：14 Condition + 3 Consideration + 3 Task + 19 PropertyFunction。PropertyFunction 头文件全部在 `Private\PropertyFunctions\`，`FStateTreeDelayTask`/`FStateTreeDebugTextTask` 头文件在 `Private\Tasks\`（布局例外）。调研报告 TL;DR 的"26（7 条件 + 13 函数）"口径漏计 4 个 Tag 条件、3 个 Object 条件与 6 个 Int 函数（已对 5.8 源码只读清点修正，见 §1.3）。
- Blueprint 双类机制：`UStateTree*BlueprintBase`（UCLASS，蓝图继承）+ `FStateTreeBlueprint*Wrapper`（运行时 USTRUCT 包装）；任务行为位经 `TaskFlags` 位掩码桥接；蓝图事件检测依赖 AIModule `BlueprintNodeHelpers::HasBlueprintFunction`。
- Blueprint Task 现行范式：**无返回值**事件 `ReceiveLatentEnterState`/`ReceiveLatentTick` + `FinishTask(bool bSucceeded)`；异步完成走 `GetWeakExecutionContext()`；`ExitState` 自动清 Latent Actions 与 Timer。
- **[5.8 变更]**：3 个数值比较条件 `EGenericAICheck` → `UE::StateTree::EComparisonOperator`；Evaluator 调试 `AppendDebugInfoString` → `GetDebugInfo(const FStateTreeReadOnlyExecutionContext&)`；`AITypes.h` include 弃用包裹；POD 实例数据宏换代。
- 自定义节点操作步骤 → `customization-guide.md`（本篇只写契约与行为）；实例数据/评估作用域内存 → `instance-data.md`；绑定机制 → `property-bindings.md`。

## 目录

1. 节点体系总览（类层次 / 源码地图 / 计数口径）
2. `FStateTreeNodeBase` 公共契约
3. 领域基类完整契约（Condition / Consideration / Evaluator / Task 与行为位 / PropertyFunction / 调用时序）
4. 内置节点逐个（14 Conditions / 3 Considerations / 3 Tasks / 19 PropertyFunctions）
5. Blueprint 双类包装机制（公共面 / Wrapper / TaskFlags 桥 / AIModule 依赖）
6. FinishTask 现行范式（同步/异步双路径 / 蓝图任务要点）
7. 弃用 API 单列表
8. 5.6→5.8 签名变迁表（含任务书猜测 API 的实际对应物）
9. 常见坑清单
10. 开放问题

---

## 1. 节点体系总览

证据与路径约定：下文【源码:路径:行号】相对源码根 `E:\UnrealEngine\UE_5.8\Engine\Plugins\Runtime\StateTree\Source\StateTreeModule\`；行为佐证测试位于 `...\Source\StateTreeTestSuite\`（12 号测试报告）。调用点证据集中来自 `Private\StateTreeExecutionContext.cpp`（8374 行）与 `Private\StateTree.cpp`。

### 1.1 类层次

```text
FStateTreeNodeBase (USTRUCT)
├─ FStateTreeConditionBase      → FStateTreeConditionCommonBase      → 内置 7+4+3 条件
├─ FStateTreeConsiderationBase  → FStateTreeConsiderationCommonBase  → 内置 3 consideration（Experimental）
├─ FStateTreeEvaluatorBase      → FStateTreeEvaluatorCommonBase      → 本模块无内置 Evaluator（GameplayStateTree/UAF/Mass 各有）
├─ FStateTreeTaskBase           → FStateTreeTaskCommonBase           → 内置 3 task
└─ FStateTreePropertyFunctionBase → FStateTreePropertyFunctionCommonBase → 内置 19 property function

UStateTreeNodeBlueprintBase (UCLASS, Abstract)
├─ UStateTreeConditionBlueprintBase     ←包装← FStateTreeBlueprintConditionWrapper     : FStateTreeConditionBase
├─ UStateTreeConsiderationBlueprintBase ←包装← FStateTreeBlueprintConsiderationWrapper : FStateTreeConsiderationBase
├─ UStateTreeEvaluatorBlueprintBase     ←包装← FStateTreeBlueprintEvaluatorWrapper     : FStateTreeEvaluatorBase
└─ UStateTreeTaskBlueprintBase          ←包装← FStateTreeBlueprintTaskWrapper          : FStateTreeTaskBase
```

【源码:StateTreeConditionBase.h L21/82；StateTreeTaskBase.h L19/165；StateTreeTaskBlueprintBase.h L21/174】

### 1.2 源码文件地图与 Private 布局例外

| 族 | 头文件（相对源码根） | 实现 | 布局注意 |
|---|---|---|---|
| 基类 | `Public\StateTreeNodeBase.h`、`Public\StateTreeConditionBase.h`、`StateTreeConsiderationBase.h`、`StateTreeEvaluatorBase.h`、`StateTreeTaskBase.h`、`StateTreePropertyFunctionBase.h` | `Private\` 同名 .cpp | Condition 的 cpp 仅 7 行（inline 生成器） |
| Conditions | `Public\Conditions\StateTreeCommonConditions.h`（7 类）、`StateTreeGameplayTagConditions.h`（4 类）、`StateTreeObjectConditions.h`（3 类）、`StateTreeConditionHelpers.h`（`CompareNumbers` 模板 + 弃用转换函数） | `Private\Conditions\` 同名 .cpp | — |
| Considerations | `Public\Considerations\StateTreeCommonConsiderations.h`（3 类 + `FStateTreeConsiderationResponseCurve` + `FStateTreeEnumValueScorePair(s)`） | `Private\Considerations\` 同名 .cpp | — |
| Tasks | `Public\Tasks\StateTreeRunParallelStateTreeTask.h`（Task + `FStateTreeRunParallelStateTreeExecutionExtension`） | `Private\Tasks\` 同名 .cpp | **`Private\Tasks\StateTreeDelayTask.h`、`Private\Tasks\StateTreeDebugTextTask.h`：头文件在 Private 的布局例外** |
| PropertyFunctions | **全部头文件在 Private**：`Private\PropertyFunctions\StateTreeBooleanAlgebraPropertyFunctions.h`、`StateTreeFloatPropertyFunctions.h`、`StateTreeIntPropertyFunctions.h`、`StateTreeIntervalPropertyFunctions.h`、`StateTreeTransformPropertyFunctions.h` | 同目录 .cpp | 查类定义时勿在 Public 下找 |
| Blueprint | `Public\Blueprint\StateTreeNodeBlueprintBase.h` + 各域 `*BlueprintBase.h`（含 Wrapper 类、`FStateTreeDynamicDelegate`、`EStateTreeBlueprintPropertyCategory`、`FStateTreeBlueprintExternalDataHandle`） | `Private\Blueprint\` 五个 .cpp | — |
| 调用时序证据 | — | `Private\StateTreeExecutionContext.cpp`、`Private\StateTree.cpp`（编译期缓存 L928-1004）、`Public\StateTreeExecutionTypes.h` | — |

### 1.3 节点计数口径说明

- **5.8 源码实点（本文口径）：39 类** = 14 Condition（7+4+3）+ 3 Consideration + 3 Task + 19 PropertyFunction（4 Boolean + 6 Float + 6 Int + 1 Interval + 2 Transform）。清点方式：对上述头文件匹配 `struct F\w+ : public FStateTree*CommonBase`（本机只读核实）。
- 调研报告 TL;DR 的"26 个（7 条件 + 13 property function）"与任务书"26/14/3/3/13"均为计数口径偏差："7"只数 `StateTreeCommonConditions.h`、"13"漏数 Int 组 6 类。本文按报告 §3.2/§3.5 逐类枚举表 + 源码清点，以 **39** 为准，逐个覆盖见 §4。

---

## 2. FStateTreeNodeBase 公共契约【源码:StateTreeNodeBase.h】

| 成员 | 签名要点 | 调用时机与语义 | 默认实现 |
|---|---|---|---|
| `FInstanceDataType` | `using FInstanceDataType = FNoInstanceDataType`（L82） | 节点实例数据类型别名，须与 `GetInstanceDataType()` 返回一致；实例数据按节点存于 InstanceData/Temporary/EvaluationScope 三种来源之一（详见 `instance-data.md`） | 无 |
| `FExecutionRuntimeDataType` | 同上（L89） | 执行期运行时数据类型；**在 Context Start~Stop 之间有效**；实例不再活动但 InstanceData 仍活动时数据持久有效；UObject 引用按普通引用被 GC | 无 |
| `FStateTreeNodeBase::GetInstanceDataType()` | `virtual const UStruct* () const`（L94） | 返回实例数据 UStruct；编译器用它建实例布局 | `nullptr` |
| `FStateTreeNodeBase::GetExecutionRuntimeDataType()` | 同上（L105） | 返回执行运行时数据 UStruct | `nullptr` |
| `FStateTreeNodeBase::Link(FStateTreeLinker&)` | `[[nodiscard]] virtual bool`（L116-119） | 资产 Link 阶段解析外部引用（`TStateTreeExternalDataHandle`，经 `Linker.AddExternalData`）；返回 false = link 失败（`[[nodiscard]]` 忘写返回值会编译失败，引擎有意为之） | `return true` |
| `FStateTreeNodeBase::Compile(UE::StateTree::ICompileNodeContext&)`（WITH_EDITOR） | `virtual EDataValidationResult`（L129-132） | 编译期校验/修改节点；传入的节点与实例数据是**编译期复制后用于运行时的那份**（非编辑器数据）；`ICompileNodeContext` 提供 `AddValidationError`/`GetInstanceDataView`/`HasBindingForProperty`（L29-35）；返回 Invalid 使编译失败 | `NotValidated` |
| `FStateTreeNodeBase::GetDescription(const FGuid&, FStateTreeDataView, const IStateTreeBindingLookup&, EStateTreeNodeFormatting)`（WITH_EDITOR） | `virtual FText`（L155-158） | 编辑器节点描述；选择顺序：Name 非空 → Description 非空 → 节点 struct 显示名；RichText 可用 `<b>`/`<s>` 标记 | 空文本 |
| `FStateTreeNodeBase::GetIconName()` | `virtual FName`（L166-169） | 图标，格式 `StyleSetName|StyleName [|SmallStyleName [|StatusOverlayStyleName]]` | `FName()` |
| `FStateTreeNodeBase::GetIconColor()` | `virtual FColor`（L172-175） | 图标颜色 | `UE::StateTree::Colors::DarkGrey` |
| `FStateTreeNodeBase::OnBindingChanged(const FGuid&, FStateTreeDataView, const FPropertyBindingPath& Source, const FPropertyBindingPath& Target, const IStateTreeBindingLookup&)`（WITH_EDITOR） | `virtual void`（L185） | 节点任一属性绑定变化时回调（编辑器），用于同步依赖绑定的成员（如 Enum Compare 的枚举类型） | 空 |
| `FStateTreeNodeBase::PostEditNodeChangeChainProperty(const FPropertyChangedChainEvent&, FStateTreeDataView)` | `virtual void`（L194） | 节点属性被外部修改（PropertyChain 相对节点） | 空 |
| `FStateTreeNodeBase::PostEditInstanceDataChangeChainProperty(const FPropertyChangedChainEvent&, FStateTreeDataView)` | `virtual void`（L201） | 实例数据属性被外部修改（PropertyChain 相对实例数据） | 空 |
| `FStateTreeNodeBase::PostLoad(FStateTreeDataView)` | `virtual void`（L208） | **运行时可用（非 editor-only）**：资产从磁盘加载后调用（Delay/RunParallel 用它同步旧序列化数据，DebugText 用它迁移弃用字段） | 空 |
| 数据成员 | `Name`、`BindingsBatch`、`OutputBindingsBatch`、`InstanceTemplateIndex`、`ExecutionRuntimeTemplateIndex`、`InstanceDataHandle`（L212-232） | 编译产物：输入/输出绑定批句柄、模板实例索引、实例数据句柄 | — |

另有旧签名 `Compile(FStateTreeDataView, TArray<FText>&)` 与 `OnBindingChanged(..., const FStateTreePropertyPath&, ...)` 均 **UE_DEPRECATED(5.6) final**（L141-142/L186-187），不可 override，见 §7。

---

## 3. 领域基类完整契约

### 3.1 FStateTreeConditionBase【源码:StateTreeConditionBase.h】

| 成员 | 签名要点 | 调用时机与语义 | 默认实现 |
|---|---|---|---|
| `FStateTreeConditionBase::TestCondition(FStateTreeExecutionContext&)` | `virtual bool () const`（L26） | 条件求值：EnterConditions/TransitionConditions/效用求值时逐个调用；`bInvert` 与组合逻辑由节点/表达式栈处理（§3.6） | `false` |
| `FStateTreeConditionBase::EnterState(FStateTreeExecutionContext&, const FStateTreeTransitionResult&)` | `virtual void () const`（L36） | 状态进入且条件带状态变更事件时（正向遍历）；**条件实例数据是资产所有使用处共享的，回调内禁止修改实例数据**（L30-31 注释） | 空 |
| `FStateTreeConditionBase::ExitState(同上签名)` | `virtual void () const`（L45） | 状态退出（反向遍历）；同样不得修改共享实例数据 | 空 |
| `FStateTreeConditionBase::StateCompleted(FStateTreeExecutionContext&, const EStateTreeRunStatus, const FStateTreeActiveStates&)` | `virtual void () const`（L56） | 状态完成后、新状态选择前（反向遍历）；条件转换改变状态时不调用；**对条件始终调用**（`bAlwaysCallEnterState`，ExecutionContext.cpp L5216/5220） | 空 |
| `Operand` | `EStateTreeExpressionOperand = And`（L59） | 表达式组合操作数（And/Or/Copy；Multiply 仅 Consideration 支持，条件遇之 checkf） | — |
| `DeltaIndent` | `int8 = 0`（L62） | 表达式括号缩进增量（正=开括号，负=闭括号） | — |
| `EvaluationMode` | `EStateTreeConditionEvaluationMode = Evaluated`（L65） | ForcedTrue/ForcedFalse 不调 `TestCondition` 直接给结果（ExecutionContext.cpp L5099/L5132） | `Evaluated` |
| `bHasShouldCallStateChangeEvents` | `uint8 : 1 = false`（L68） | **非 UPROPERTY 的编译期缓存位**：override 了三个事件回调才由编译器置 true，为 true 时事件才会被调用 | — |
| `bShouldStateChangeOnReselect` | `uint8 : 1 = true`（L74） | 状态被重选（Sustained）时是否仍收 EnterState/ExitState | — |

**条件表达式求值**（`TestCondition` 之外的一半逻辑）【源码:StateTreeExecutionContext.cpp L5056-5181】：
1. `EvaluationMode != Evaluated` → 直接取 ForcedTrue/ForcedFalse，不调 `TestCondition`；
2. Evaluated：复制输入绑定；**复制失败 → 整个表达式强制 false 并告警**（"enter conditions trying to access inactive parent state"，排查转换不发生先看此告警）；
3. `Cond.TestCondition(*this)`（L5121）→ 4. 复制的对象引用 `ResetObjects` 清除 → 5. 结果按 `DeltaIndent`（括号）与 `Operand`（Copy/And/Or）合并进操作数栈，返回 `Values[0]`。
条件实例数据来源含 EvaluationScope（`FEvaluationScopeInstanceContainer` 共享内存布局，内存归属详见 `instance-data.md`）。

### 3.2 FStateTreeConsiderationBase（实验特性）【源码:StateTreeConsiderationBase.h/.cpp】

头文件类注释（L14）："This feature is experimental and the API is expected to change."——效用考虑度整体为实验特性，跨版本 API 风险自担。

| 成员 | 签名要点 | 调用时机与语义 | 默认实现 |
|---|---|---|---|
| `FStateTreeConsiderationBase::GetScore(FStateTreeExecutionContext&)` | `protected virtual float () const`（L28） | 子类实现**原始评分** | `0.f` |
| `FStateTreeConsiderationBase::GetNormalizedScore(FStateTreeExecutionContext&)` | `public UE_API float () const`（L25；cpp L14-17） | 状态选择效用计算（`EvaluateUtilityWithValidation`，ExecutionContext.cpp L5333）调用；实现为 `FMath::Clamp(GetScore(Context), 0.f, 1.f)`——**原始分数强制钳制 [0,1]** | — |
| `Operand` / `DeltaIndent` | `EStateTreeExpressionOperand` / `int8`（L32/35，默认 And/0） | 组合多个 consideration：And→Min(a,b)、Or→Max(a,b)、Multiply→a*b（StateTreeTypes.h L142-149 注释；求值代码在状态选择路径，报告未逐行核实） | — |

### 3.3 FStateTreeEvaluatorBase【源码:StateTreeEvaluatorBase.h/.cpp】

| 成员 | 签名要点 | 调用时机与语义 | 默认实现 |
|---|---|---|---|
| `FStateTreeEvaluatorBase::TreeStart(FStateTreeExecutionContext&)` | `virtual void () const`（L26） | `FStateTreeExecutionContext::Start` 期间对全局评估器逐个调用（先复制输入绑定，调用后复制输出绑定；ExecutionContext.cpp L4402-4435） | 空 |
| `FStateTreeEvaluatorBase::TreeStop(FStateTreeExecutionContext&)` | `virtual void () const`（L32） | Stop / 终态转换时调用（先调 TreeStop 再复制输出绑定；L4697-4707） | 空 |
| `FStateTreeEvaluatorBase::Tick(FStateTreeExecutionContext&, const float DeltaTime)` | `virtual void () const`（L39） | 每帧全局评估器更新（复制输入绑定 → Tick → 复制输出绑定；L4187-4218）；DeltaTime = 距上次 StateTree tick 时长，**预选（preselection）期间为 0**（L37 注释） | 空 |
| `FStateTreeEvaluatorBase::GetDebugInfo(const FStateTreeReadOnlyExecutionContext&)` | `UE_API virtual FString`（WITH_GAMEPLAY_DEBUGGER，L42；cpp L8-16） | Gameplay Debugger 输出 | `[Name]\n` |
| `FStateTreeEvaluatorBase::AppendDebugInfoString(FString&, const FStateTreeExecutionContext&)` | **UE_DEPRECATED(5.8) final**（L44-47） | **[5.8 变更]** 旧调试接口，final 空实现，不可用 | （弃用） |

### 3.4 FStateTreeTaskBase 与行为位【源码:StateTreeTaskBase.h；调用点 StateTreeExecutionContext.cpp】

| 虚函数 | 签名 | 调用时机与返回值语义 | 默认 |
|---|---|---|---|
| `FStateTreeTaskBase::EnterState` | `(FStateTreeExecutionContext&, const FStateTreeTransitionResult&)` → `virtual EStateTreeRunStatus () const`（L46-49） | 状态进入、任务在活动状态中：**条件事件之后、正向遍历**（L3852；全局任务在 Start 时 L4495）；返回 Succeed/Failed 立即结束状态并触发选择新状态；失败中断后续任务 EnterState（L3873-3879）；Sustained 状态仅当 `bShouldStateChangeOnReselect` 才调用（L3839-3841） | `Running` |
| `FStateTreeTaskBase::ExitState` | 同上参数 → `virtual void () const`（L56-58） | 状态退出：**反向遍历**（L4038）；之后复制输出绑定（L4041-4044） | 空 |
| `FStateTreeTaskBase::StateCompleted` | `(FStateTreeExecutionContext&, EStateTreeRunStatus CompletionStatus, const FStateTreeActiveStates&)` → `virtual void () const`（L67-69） | 状态完成后、新状态选择前：**反向遍历**（L4126-4146），仅对已收到 EnterState 的任务（`TaskIndex <= ActiveNodeIndex`）；反向调用以便向更早执行的任务传播状态；条件转换（conditional transition）改变状态时不调用 | 空 |
| `FStateTreeTaskBase::Tick` | `(FStateTreeExecutionContext&, const float DeltaTime)` → `virtual EStateTreeRunStatus () const`（L78-81） | 每帧 tick 活动状态任务：仅当 `bShouldCallTick` 或（队列有事件且 `bShouldCallTickOnlyOnEvents`）且任务仍 Running（L4963-4965）；调用前按 `bShouldCopyBoundPropertiesOnTick` 复制输入绑定；返回值经 `SetTaskStatusWithPriority` 写入；非 Failed 且有输出绑定时复制输出绑定；状态实际变化且有完成委托分发器时广播；**某任务 Failed 且参与完成判定 → 停止后续任务 tick**（L5026-5033） | `Running` |
| `FStateTreeTaskBase::TriggerTransitions` | `(FStateTreeExecutionContext&)` → `virtual void () const`（L88-90） | 转换处理阶段：先于状态自身转换与事件转换（L84 注释）；**仅 `bShouldAffectTransitions && bTaskEnabled` 参与**：收集成 TransitionHandlers 按 `TransitionHandlingPriority` + 加入顺序 StableSort（L5888-5895/5934-5935）再依次调用（L5977）；调用前复制输入绑定（L5968-5971） | 空 |
| `FStateTreeTaskBase::GetDebugInfo` | `(const FStateTreeReadOnlyExecutionContext&)` → `FString`（WITH_GAMEPLAY_DEBUGGER，L104） | 同 Evaluator（5.8 直接是新接口，无弃用旧版） | 实现 |

**行为位汇总**（构造默认值见 StateTreeTaskBase.h L23-38）：

| 位 | 默认 | 语义 | 编译期效果 |
|---|---|---|---|
| `bShouldStateChangeOnReselect` | true | Sustained 时是否仍调 EnterState/ExitState（动作类 true；资源占用类 false） | 无（运行时判断） |
| `bShouldCallTick` | true | Tick 是否被调；**false 同时意味着不复制属性**（L115） | `State.bHasTickTasks`、`bCachedRequestTick`（StateTree.cpp L937/942） |
| `bShouldCallTickOnlyOnEvents` | false | 仅事件队列有事件时 Tick | `bHasTickTasksOnlyOnEvents` 等 |
| `bShouldCopyBoundPropertiesOnTick` | true | Tick 前复制输入绑定 | 无 |
| `bShouldCopyBoundPropertiesOnExitState` | true | ExitState 前复制输入绑定 | 无 |
| `bShouldAffectTransitions` | false | TriggerTransitions 是否参与转换处理 | `State.bHasTransitionTasks`、`bCachedRequestTick` |
| `bConsideredForScheduling` | true | 参与 ScheduledTick 调度统计；**不影响任务自身是否 tick**（L128-133 注释）；仅此位为 true 时才把 tick/transition 位计入 `bCachedRequestTick*`（StateTree.cpp L940-944/997-1001） | 见左 |
| `bTaskEnabled` | true（UPROPERTY） | false 时 EnterState/Tick/ExitState/StateCompleted/TriggerTransitions 全部跳过（L4945-4949、L3823-3827 等） | 各 `bHas*` 缓存按 enabled 任务统计 |
| `bHasTaskCompletionDelegateDispatcher` | false（UPROPERTY） | 是否绑定任务完成委托分发器；状态变化时广播 | — |
| `TransitionHandlingPriority` | Normal（UPROPERTY） | TriggerTransitions 处理优先级（High 先处理） | StableSort 依据 |
| `bConsideredForCompletion`（WITH_EDITORONLY_DATA） | true | false = 后台运行不影响状态完成（如 DebugText） | `IsConsideredForCompletion` 判定 |

任务书名称核对：任务书猜测的 `TickDelta`、`RequiresTick`、`TransitionOnCompleted` 在 5.8 源码中**不存在**，实际对应物见 §8 末表。

### 3.5 FStateTreePropertyFunctionBase【源码:StateTreePropertyFunctionBase.h/.cpp】

| 成员 | 签名要点 | 调用时机与语义 | 默认实现 |
|---|---|---|---|
| `FStateTreePropertyFunctionBase::Execute(FStateTreeExecutionContext&)` | `virtual void () const`（L48） | **在求值宿主节点的属性绑定之前执行**（头注释 L13-14）；挂接点：绑定复制批（`CopyBatchInternal`）内先评估该批次的 PropertyFunctions 再做绑定复制（ExecutionContext.cpp L3357-3378；`Func.Execute` 在 L5429，前有输入绑定复制 L5417-5427）；同批多个函数按 `PropertyFunctionsBegin..End` 顺序执行；没有输出绑定回调 | 空 |
| 输出属性约定 | 头注释 L16-37 | 实例数据应**恰好一个**输出属性（Category=Output）：编辑器以它确定函数适用于哪些属性并在 UI 中隐藏该属性；`FStateTreeBreakTransformPropertyFunction` 的双输出是引擎内部例外（§4.4），自定义请保持单输出 | — |
| `GetIconName()` / `GetIconColor()`（WITH_EDITOR） | L51-56；cpp L13-28 | 图标 `StateTreeEditorStyle|Node.Function`；颜色取输出属性对应的 K2 Pin 颜色，无输出属性回退灰色 | 实现 |

### 3.6 统一调用节奏与每帧时序

统一节奏（所有节点虚函数一致）：**复制输入绑定 → 调虚函数 → 复制输出绑定**。Tick 前按 `bShouldCopyBoundPropertiesOnTick`、ExitState 前按 `bShouldCopyBoundPropertiesOnExitState`、TriggerTransitions 前固定复制。

每帧骨架 `FStateTreeExecutionContext::Tick(DeltaTime)`【源码:StateTreeExecutionContext.cpp L1812-1831】：

```text
TickPrelude（L1754-1788：有效性检查 → CollectActiveExternalData → 非 Running 直接返回 → Phase=TickStateTree）
TickUpdateTasksInternal（L1873-1950）
  ├─ DelayedTransitions 倒计时（L1887-1890）
  ├─ TickEvaluatorsAndGlobalTasks（L1922；CVar bTickGlobalNodesFollowingTreeHierarchy 控制与任务合并）
  │    ├─ 全局 Evaluator：输入绑定 → TreeStart/Tick/TreeStop 相应阶段 → 输出绑定
  │    └─ 全局 Task：输入绑定 → EnterState → 输出绑定（Start 时）；Tick 同任务
  ├─ Exec.LastTickStatus = TickTasks(DeltaTime)（L1904；逐任务见 §3.4 Tick 行）
  └─ 状态完成 → StateCompleted()（L1906-1909）
TickTriggerTransitionsInternal（L1965-2033；最多 5 轮 MaxIterations L1979）
  ├─ TriggerTransitions()：收集处理器（bShouldAffectTransitions 任务 + 状态转换）→ 排序 → 执行
  │    ├─ 有转换：ExitState（任务反向 → 条件反向）→ 终态则停树（L1995-2010）
  │    ├─ EnterState（条件正向 → 任务正向）→ LastTickStatus 非 Running → StateCompleted()（L2014-2024）
  │    └─ ResetTemporaryInstances 每轮清理（L1982）
  └─ Running 且无待广播委托 → break（L2028）
TickPostlude（L1791-1810：Phase=Unset → 处理 Deferred Stop → Stop()）
```

遍历方向汇总【L3798-3884 / L4012-4059 / L4091-4154】：`EnterState` 内条件正向（L3812）→ 任务正向（L3852）；`ExitState` 内任务反向（L4038）→ 条件反向（L4059）；`StateCompleted` 内任务反向（仅已 EnterState 的任务）→ 条件反向。条件三事件统一门槛在 `RunAllConditionsInternal`【L5183-5269】：`bHasShouldCallStateChangeEvents` +（Changed 或 Sustained 且 `bShouldStateChangeOnReselect`）。

---

## 4. 内置节点逐个

### 4.1 Conditions（14 个，全部继承 `FStateTreeConditionCommonBase`）

| 类（DisplayName） | 实例数据 | TestCondition 行为 | 来源 |
|---|---|---|---|
| `FStateTreeCompareIntCondition`（Integer Compare） | `{Left, Right int32}` | `CompareNumbers<int32>`（Equal/NotEqual/Less/LessOrEqual/Greater/GreaterOrEqual）后 `^ bInvert`；发 Trace 文本 | 【StateTreeCommonConditions.h L35；.cpp L52-65】 |
| `FStateTreeCompareFloatCondition`（Float Compare）**[5.8 变更]** | `{Left, Right double}` | `CompareNumbers<double>`；Operator 类型已换 `EComparisonOperator`（§7/§8） | 【.h L82；.cpp L108-121】 |
| `FStateTreeCompareBoolCondition`（Bool Compare） | `{bLeft, bRight bool}` | `bLeft == bRight ^ bInvert` | 【.h L129；.cpp L160-170】 |
| `FStateTreeCompareEnumCondition`（Enum Compare） | `{Left, Right FStateTreeAnyEnum}` | `Left == Right ^ bInvert`；编辑器 `OnBindingChanged` 同步 Left 的枚举类型到 Right（.cpp L263-304） | 【.h L172；.cpp L207-217】 |
| `FStateTreeCompareDistanceCondition`（Distance Compare）**[5.8 变更]** | `{Source, Target FVector, Distance double}` | `FVector::DistSquared(Source,Target)` 与 `Distance²` 比较（避免开方） | 【.h L219；.cpp L321-338】 |
| `FStateTreeCompareNameCondition`（Name Compare） | `{Left, Right FName}` | `Left.IsEqual(Right)`（大小写敏感默认） | 【.h L265；.cpp L388-398】 |
| `FStateTreeRandomCondition`（Random） | `{Threshold float 0..1}` | `FMath::FRandRange(0,1) < Threshold`——**每次求值重掷随机数**，非缓存 | 【.h L304；.cpp L435-445】 |
| `FGameplayTagSingleMatchCondition`（Matches Tag） | `{Left, Right FGameplayTag}` | `Left.MatchesTagExact/MatchesTag(Right) ^ bInvert`；"A.1 match A" 精确=false 时成功、"A match A.1" 恒 false（头注释 L28-33） | 【StateTreeGameplayTagConditions.h L36；.cpp L24-35】 |
| `FGameplayTagMatchCondition`（Has Tag） | `{TagContainer, Tag}` | `HasTagExact/HasTag ^ bInvert` | 【.h L90；.cpp L75-86】 |
| `FGameplayTagContainerMatchCondition`（Has Tags） | `{TagContainer, OtherContainer}` | `MatchType`（Any→HasAny/HasAnyExact，All→HasAll/HasAllExact）`^ bInvert`；Any 且容器空恒 false，All 且容器空恒 true（头注释 L140-158） | 【.h L161；.cpp L125-150】 |
| `FGameplayTagQueryCondition`（Does Container Match Tag Query） | `{TagContainer}` | `TagQuery.Matches(TagContainer) ^ bInvert` | 【.h L209；.cpp L191-201】 |
| `FStateTreeObjectIsValidCondition`（Object Is Valid） | `{Object TObjectPtr<UObject>}` | `IsValid(Object) ^ bInvert` | 【StateTreeObjectConditions.h L23；.cpp L16-21】 |
| `FStateTreeObjectEqualsCondition`（Object Equals） | `{Left, Right}` | `Left == Right ^ bInvert` | 【.h L65；.cpp L39-44】 |
| `FStateTreeObjectIsChildOfClassCondition`（Object Class Is） | `{Object, Class TObjectPtr<UClass>}` | `Object && Class && Object->GetClass()->IsChildOf(Class)` | 【.h L107；.cpp L62-75】 |

注：比较条件实例数据均以 **[5.8 变更]** 新宏 `UE_STATETREE_ZEROED_TRIVIALLY_COPIED_NO_DESTRUCTOR_INSTANCEDATA` / `UE_STATETREE_CONSTRUCTED_TRIVIALLY_COPIED_NO_DESTRUCTOR_INSTANCEDATA` 注册 POD 优化布局（替代已弃用 `STATETREE_POD_INSTANCEDATA`）。仅 3 个数值比较条件（Int/Float/Distance）经历过 `EGenericAICheck`；Bool/Enum/Name/Object/Tag 条件从未有过该字段（5.8 无弃用标记）。

### 4.2 Considerations（3 个，全部继承 `FStateTreeConsiderationCommonBase`，实验特性）【源码:StateTreeCommonConsiderations.h/.cpp】

| 类 | 实例数据 | GetScore 行为 |
|---|---|---|
| `FStateTreeConstantConsideration`（Constant） | `{Constant float, clamp 0..1}` | 直接返回 `Constant`（cpp L83-88） |
| `FStateTreeFloatInputConsideration`（Float Input） | `{Input float, Interval FFloatInterval(0,1)}` | 归一化 `Clamp(Interval.GetRangePct(Input),0,1)` → 过 `FStateTreeConsiderationResponseCurve.Evaluate`（FRuntimeFloatCurve；曲线空则原样返回输入，.h L54-65；cpp L52-60） |
| `FStateTreeEnumInputConsideration`（Enum Input） | `{Input FStateTreeAnyEnum}` | 查 `EnumValueScorePairs.Data` 中匹配 `Input.Value` 的 `FStateTreeEnumValueScorePair.Score`，无匹配返回 0（cpp L90-106）；编辑器 Compile 校验枚举值重复（Invalid，cpp L109-132）；`OnBindingChanged` 同步枚举（cpp L134-175） |

测试盲区提示：Consideration 效用求值本体无自动化测试（唯一触达点是 `FStateTreeTest_OverrideStartState` 证明 Start 覆盖优先于 Utility 选择，StateTreeTest.cpp L2267-2276）。

### 4.3 Tasks（3 个）

**`FStateTreeDelayTask`（Delay Task）**【源码:Private\Tasks\StateTreeDelayTask.h/.cpp，头文件在 Private】
- 实例数据 `{Duration=1, RandomDeviation=0, bRunForever=false, RemainingTime, ScheduledTickHandle}`。
- 构造：`bConsideredForScheduling=false`、`bShouldCopyBoundPropertiesOnTick/OnExitState=false`（cpp L10-15）——用自己的 ScheduledTick 调度且无绑定复制。
- `EnterState`：非 RunForever 时 `RemainingTime = FRandRange(max(0,Duration-RandomDeviation), Duration+RandomDeviation)`，`Context.AddScheduledTickRequest(FStateTreeScheduledTick::MakeCustomTickRate(RemainingTime))`，返回 Running（cpp L17-30）。
- `Tick`：`RemainingTime -= DeltaTime`，≤0 时 `RemoveScheduledTickRequest` 并返回 Succeeded；否则 `UpdateScheduledTickRequest` 返回 Running（cpp L32-49）。`ExitState`：移除调度句柄（cpp L51-55）。

**`FStateTreeDebugTextTask`（Debug Text Task）**【源码:Private\Tasks\StateTreeDebugTextTask.h/.cpp，头文件在 Private】
- 实例数据 `{bEnabled=true, ReferenceActor(optional), BindableText}`；节点另有 `Text/TextColor/FontScale/Offset` 与 WITH_EDITORONLY_DATA 迁移字段 `bEnabled_DEPRECATED/DeprecatedVersion`。
- 构造：`bShouldCallTick=false`（不 tick）、不复制绑定、`bConsideredForCompletion=false` 且不可编辑（cpp L12-23）——纯显示不影响状态完成。
- `EnterState`：取 World（Context 优先，退回 ReferenceActor），无效则 Failed；`DrawDebugString(Duration=-1)` 画 Text 与 BindableText 两串；返回 Running（cpp L25-58）。`ExitState`：画空字符串清除该 Actor 的 HUD DebugText 条目（cpp L60-84）。
- `PostLoad`（editor）：把旧节点级 `bEnabled_DEPRECATED` 迁移到实例数据（版本锚 1，cpp L87-104）——自定义节点 PostLoad 数据迁移的官方示例。

**`FStateTreeRunParallelStateTreeTask`（Run Parallel Tree）**【源码:Public\Tasks\StateTreeRunParallelStateTreeTask.h/.cpp】
- 实例数据 `{StateTree FStateTreeReference(SchemaCanBeOverriden), TreeInstanceData(Transient), RunningStateTree(Transient), ScheduledTickHandle}`；配套 `FStateTreeRunParallelStateTreeExecutionExtension`（`ScheduleNextTick` 用 MinimalExecutionContext 读并行树 NextScheduledTick 回写父树句柄）。
- 构造：`bShouldCopyBoundPropertiesOnTick/OnExitState=false`、`bShouldAffectTransitions=true`、`bConsideredForScheduling=false`（cpp L38-45）。
- `EnterState`：解析树（`StateTreeOverrideTag` 有值时优先 `Context.GetLinkedStateTreeOverrideForTag`，cpp L194-205）；无效上下文/引用/递归检测命中 → Failed（递归检测不完美：A↔B 互链检不出，注释 L64）；否则构造子 `FStateTreeExecutionContext` 并 `Start(FStartParameters{InitialGlobalParameters, ExecutionExtension=并行扩展, SharedEventQueue=父实例事件队列})`（**共享事件队列**=并行树收父树事件的关键，cpp L92）。
- `Tick`：可选复制全局参数（`bShouldCopyParametersOnTick` → `UpdateGlobalParameters()`，struct 匹配才复制）；`ParallelTreeContext.TickUpdateTasks(DeltaTime)`（**只 Tick 任务**）。
- `TriggerTransitions`：`FEventsPendingForNextTransitionProcessingScope` 保事件存活跨越父树转换阶段；子树 RunStatus 非 Running → `Context.FinishTask(*this, Succeeded/Failed)`（cpp L129-161）。`ExitState`：移除句柄、可选复制参数、`ParallelTreeContext.Stop()`（cpp L163-192）。`PostLoad`/`Compile` 同步行为位与 `TransitionHandlingPriority`（cpp L207-226）。

### 4.4 PropertyFunctions（19 个，全部继承 `FStateTreePropertyFunctionCommonBase`，全部 Private）

| 组 | 类 | Execute 行为 | 来源 |
|---|---|---|---|
| Boolean | `FStateTreeBooleanAndPropertyFunction` / `FStateTreeBooleanOrPropertyFunction` / `FStateTreeBooleanXOrPropertyFunction` | `bResult = bLeft && / \|\| / ^ bRight` | 【StateTreeBooleanAlgebraPropertyFunctions.h L31/50/69；.cpp L35-65】 |
| Boolean | `FStateTreeBooleanNotPropertyFunction` | `bResult = !bInput` | 【同文件 L100；.cpp L74-78】 |
| Float | `FStateTreeAddFloatPropertyFunction` / `FStateTreeSubtractFloatPropertyFunction` / `FStateTreeMultiplyFloatPropertyFunction` | `Result = Left ±/* Right` | 【StateTreeFloatPropertyFunctions.h L31-88；.cpp L12-28】 |
| Float | `FStateTreeDivideFloatPropertyFunction` | **除 0 保护：Right==0 时 Result=0** | 【.cpp L30-41】 |
| Float | `FStateTreeInvertFloatPropertyFunction` / `FStateTreeAbsoluteFloatPropertyFunction` | `Result = -Input` / `FMath::Abs(Input)` | 【.cpp L43-53】 |
| Int | `FStateTreeAddIntPropertyFunction` / `FStateTreeSubtractIntPropertyFunction` / `FStateTreeMultiplyIntPropertyFunction` / `FStateTreeDivideIntPropertyFunction` / `FStateTreeInvertIntPropertyFunction` / `FStateTreeAbsoluteIntPropertyFunction` | 与 Float 一一对应；Divide 同样除 0 保护（注意整数除法截断） | 【StateTreeIntPropertyFunctions.h L31-138；.cpp L12-53】 |
| Interval | `FStateTreeMakeIntervalPropertyFunction` | `Result = FFloatInterval(Min, Max)` | 【StateTreeIntervalPropertyFunctions.h L31；.cpp L12-16】 |
| Transform | `FStateTreeMakeTransformPropertyFunction` | `OutTransform = FTransform(InRotation, InTranslation)` | 【StateTreeTransformPropertyFunctions.h L31；.cpp L8-12】 |
| Transform | `FStateTreeBreakTransformPropertyFunction` | `OutTranslation = InTransform.GetTranslation(); OutRotation = InTransform.GetRotation()`（**双输出属性=单输出约定的唯一内置例外**） | 【.h L71；.cpp L14-19】 |

测试盲区提示：内置 PropertyFunction 库零自动化测试（StateTreeTestSuite 只用自造 `FTestPropertyFunction`）；PropertyFunction 求值时机佐证：`FStateTreeTest_PropertyFunctions` 证明其在 EnterState/Tick/ExitState 每阶段先于绑定拷贝求值（StateTreeBindingTest.cpp L578-583）；异步 `CopyInputBindings` 遇属性函数会跳过求值并返回 false（StateTreeTestAsyncExecution.cpp L1289-1295）。

---

## 5. Blueprint 双类包装机制

机制总述：蓝图侧每域两个类——`UStateTree*BlueprintBase`（UCLASS，Abstract，用户蓝图继承它）+ `FStateTreeBlueprint*Wrapper`（USTRUCT，继承对应 C++ 基类，运行时真正进树）。Wrapper 持有蓝图类实例（**蓝图类本身即实例数据类型**：`GetInstanceDataType()` 返回 TaskClass，StateTreeTaskBlueprintBase.h L178-181；EditAnywhere 蓝图变量自动成为实例数据成员）。Wrapper 调用链统一模式：**缓存 WeakContext → 调 Receive* 事件 → 清缓存**；编译期用 `bHas*` 位检测蓝图是否实现事件，未实现则跳过调用（不白白进蓝图 VM）。

### 5.1 UStateTreeNodeBlueprintBase 公共面【源码:StateTreeNodeBlueprintBase.h/.cpp】

- BlueprintCallable：`SendEvent(const FStateTreeEvent&)`（走 `WeakExecutionContext.SendEvent`，失败 VLog Error "instance probably stopped"）；`RequestTransition(const FStateTreeStateLink&, EStateTreeTransitionPriority = Normal)`；`GetPropertyReference(const FStateTreeBlueprintPropertyRef&)`（CustomThunk，`execGetPropertyReference` 直接把引用属性地址交给蓝图 VM——PropertyRef 的 5.8 现行消费方式）；`IsPropertyRefValid(...)`。
- `GetPropertyDescriptionByPropertyName(FName)`（BlueprintInternalUseOnly）：编辑器取绑定显示名或属性值文本。
- protected：`ReceiveGetDescription(EStateTreeFormatting)`（BlueprintImplementableEvent）；`GetWorld()` override（非 CDO 时从 WeakExecutionContext Owner 或 Outer 取）；`SetCachedInstanceDataFromContext`/`ClearCachedInstanceData`（本质是 `WeakExecutionContext = Context.MakeWeakExecutionContext()` / 清空）；`GetWeakExecutionContext()`。
- 编辑器 `GetDescription` 顺序：Description 属性 → `ReceiveGetDescription` → 类显示名；期间静态缓存 `CachedNodeID/CachedBindingLookup`（WITH_EDITOR，非线程安全）。
- 弃用成员：`WeakInstanceStorage`/`CachedFrameStateTree`/`CachedFrameRootState`（均 5.6 → `WeakExecutionContext`）。

### 5.2 各域 Blueprint 基类与 Wrapper

| 蓝图基类 | Wrapper | 蓝图事件（BlueprintImplementableEvent） | 事件检测位 |
|---|---|---|---|
| `UStateTreeConditionBlueprintBase` | `FStateTreeBlueprintConditionWrapper : FStateTreeConditionBase` | `ReceiveTestCondition()`（未实现→false，每帧/每次求值都调，注意蓝图开销） | `bHasTestCondition` |
| `UStateTreeConsiderationBlueprintBase` | `FStateTreeBlueprintConsiderationWrapper : FStateTreeConsiderationBase` | `ReceiveGetScore()`（未实现→0，自动 Clamp [0,1]） | — |
| `UStateTreeEvaluatorBlueprintBase` | `FStateTreeBlueprintEvaluatorWrapper : FStateTreeEvaluatorBase` | `ReceiveTreeStart()` / `ReceiveTreeStop()` / `ReceiveTick(float)` | — |
| `UStateTreeTaskBlueprintBase` | `FStateTreeBlueprintTaskWrapper : FStateTreeTaskBase` | **现行（均无返回值）**：`ReceiveLatentEnterState(const FStateTreeTransitionResult&)`、`ReceiveExitState(...)`、`ReceiveStateCompleted(EStateTreeRunStatus, FStateTreeActiveStates)`、`ReceiveLatentTick(float)`（.h L37-68） | `bHasLatentEnterState` / `bHasLatentTick` |

`UStateTreeTaskBlueprintBase` 蓝图可调用：`FinishTask(bool bSucceeded = true)`（§6）；`BroadcastDelegate(FStateTreeDelegateDispatcher)`、`BindDelegate(FStateTreeDelegateListener, FStateTreeDynamicDelegate)`、`UnbindDelegate(...)`（全部走 WeakExecutionContext，失败 VLog Error）。

### 5.3 TaskFlags 位掩码桥与隐性开关

- `FStateTreeTaskBase` 行为位**不是 UPROPERTY**；Wrapper 用 `TaskFlags` 位掩码在 Compile 时打包、Link 时解包（StateTreeTaskBlueprintBase.cpp L146-155/L202-206）——**直接在 Wrapper 子类改位不生效，必须经蓝图实例设置**。
- `bShouldCallTick` 在蓝图基类故意非 UPROPERTY（仅 C++ 派生可设，L125-127 注释）：编译期 `bShouldCallTick = bShouldCallTick || bHasLatentTick`（cpp L193）——**实现 ReceiveLatentTick 才会 Tick**；只想要"事件时 Tick"应显式勾 `bShouldCallTickOnlyOnEvents`。
- 可编辑位（UPROPERTY）：`bShouldStateChangeOnReselect`、`bShouldCallTickOnlyOnEvents`、`bShouldCopyBoundPropertiesOnTick`、`bShouldCopyBoundPropertiesOnExitState`、`bConsideredForCompletion`、`bCanEditConsideredForCompletion`（L120-153）。

### 5.4 AIModule 依赖

- 蓝图事件检测用 `BlueprintNodeHelpers::HasBlueprintFunction`（`E:\UnrealEngine\UE_5.8\Engine\Source\Runtime\AIModule\Public\BlueprintNodeHelpers.h` L35-40）——这是 StateTreeModule.Build.cs 公开依赖 AIModule 的直接原因之一（Build.cs @TODO：AITypes.h 弃用后移为 Private）。
- **[5.8 变更]** `StateTreeCommonConditions.h`/`StateTreeConditionHelpers.h` 对 `AITypes.h` 的 include 用 `#if UE_ENABLE_INCLUDE_ORDER_DEPRECATED_IN_5_8` 包裹——5.8 起这些头不再隐式给出 `EGenericAICheck`。

---

## 6. FinishTask 现行范式

### 6.1 同步与异步双路径【源码:StateTreeExecutionContext.cpp L2246-2306 + StateTreeTaskBlueprintBase.cpp L107-115】

- **同步路径**（C++ 任务，或蓝图在 EnterState/Tick 处理中）：`FStateTreeExecutionContext::FinishTask(const FStateTreeTaskBase&, EStateTreeFinishTaskType)` → `ensure(CurrentNode == &Task)`（只接受当前正在处理的任务，L2257-2261）→ 写 `FTasksCompletionStatus` 并标记 `bHasPendingCompletedState`；状态实际变化时广播任务完成委托（L2286-2289）。
- **异步路径**（蓝图任务在回调中调 FinishTask，不在 EnterState/Tick 处理期间）：`GetWeakExecutionContext().FinishTask(EStateTreeFinishTaskType)`（StateTreeTaskBlueprintBase.cpp L110-114）→ `TStateTreeStrongExecutionContext<true>::FinishTask`【源码:StateTreeAsyncExecutionContext.h L138，弱上下文先 `MakeStrongExecutionContext()`】→ 最终落 `FStateTreeExecutionContext::FinishTask`。
- `EStateTreeFinishTaskType` 只有 `Failed`/`Succeeded` 两值【源码:StateTreeExecutionTypes.h L73-81】。
- 优先级：Tick 返回值与 FinishTask 经 `SetTaskStatusWithPriority` 写入——**Succeeded/Failed 覆盖 Running，不反向**（ExecutionContext.cpp L5005-5008）。
- 测试佐证：Tick 内 FinishTask 当帧收尾重选、Tick 内第二次调用为 no-op（StateTreeTest.cpp `FStateTreeTest_FinishTasks`）；Tick 外 `WeakContext.FinishTask` 缓冲至下一 Tick 生效（StateTreeTestAsyncExecution.cpp `FinishTaskViaWeakContext`/`FinishTaskFailed`）；状态任务 FinishTask 只完成该状态且当帧 Tick 返回值仍为 Running（StateTreeWeakContextTest.cpp `WeakContext_FinishTask`）。

### 6.2 Blueprint 任务要点（现行范式）

1. 继承 `UStateTreeTaskBlueprintBase` 建蓝图；EditAnywhere 变量即实例数据成员。
2. 实现 **EnterState**（`ReceiveLatentEnterState`）：启动动作（Latent 节点如 Delay/Timeline，或 GameplayTask）；**不依赖返回值**（事件无返回值，"Latent"即允许启动 Latent actions 之意）。
3. 完成/失败调 **Finish Task**（bSucceeded=true/false）：在 EnterState/Tick 事件内调用 → 本次执行返回时生效；在异步回调（Delay 完成、GameplayTask 回调）中调用 → 立即经 WeakExecutionContext 完成。
4. 需要 Tick：实现 **Tick**（`ReceiveLatentTick`）——`bShouldCallTick` 编译期自动开启（§5.3）；仅事件驱动 Tick 勾 `bShouldCallTickOnlyOnEvents`。
5. 可选实现 ExitState/StateCompleted；**ExitState 里无需手工清理 Latent/Delay**：基类自动 `GetLatentActionManager().RemoveActionsForObject(this)` + `GetTimerManager().ClearAllTimersForObject(this)`（cpp L70-74）；但生命周期绑本任务的 GameplayTask 需手动 Cancel（头注释 L32-33）。
6. `WeakExecutionContext` 在 EnterState 缓存、ExitState 清除——状态退出后异步回调即失效（失败仅 VLog Error，不崩溃）。
7. 从零自定义 Condition/Task/Evaluator/Consideration/PropertyFunction 的完整操作步骤（建模块、实例数据 struct、POD 宏、Link 外部数据、异步回调模板等）→ `customization-guide.md`。

---

## 7. 弃用 API 单列表

| API | 弃用版本 | 替代品 |
|---|---|---|
| `FStateTreeNodeBase::Compile(FStateTreeDataView, TArray<FText>&)`（final） | 5.6 | `FStateTreeNodeBase::Compile(UE::StateTree::ICompileNodeContext&)` |
| `FStateTreeNodeBase::OnBindingChanged(..., const FStateTreePropertyPath&, ...)`（final） | 5.6 | `FPropertyBindingPath` 参数版本 |
| `UStateTreeNodeBlueprintBase::WeakInstanceStorage` | 5.6 | `WeakExecutionContext` |
| `UStateTreeNodeBlueprintBase::CachedFrameStateTree` / `CachedFrameRootState` | 5.6 | `WeakExecutionContext` |
| `UStateTreeTaskBlueprintBase::WeakTaskRef` | 5.6 | TaskIndex in WeakExecutionContext |
| `UStateTreeTaskBlueprintBase::ReceiveEnterState(...) → EStateTreeRunStatus`（BP 事件） | all（无版本号） | `ReceiveLatentEnterState` + `FinishTask` |
| `UStateTreeTaskBlueprintBase::ReceiveTick(float) → EStateTreeRunStatus`（BP 事件） | all（无版本号） | `ReceiveLatentTick` + `FinishTask` |
| `UStateTreeTaskBlueprintBase::bHasEnterState_DEPRECATED` / `bHasTick_DEPRECATED` | all（无版本号） | `bHasLatentEnterState` / `bHasLatentTick` |
| `FStateTreeEvaluatorBase::AppendDebugInfoString(FString&, const FStateTreeExecutionContext&)`（final） | 5.8 | `FStateTreeEvaluatorBase::GetDebugInfo(const FStateTreeReadOnlyExecutionContext&)` |
| `FStateTreeCompareIntCondition`/`...FloatCondition`/`...DistanceCondition` 的 `(const EGenericAICheck, const EStateTreeCompare)` 构造器 | 5.8 | `EComparisonOperator` 构造器 |
| 同三类的 `Operator` UPROPERTY（`UE_DEPRECATED_FORGAME`，字段名保留、类型已换） | 5.8 | 同字段新类型 `UE::StateTree::EComparisonOperator`（meta InvalidEnumValues="IsTrue"） |
| `UE::StateTree::Conditions::GenericAICheckToComparisonOperator(EGenericAICheck)` | 5.8 | 直接使用 `EComparisonOperator` |
| `STATETREE_POD_INSTANCEDATA` 宏（StateTreeTypes.h L1388） | 5.8 | `UE_STATETREE_ZEROED_`/`UE_STATETREE_CONSTRUCTED_TRIVIALLY_COPIED_NO_DESTRUCTOR_INSTANCEDATA` |
| `FStateTreeTransitionResult::NextActiveFrames` | 5.7 | `FStateTreeExecutionContext::RequestTransitionResult.Selection.SelectedState`（`FSelectStateResult`） |
| `FStateTreeTransitionResult(const FRecordedStateTreeTransitionResult&)` 构造 | 5.6 | `FStateTreeExecutionContext::MakeTransitionResult` |
| `FStateTreeExecutionContext::FinishTask(const UE::StateTree::FFinishedTask&, EStateTreeFinishTaskType)`（注释级弃用 + PRAGMA 包裹） | 5.7 波 | `FinishTask(const FStateTreeTaskBase&, EStateTreeFinishTaskType)` |
| `IsFinishedTaskValid(FFinishedTask&)` / `UpdateCompletedStateList()` / `MarkStateCompleted(FFinishedTask&)` / 旧 `UpdateInstanceData(TConstArrayView<FStateTreeExecutionFrame>, TArrayView<FStateTreeExecutionFrame>)` | 5.7 波 | 5.7 后新状态选择体系 |
| `FStateTreeDebugTextTask::bEnabled_DEPRECATED`（WITH_EDITORONLY_DATA） | 命名级弃用（PostLoad 迁移，版本锚 1） | 实例数据 `bEnabled` |

说明：`EStateTreeCompare`（Default/Invert，StateTreeConditionBase.h L11-15）无弃用标记，现行（用于构造器）。

---

## 8. 5.6→5.8 签名变迁表

| 版本 | 变化 | 证据 |
|---|---|---|
| **5.6** | `Compile(FStateTreeDataView, TArray<FText>&)` → `Compile(ICompileNodeContext&)`（旧 final 弃用） | StateTreeNodeBase.h L141-142 |
| 5.6 | `OnBindingChanged` 参数 `FStateTreePropertyPath` → `FPropertyBindingPath`（旧 final 弃用） | StateTreeNodeBase.h L186-187 |
| 5.6 | Blueprint 基类缓存三件套 `WeakInstanceStorage/CachedFrameStateTree/CachedFrameRootState` 弃用 → `FStateTreeWeakExecutionContext` | StateTreeNodeBlueprintBase.h L108-119 |
| 5.6 | `FStateTreeWeakTaskRef`（`UStateTreeTaskBlueprintBase::WeakTaskRef`）弃用 → "We now use TaskIndex in WeakExecutionContext" | StateTreeTaskBlueprintBase.h L106-110 |
| 5.6 | `FStateTreeTransitionResult(const FRecordedStateTreeTransitionResult&)` 构造弃用 → `MakeTransitionResult` | StateTreeExecutionTypes.h L1317-1318 |
| **5.7** | `FStateTreeTransitionResult::NextActiveFrames` 弃用 → 状态选择结果改由 `FSelectStateResult` 携带（EnterState 等重载带 `TSharedPtr<FSelectStateResult>`） | StateTreeExecutionTypes.h L1355-1358；ExecutionContext.cpp L3634 |
| 5.7 | 上下文 FinishTask 旧重载（FFinishedTask）及辅助 `IsFinishedTaskValid/UpdateCompletedStateList/MarkStateCompleted/旧 UpdateInstanceData` 全部转 Deprecated 空实现 | ExecutionContext.cpp L2308-2372 |
| **5.8** | **比较算子去 AIModule 化**：`EGenericAICheck` → `UE::StateTree::EComparisonOperator`，**仅覆盖 3 个数值比较条件**（Int/Float/Distance）：`Operator` UPROPERTY 换类型并标 `UE_DEPRECATED_FORGAME(5.8)`、3 个 `EGenericAICheck` 构造器弃用、转换函数 `GenericAICheckToComparisonOperator` 弃用、`IsTrue` 值移入 InvalidEnumValues | StateTreeCommonConditions.h L47-48/59-61/94-95/106-108/231-232/243-245；StateTreeConditionHelpers.h L40-41 |
| 5.8 | 头文件不再隐式 include `AITypes.h`（`#if UE_ENABLE_INCLUDE_ORDER_DEPRECATED_IN_5_8` 包裹） | StateTreeCommonConditions.h L5-7/15；StateTreeConditionHelpers.h L5-7/13 |
| 5.8 | Evaluator 调试接口：`AppendDebugInfoString` final 弃用 → `GetDebugInfo(const FStateTreeReadOnlyExecutionContext&)`（Task 侧新接口无弃用旧版） | StateTreeEvaluatorBase.h L44-47；StateTreeTaskBase.h L104 |
| 5.8 周期内（标记 all） | Blueprint Task FinishTask 范式：`ReceiveEnterState/ReceiveTick`（带 `EStateTreeRunStatus` 返回值）弃用 → 无返回值 `ReceiveLatentEnterState/ReceiveLatentTick` + `FinishTask`；确切引入版本本机无 5.6/5.7 源码对照【未证实】 | StateTreeTaskBlueprintBase.h L70-76/160-163 |
| 5.8 | POD 实例数据宏换代：`STATETREE_POD_INSTANCEDATA` → `UE_STATETREE_ZEROED_/CONSTRUCTED_TRIVIALLY_COPIED_NO_DESTRUCTOR_INSTANCEDATA`（本模块条件实例数据已全用新宏；测试用例 StateTreeTestTypes.h L1164/L1228） | StateTreeTypes.h L1388 |
| 结构性 | Consideration 全族头注释声明 experimental（跨版本风险提示，非弃用标记） | StateTreeConsiderationBase.h L14 |
| 结构性 | 蓝图任务 ExitState 自动清 LatentActions/Timer（为 Latent 范式配套；引入版本未标） | StateTreeTaskBlueprintBase.cpp L70-74 |

**基类签名稳定性对照**（5.8 视角）：`FStateTreeConditionBase`/`FStateTreeTaskBase`/`FStateTreePropertyFunctionBase` 无弃用标记（五虚函数 + Execute 签名稳定）；`FStateTreeEvaluatorBase` 仅 `AppendDebugInfoString`（5.8）；`FStateTreeNodeBase` 仅两个旧重载（5.6，final）；`UStateTree*BlueprintBase` 见 §7。

**任务书猜测 API → 5.8 实际对应物**：

| 任务书曾猜测（5.8 不存在） | 实际对应物 |
|---|---|
| `TickDelta` | `FStateTreeTaskBase::Tick(FStateTreeExecutionContext&, const float DeltaTime)` |
| `RequiresTick` | `bShouldCallTick` / `bConsideredForScheduling` 位（编译期决定 `bCachedRequestTick`，StateTree.cpp L940-944） |
| `TransitionOnCompleted` | `FStateTreeTaskBase::TriggerTransitions()` + `TransitionHandlingPriority` |
| `Completed` | `FStateTreeTaskBase::StateCompleted` |

---

## 9. 常见坑清单

1. **条件实例数据共享**：条件/consideration 实例数据在资产所有使用处共享（StateTreeConditionBase.h L30-31 + EvaluationScope 机制）；事件回调内修改 = 竞态/串扰；需要 per-instance 状态用 Task。
2. **蓝图任务 Tick 隐性开关**：不实现 `ReceiveLatentTick` 就不会 Tick；`bShouldCallTick` 非 UPROPERTY（§5.3）。
3. **返回值语义陷阱（蓝图旧式）**：新式 FinishTask 在事件内调用只是设置 RunStatus、事件返回后生效；异步调用立即生效；同帧先 Tick 后异步 Finish 的胜负由 `SetTaskStatusWithPriority` 定（Succeeded/Failed 覆盖 Running，不反向）。
4. **Tick 返回 Failed 的连锁**：参与完成判定的任务 Failed → 后续任务不再 Tick 且当帧触发状态结束；被跳过任务仍会复制绑定。
5. **`bConsideredForScheduling=false` 的含义**：Delay/RunParallel 自管 ScheduledTick——false 使其 tick/transition 位不计入 `bCachedRequestTick`，避免重复调度；自定义任务自带调度也应关掉它。
6. **PropertyFunction 输出约束**：UI 假定单输出并隐藏之；执行在绑定复制批内部、复制之前；函数失败无独立错误通道（表现为绑定复制失败）。
7. **RunParallel 递归检测不完美**：A↔B 互链检不出；并行树不复制父树全局参数除非 struct 匹配。
8. **DebugText 每帧不重画**：EnterState 一次 `DrawDebugString(-1)`；运行中改 Text 绑定不生效（绑定复制已关）；清除在 ExitState 画空串。
9. **条件 EvaluationMode**：ForcedTrue/ForcedFalse 编译/编辑期固化；"绑定源不可访问 → 表达式整体 false"是评估期保护告警。
10. **`Link` 必须 `[[nodiscard]]`**：忘写返回值编译失败——处理失败必须返回 false。
11. **InstanceData vs ExecutionRuntimeData**：跨 Context 重建要存活的数据（如 Pause/Resume 后仍在）用 `GetExecutionRuntimeDataType`；单次 Tick 临时数据放局部。
12. **蓝图 GetDescription 静态缓存非线程安全**（WITH_EDITOR 静态成员）；事件队列满（MaxActiveEvents=64）溢出行为无测试覆盖。
13. **Random 条件每次求值随机**：放 EnterConditions 会每次进入状态重掷；要"一次掷定"用 Task 或实例数据缓存。
14. **Multiply 操作数对条件无效**：仅 Consideration 支持，条件求值遇之 checkf（程序化构造资产注意）。

---

## 开放问题

1. 【未证实】`ReceiveEnterState/ReceiveTick`（UE_DEPRECATED(all)）与 FinishTask 范式的确切引入版本：`all` 无版本号，本机无 5.6/5.7 源码比对；社区资料指向 5.5/5.6 时段，未采信。
2. 【未证实】Consideration / PropertyFunction 两族的引入版本（推断约 5.5 随效用系统加入，未逐项核实）。
3. 【推断】Consideration 的 Operand（And→Min/Or→Max/Multiply→a*b）合并求值代码在状态选择路径，本模块仅证实单 consideration 的 `GetNormalizedScore` 与枚举注释。
4. 【未证实】`FStateTreeConsiderationResponseCurve::Evaluate` 在曲线非空但输入超范围时依赖 `FRichCurve::Eval` 默认行为（外层 Clamp 兜底，结论不受影响）。
5. 【推断】蓝图 UObject 实例数据的属性绑定复制时机与 struct 实例数据一致（在 CopyBatch/PropertyBindings 层，归 `property-bindings.md` 复核）。
6. 【未证实】`bCopyBoundPropertiesOnNonTickedTask`（ExecutionContext.cpp L4933 引用的私有常量）默认值与配置入口。
7. 【推断】`bShouldCallTickOnlyOnEvents` 的"事件"口径：任务 Tick 判定只看 EventQueue（L4961-4965），与 BroadcastedDelegates 触发的转换处理（L5857-5862）口径差异未逐行核实。
8. 【未证实】C++ 派生 `UStateTreeTaskBlueprintBase` 子类手工设 `bShouldCallTick=false` 在资产序列化往返后是否始终保留（TaskFlags 桥应保留，未做序列化测试）。
9. 计数口径：本文"39 内置节点类"已对 5.8 源码清点核实；若后续对照官方 API 文档页发现类清单差异（如编辑器专用包装类计数口径），以源码为准并回填 §1.3。
