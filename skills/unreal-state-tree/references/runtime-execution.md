# UE 5.8 StateTree 运行时执行模型（runtime-execution）

> 版本基线：UE 5.8.0 (Release-5.8, CL 55116800) · 版本标记约定：**[UE 5.x+]**=该版本新增，**[仅 <5.x]**=已移除/旧行为，**[5.8 变更]**=本版变更；现行 API 判定标准=声明无 UE_DEPRECATED 标记。

## TL;DR

- 5.8 执行模型是三层上下文：`FStateTreeReadOnlyExecutionContext`（只读，可多实例并存）→ `FStateTreeMinimalExecutionContext`（+`SendEvent`/调度请求）→ `FStateTreeExecutionContext`（Start/Tick/Stop/状态选择/转换）；运行状态全部存于 `FStateTreeInstanceStorage`（布局见 [instance-data.md](instance-data.md)）。
- `FStateTreeExecutionContext::Start(FStartParameters)` **[UE 5.8+]**：注入全局参数/`FStateTreeExecutionExtension`/共享事件队列/随机种子/启动状态 Tag 覆盖 → InitFrame → StartGlobals → `SelectState` → `EnterState`；Start 期间全局评估器被立即 Tick 一次（DeltaTime=0）。
- `FStateTreeExecutionContext::Tick` 四阶段：`TickPrelude` → 阶段A `TickUpdateTasksInternal`（延迟转换倒计时+任务 Tick）→ 阶段B `TickTriggerTransitionsInternal`（最多 **5 轮**「TriggerTransitions→ExitState→EnterState→StateCompleted」重规划）→ `TickPostlude`（补做延迟 Stop）。
- 转换请求：转换处理阶段内（`FAllowDirectTransitionsScope`）直接执行；阶段外只缓冲进 Storage（上限 32），下一轮 TriggerTransitions 开头处理；延迟转换以 `FStateTreeTransitionDelayedState` 挂 `Exec.DelayedTransitions`。
- 状态选择 `FStateTreeExecutionContext::SelectState` 递归展开 + `EStateTreeStateSelectionBehavior` 分派；Utility 评分用括号栈机（And=Min / Or=Max / Multiply / Copy），最终 `Score = StateWeight * Values[0]`。
- 重入防护真相：`FStateTreeExecutionState::CurrentPhase` 仅 **StartTree/StopTree/TickStateTree/Unset** 四值参与判定，枚举其余值只是 Trace 调试标签；相位内调 Stop 一律延迟到相位边界。
- 并行子树 `FStateTreeRunParallelStateTreeTask` 用分片 API `TickUpdateTasks`/`TickTriggerTransitions` 在主树对应相位内驱动子树，并与主树共享事件队列。

## 目录

1. [证据路径约定](#0-证据路径约定)
2. [执行上下文三层模型](#1-执行上下文三层模型)
3. [Start(FStartParameters) 全流程](#2-startfstartparameters-全流程)
4. [Tick 四阶段与阶段时序](#3-tick-四阶段与阶段时序)
5. [状态选择 SelectState 与 Considerations 评分](#4-状态选择-selectstate-与-considerations-评分)
6. [转换请求与延迟转换](#5-转换请求与延迟转换)
7. [RAII Scope 体系](#6-raii-scope-体系)
8. [重入防护（CurrentPhase）](#7-重入防护currentphase)
9. [Stop 流程与延迟停止](#8-stop-流程与延迟停止)
10. [并行子树（FStateTreeRunParallelStateTreeTask）](#9-并行子树fstatetreerunparallelstatetreetask)
11. [执行相关 CVar 开关](#10-执行相关-cvar-开关)
12. [执行层弃用 API](#11-执行层弃用-api)
13. [开放问题](#12-开放问题)

## 0. 证据路径约定

- 证据均出自本机 5.8 引擎源码，引用格式为 `文件相对路径 L行号`，相对根：`E:\UnrealEngine\UE_5.8\Engine\Plugins\Runtime\StateTree\Source\StateTreeModule\`（下文简称"模块根"）。
- 行为佐证引用调研报告 12-tests.md（`C:\Users\TireflyPC\.agents\tmp\state-tree-research\12-tests.md`）的结论表述，不复制其断言表。
- 分工边界（本文档只链接不展开）：事件队列/委托/ScheduledTick 优先级链/Weak-Strong 异步上下文 → [events-async.md](events-async.md)；InstanceData 内存布局与并发探测器 → [instance-data.md](instance-data.md)；Linked Tree/Reference/Overrides 资产机制 → [assets-types.md](assets-types.md)；组件宿主封装 → [gameplay-state-tree.md](gameplay-state-tree.md)。

## 1. 执行上下文三层模型

| 层 | 类型（全名） | 能力 | 访问级别 |
|---|---|---|---|
| 只读层 | `FStateTreeReadOnlyExecutionContext` | `IsValid()`/RunStatus/活动状态查询/`HasEventToProcess()`/`GetNextScheduledTick()` | 构造即 `Storage.AcquireReadAccess()`；多个实例可跨线程共存 |
| 写层 | `FStateTreeMinimalExecutionContext` | 只读层全部 + `SendEvent()`/`AddScheduledTickRequest()`/`UpdateScheduledTickRequest()`/`RemoveScheduledTickRequest()` | 再 `AcquireWriteAccess()`，独占写 |
| 完整层 | `FStateTreeExecutionContext` | Start/Tick/Stop/`SelectState`/转换/委托/`FinishTask()` | 写访问；**禁止跨帧保存**（拷贝/赋值均 delete，头 L341-342） |

- 继承声明位置：Public\StateTreeExecutionContext.h L72 / L224 / L329；只读共存的注释前提（不存在 Minimal/Weak/Regular 上下文时）见头 L67-71。
- 完整上下文构造副作用：缓存 `EventQueue = InstanceData.GetSharedMutableEventQueue()`、`ContextAndExternalDataViews.SetNum(RootStateTree.GetNumContextDataViews())`；析构将所有 ActiveFrame 的 `ExternalDataBaseIndex` 置空（外部数据须重收集）——Private\StateTreeExecutionContext.cpp L1109-1175。
- `IsValid()` = `RootStateTree.IsReadyToRun()`（已编译+Link）——Public\StateTreeExecutionContext.h L89-92。
- 并发纪律：同一 Storage 上 N 个只读上下文或 1 个写上下文，混用即 UE_MT MRSW 探测器报警（DO_CHECK 构建）——机制见 [instance-data.md](instance-data.md)。
- 跨帧/跨线程需求走 `FStateTreeExecutionContext::MakeWeakExecutionContext()` → Weak/Strong 上下文，见 [events-async.md](events-async.md)。

## 2. Start(FStartParameters) 全流程

### 2.1 FStartParameters 字段（**[UE 5.8+]** 收拢形态）

| 字段 | 类型 | 语义 |
|---|---|---|
| `InitialGlobalParameters` | `FConstStructView` | 全局参数初始值覆盖（**[5.8 变更]** 由 FInstancedPropertyBag 指针改为 struct view） |
| `ExecutionExtension` | `TInstancedStruct<FStateTreeExecutionExtension>` | 宿主扩展（MoveTemp 进 `Exec.ExecutionExtension`，仅注入一次） |
| `SharedEventQueue` | `const TSharedPtr<FStateTreeEventQueue>` | 共享事件队列；设置后本实例**不再拥有**队列（`IsOwningEventQueue()==false`） |
| `RandomSeed` | `TOptional<int32>` | 默认 `FPlatformTime::Cycles()` |
| `SelectStateOverrideArgs` | `TOptional<FStateToSelectOverrideArgs>`{`StateTag`, `TagQueryMethod`} | 按 GameplayTag 覆盖启动状态（默认 Root） |
| `GlobalParameters`（WITH_EDITORONLY_DATA） | `const FInstancedPropertyBag*` | UE_DEPRECATED(5.8) → `InitialGlobalParameters` |

证据：Public\StateTreeExecutionContext.h L440-471。

### 2.2 Start 步骤表

`EStateTreeRunStatus FStateTreeExecutionContext::Start(FStartParameters Parameters)`——Private\StateTreeExecutionContext.cpp L1461-1673：

| # | 步骤 | 要点 |
|---|---|---|
| 1 | 有效性/重入检查 | `IsValid()`；`ensureMsgf(Exec.CurrentPhase == EStateTreeUpdatePhase::Unset)` 失败返回 Failed（L1472-1484） |
| 2 | 已在 Running 则先 `Stop()` | Start 即重启（L1487-1490） |
| 3 | `InstanceData.Reset()` | 清空整个 InstanceStorage（L1493） |
| 4 | **ExecutionExtension 注入点** | `Exec.ExecutionExtension = MoveTemp(Parameters.ExecutionExtension)`（L1497）；之后每帧新建的 Context 自动拾取，无需重复注入 |
| 5 | SharedEventQueue | `InstanceData.SetSharedEventQueue(...)`（L1498-1501） |
| 6 | 全局参数 | `SetGlobalParameters(InitialGlobalParameters)` 失败或未给 → 回退 `RootStateTree.GetDefaultParameters().GetValue()`；类型校验后 `Storage.SetGlobalParameters`（L1508-1511 + L3526-3536） |
| 7 | 随机流 | `Exec.RandomStream.Initialize(seed)`（L1513） |
| 8 | `TGuardValue(bAllowedToScheduleNextTick, false)` | Start 期间不唤醒宿主（L1515） |
| 9 | 临时选择结果 | `TSharedRef<FSelectStateResult>` + `TGuardValue(CurrentlyProcessedTemporaryStorage, ...)`（L1519-1521） |
| 10 | InitFrameID 与启动状态解析 | `FActiveFrameID(Storage.GenerateUniqueId())`；`GetSelectStartStateInfo()`：有覆盖则 `RootStateTree.GetStateHandleFromGameplayTag(StateTag, TagQueryMethod)` 定位状态并上溯到 FrameRoot（子树视作独立树），否则 `{Root, Root}`；找不到覆盖 Tag → Failed（L1523-1535） |
| 11 | 建 GlobalFrame | `SelectStateResult->MakeAndAddTemporaryFrame(InitFrameID, InitFrameHandle, bIsGlobalFrame=true)`，并设 `ExecutionRuntimeIndexBase`、`GlobalParameterDataHandle`、`GlobalInstanceDataFrameID`、`StateParameterDataHandle`（Root 态参数）（L1537-1547） |
| 12 | `CollectActiveExternalData(TemporaryFrames)` | 失败返回 Failed（L1549-1554） |
| 13 | `SetUpdatePhase(StartTree)` | 此后 Stop 全部转延迟（L1563） |
| 14 | `StartTemporaryEvaluatorsAndGlobalTasks` | 逐个 `Eval.TreeStart` + GlobalTask `EnterState`（带绑定拷贝与输出绑定拷贝、完成委托广播）；任一失败 → FrameResult 失败（L1568 + L4348-4537） |
| 15 | Start 特例 | 全局成功后 `TickGlobalEvaluatorsForFrameWithValidation(DeltaTime=0.0f)`（注释 "Exception with Start. Tick the evaluators."）（L1571-1573） |
| 16 | 状态选择 | `TreeRunStatus=Running; LastTickStatus=Unset`；构造 `FSelectStateArguments`（SourceState 为空、TargetState=启动状态、Behavior=StateTransition）→ `SelectState(...)`（L1576-1584） |
| 17 | 进入状态 | 目标为完成态 → 直接置 TreeRunStatus；否则 `EnterState(SelectStateResult, Transition{TargetState=Root})`；非 Running → 立即 `StateCompleted()`；ActiveFrames 仍空 → Failed（"Check that the StateTree logic can always select a state at start."）（L1586-1623） |
| 18 | 失败收尾 | TreeRunStatus != Running → `StopTemporaryEvaluatorsAndGlobalTasks` + `ActiveFrames.Reset()` + `RemoveAllDelegateListeners()` + `SelectedFrames.Pop()`；`InstanceData.ResetTemporaryInstances()`；`SetUpdatePhase(Unset)`（L1640-1659） |
| 19 | 延迟 Stop 补做 | `RequestedStop != Unset && Running` → `Stop(Exec.RequestedStop)`（L1664-1670） |

### 2.3 ExecutionExtension 参与时机

`FStateTreeExecutionExtension`（USTRUCT + 虚函数，非 UObject，Public\StateTreeExecutionExtension.h L22-81）；注入仅在 Start 第 4 步，之后 4 个触发点：

| 虚函数 | 触发时机 | 调用点 |
|---|---|---|
| `GetInstanceDescription(FContextParameters)` | 每次 STATETREE_LOG 前缀 | cpp L812-818 |
| `ScheduleNextTick(FContextParameters, FNextTickArguments)` | `SendEvent`/调度请求增删改/缓冲路径 `RequestTransition`/委托广播命中转换时；受 `bAllowedToScheduleNextTick` 与 `RootStateTree.IsScheduledTickAllowed()` 双闸 | Minimal 层 cpp L945-954；调度语义 → [events-async.md](events-async.md) |
| `OnLinkedStateTreeOverridesSet(FContextParameters, Overrides)` | `SetLinkedStateTreeOverrides` 实际变更后 | cpp L1274-1281 |
| `OnBeginApplyTransition(FContextParameters, TransitionResult)` | 每次转换应用前（ExitState 之前） | cpp L2035-2041 / L2942 |

### 2.4 启动状态 Tag 覆盖（SelectStateOverrideArgs）

- `FStateToSelectOverrideArgs{StateTag, TagQueryMethod}`（默认 `UStateTree::EStateGameplayTagQueryMethod::MatchesExact`）经 `GetSelectStartStateInfo()` 解析为具体状态句柄并上溯到其所在子树的 FrameRoot（Public\StateTreeExecutionContext.h L454-464；cpp L1525-1535）。
- 覆盖**优先于 Utility 评分**：12-tests.md §2.1 `FStateTreeTest_OverrideStartState` 断言 0.5 分候选胜过 1.0 分候选；命中中间状态时自动带上祖先链，Subtree 状态只激活自身。

### 2.5 Start 行为契约（12-tests.md 结论）

- **Start 即重启**：对 Running 树重复 Start → 先全量 ExitState 再重新 EnterState（12-tests §2.1 `FStateTreeTest_Restart`）。
- **返回值语义**：全局任务失败/树无法选中初始状态 → Start 直接返回 Failed；普通状态任务 EnterState 失败 → Start 仍返回 Running，收尾推迟到下一 Tick；全局任务 EnterState 失败 → Start 直接返回终态（12-tests §2.1 Stop_* 系列）。
- Start 期间任意阶段调 `Stop()` 均延迟到 Start 尾部生效（12-tests §2.1 `FStateTreeTest_DeferredStop_*`）。
- Start 即触发评估器 Tick(0)：评估器 Tick 有副作用时注意（cpp L1571-1573）。

## 3. Tick 四阶段与阶段时序

### 3.1 总时序

`EStateTreeRunStatus FStateTreeExecutionContext::Tick(const float DeltaTime)`——cpp L1812-1831：

```text
TGuardValue(bAllowedToScheduleNextTick, false)   // Tick 期间不因事件唤醒宿主
TickPrelude()                 // 有效?→CollectActiveExternalData→Running?→ensure(Unset)→CurrentPhase=TickStateTree
TickUpdateTasksInternal(DeltaTime)   // 阶段 A
TickTriggerTransitionsInternal()     // 阶段 B（最多 5 轮）
TickPostlude()                // CurrentPhase=Unset → 补做延迟 Stop → 返回 TreeRunStatus
```

### 3.2 Prelude / Postlude 职责

| 函数 | 行为 | 证据 |
|---|---|---|
| `TickPrelude()` | `IsValid()` 失败→Failed；`CollectActiveExternalData()` 失败→Failed；树非 Running → 直接返回其状态（不设相位）；`ensureMsgf(CurrentPhase==Unset)` 重入护栏；`SetUpdatePhase(TickStateTree)` | cpp L1754-1788 |
| `TickPostlude()` | `SetUpdatePhase(Unset)`（"now safe to stop"）→ 若 `Exec.RequestedStop != Unset` → `Stop(RequestedStop)` 并返回其结果 | cpp L1791-1810 |

### 3.3 阶段 A：TickUpdateTasksInternal(DeltaTime)

cpp L1873-1963：

1. `RequestedStop` 已置 → 跳过；`DeltaTime = FMath::Max(0.f, DeltaTime)`。
2. **延迟转换倒计时**：`Exec.DelayedTransitions` 逐项 `TimeLeft -= DeltaTime`（L1887-1890）。
3. 默认（CVar `StateTree.TickGlobalNodesFollowingTreeHierarchy=true`）：`TickTasks(DeltaTime)`（含逐帧全局节点，见下）写 `Exec.LastTickStatus`；非 Running 且前一帧 Running 且无 RequestedStop → 立即 `StateCompleted()`（L1901-1912）。
4. 关闭该 CVar 时（5.5 兼容路径：CVar 可关闭，5.8 仍保留）：先 `TickEvaluatorsAndGlobalTasks`（全部 frame 的全局节点）再状态任务；全局任务失败按 `bGlobalTasksCompleteOwningFrame` 决定停止粒度（true=仅根 frame 停树；false=任一完成即停树）（L1914-1962）。

`TickTasks(float)` 内层规则（cpp L4747-4921）：

- 逐 Frame：`bIsGlobalFrame` 先 `TickEvaluatorsAndGlobalTasksForFrame`（Eval.Tick → GlobalTask Tick），Frame 结果非 Running 时按 CVar 决定 RequestedStop 粒度。
- 逐 State：`bCopyParameterBindingsOnTick` 拷贝状态参数绑定；`State.ShouldTickTasks(bHasEvents)`（编译期事件需求位）或 CVar `StateTree.CopyBoundPropertiesOnNonTickedTask` 才进入任务 Tick。
- **零任务自动完成**：整树 enabled 任务数为 0 且全部 Running → 把最底 frame 的最底活动状态 `SetCompletionStatus(Succeeded)`（ensure 兜底，L4893-4916）。
- 结果收集在**全部任务有机会 Tick 之后**（异步/委托可能完成"前面"的任务）：逐 frame 聚合 `ActiveTasksStatus.GetCompletionStatus()`（L4854-4883）。
- 聚合优先级：Failed > Succeeded > Stopped > Running（`GetPriorityRunStatus` 的 PriorityMatrix）——cpp L331-343。

### 3.4 阶段 B：TickTriggerTransitionsInternal（最多 5 轮）

cpp L1965-2033：

```text
static constexpr int32 MaxIterations = 5;                  // L1979
for (Iter = 0; Iter < 5; ++Iter):
    ON_SCOPE_EXIT { InstanceData.ResetTemporaryInstances(); }
    if (TriggerTransitions()):                    // 产生 RequestedTransition
        BeginApplyTransition(Transition)          // ExecutionExtension 钩子
        ExitState(Selection, Transition)
        if TargetState 是完成态: TreeRunStatus = 完成态; ensure(ActiveFrames空); break
        LastTickStatus = EnterState(Selection, Transition)
        if LastTickStatus != Running: StateCompleted()
    if (LastTickStatus == Running && !Storage.HasBroadcastedDelegates()): break
```

- **每帧最多 5 轮「选择→退出→进入→完成」重规划**：EnterState 失败的任务可在同帧立即重选新状态（源码注释 "This helps event driven StateTrees to not require another event/tick to find a suitable state."）；有未消化广播委托也继续循环。
- 事件队列清空时机 = `TriggerTransitions` 结束的 ON_SCOPE_EXIT（仅 `IsOwningEventQueue()` 才 `ClearEventsForCurrentTransitionProcessingPhase()`）——cpp L5767-5779；事件生命周期语义 → [events-async.md](events-async.md)。

### 3.5 分片 API（供并行子树等逐阶段调用）

| API | 组成 | 证据 |
|---|---|---|
| `EStateTreeRunStatus TickUpdateTasks(float DeltaTime)` | Prelude + 阶段A + Postlude | cpp L1833-1851 |
| `EStateTreeRunStatus TickTriggerTransitions()` | Prelude + 阶段B + Postlude | cpp L1853-1871 |

`FStateTreeRunParallelStateTreeTask` 在 `Tick` 回调里调 `TickUpdateTasks`、在 `TriggerTransitions` 回调里配合 `FEventsPendingForNextTransitionProcessingScope` 调 `TickTriggerTransitions`（Private\Tasks\StateTreeRunParallelStateTreeTask.cpp L124 / L145-152）。

### 3.6 每帧回调时序总表

| 时机 | 遍历方向 | 顺序要点 |
|---|---|---|
| `ExitState`（转换/Stop 应用时） | Frame 自叶向根（FrameIndex 降序），Frame 内 State 降序 | ① `CopyAllBindingsOnActiveInstances(ExitState)`；② 任务**降序** ExitState（仅 `TaskIndex <= ActiveNodeIndex`，即收到过 EnterState 的）→ 输出绑定拷贝；③ 条件降序 ExitState（仅 `bHasStateChangeConditions`）；④ 非 Sustained → `CleanState`（清委托监听/延迟转换）+ `ActiveStates.Pop()`；⑤ Frame 收尾：全局帧 → `StopGlobalsForFrameOnActiveInstances`（GlobalTask.ExitState → Eval.TreeStop 降序）；Frame 非共有 → 移出 ActiveFrames |
| `EnterState`（Start 或转换应用时） | Frame 自根向叶（升序），State 升序 | ① `UpdateInstanceData`（双缓冲重排：共有段保留、新增段从临时/默认值实例化）；② `CaptureNewStateEvents`（选择期捕获事件写入 StateEvent 槽）；③ 逐 State：新 Frame → 全局节点 Start；非 Sustained → `ActiveTasksStatus.Push` + `ActiveStates.Push`；④ 状态参数绑定拷贝；⑤ 条件**升序** EnterState；⑥ 任务**升序**：`MoveTemporaryToInstance` → 输入绑定拷贝 → `EnterState` → 输出绑定拷贝 → 完成委托广播。Sustained 态仅当 `Task.bShouldStateChangeOnReselect` 才回调 |
| Tick | Frame 升序，帧内全局节点先、State 升序 | 见 §3.3 |
| `StateCompleted`（状态完成时立即） | Frame 自叶向根，State 降序，任务降序 | 任务降序 `StateCompleted` → 条件降序 `StateCompleted`（Sustained 与 Changed 都调用） |

证据：ExitState cpp L3904-4084；EnterState cpp L3634-3897；StateCompleted cpp L4091-4154。
Sustained/Changed 判定：目标状态在新选择路径上且转换前已激活（`FActiveStatePath::Intersect` 求共有前缀，Target 在共有段中才 Sustained）——cpp L3711-3719 / L3937-3945。

## 4. 状态选择 SelectState 与 Considerations 评分

### 4.1 入口与参数

- 签名：`bool FStateTreeExecutionContext::SelectState(const FSelectStateArguments& SelectStateArgs, const TSharedRef<FSelectStateResult>& OutSelectionResult)`——cpp L6600-6888 **[UE 5.7+]**。
- `FSelectStateArguments` 字段（Public\StateTreeExecutionContext.h L1301-1328）：`ActiveStates`（活动路径快照）/ `SourceState` / `TargetState`（`UE::StateTree::ExecutionContext::FStateHandleContext`）/ `TransitionEvent` / `Fallback`（`EStateTreeSelectionFallback`）/ `Behavior`（`ESelectStateBehavior`{StateTransition, Forced}）/ `SelectionRules`（`EStateTreeStateSelectionRules`）。
- 结果 `FSelectStateResult`（实现 `ITemporaryStorage`）：`SelectedStates`/`SelectedFrames`/`TemporaryFrames`/`SelectionEvents`/`TargetState` **[UE 5.7+]**（取代 5.6 及以前的 `FStateSelectionResult`）。
- 深度上限：`FStateTreeActiveStates::MaxStates = 8`，超限直接失败（Public\StateTreeExecutionTypes.h L320）。

### 4.2 SelectState 主流程（7 步）

cpp L6600-6888：

1. 校验目标（非完成态、资产含该状态）与源（FrameID 有效；SourceStateID 可无效=从 Frame 根开始）。
2. `GetStatesListToState(Target)`：从目标沿 Parent 链到根再 Reverse，得 `PathToTargetState`（上限 8）。
3. `TargetFrameHandle = FExecutionFrameHandle(Tree, PathToTargetState[0])`（Frame 根）。
4. 由活动路径构造 `SourceStates`（源在活动路径中的前缀；源态无效时取源 frame 第一个活动态）。
5. 定位 `TargetFrameID`：目标 Frame 即源 Frame → 沿用；否则**只允许向上跨 frame**（"Can jump to a state from a previous frame"），共有部分拷进结果。
6. 组装 `FSelectStateInternalArguments`（MissingActiveStates/MissingSourceFrameID/MissingSourceStates/MissingStatesToReachTarget）→ 递归 `SelectStateInternal`。
7. 失败且 `Fallback == NextSelectableSibling` → 用 `GetNextSibling()` 逐兄弟重试。

### 4.3 SelectStateInternal 递归要点

cpp L6904-7418：

- 跳过 disabled 状态与 `SelectionBehavior == None`；`FCleanUpOnExit` RAII 失败即弹出本次加入的 state/frame。
- 进入无父链的子树时 `MakeAndAddTemporaryFrameWithNewRoot`（继承外部数据/全局实例基址/全局参数）。
- 源路径快路径：沿 MissingSourceStates 复用活动态；`CompletedStateBeforeTransitionSourceFailsTransition` 规则下源之前的状态已完成则转换失败。
- `bCreateNewState` 判定受 `ReselectedStateCreatesNewStates`/`CompletedTransitionStatesCreateNewStates` 规则影响（否则不在活动态即新状态）。
- LinkedAsset 运行时覆盖：`bCanOverrideLinkedAssetAtRuntime` 时 `GetLinkedStateTreeOverrideForTag(StateTag)` 替换资产与参数（资产机制 → [assets-types.md](assets-types.md)）。
- 事件接受：`RequiredEventToEnter` 匹配（优先复用转换事件；否则扫事件队列；非必需且无匹配则放哑事件继续）。
- Linked 子树 → `SelectStateInternal_Linked`（cpp L7557-7698，同资产 frame，防递归）；LinkedAsset → `SelectStateInternal_LinkedAsset`（cpp L7700-7915，**选择期即 `StartTemporaryEvaluatorsAndGlobalTasks`**，"so that their data is available already during select"）。
- 达到 Target（非 Forced）→ 按 `SelectionBehavior` 分派（cpp L7368-7392）。

### 4.4 EStateTreeStateSelectionBehavior 分派表

枚举定义：Public\StateTreeTypes.h L172-198；引擎实现函数均在 Private\StateTreeExecutionContext.cpp：

| 枚举值 | 语义 | 实现函数 |
|---|---|---|
| `None` | 不可直接选中（选择时跳过） | — |
| `TryEnterState` | 选中自身（即使有子状态） | 直接返回成功 |
| `TrySelectChildrenInOrder` | 按子状态顺序逐个尝试 | 顺序递归 |
| `TrySelectChildrenAtRandom` | 洗牌子状态后逐个尝试 | `SelectStateInternal_TrySelectChildrenAtRandom`（L7954-7998） |
| `TrySelectChildrenWithHighestUtility` | 选最高 Utility 子状态，平分按序 | `SelectStateInternal_TrySelectChildrenWithHighestUtility`（L8000-8071） |
| `TrySelectChildrenAtRandomWeightedByUtility` | 按 Utility 归一化概率轮盘赌 | `SelectStateInternal_TrySelectChildrenAtRandomWeightedByUtility`（L8073-8148） |
| `TryFollowTransitions` | 尝试触发转换而非选择子状态 | `SelectStateInternal_TryFollowTransitions`（L8150 起） |
| `TrySelectChildrenAtUniformRandom` / `TrySelectChildrenBasedOnRelativeUtility` | UE_DEPRECATED(all)，仅为资产序列化保留的旧名 | 映射到上两行 |

### 4.5 Considerations 括号栈评分

`float FStateTreeExecutionContext::EvaluateUtilityWithValidation(CurrentParentFrame, CurrentFrame, CurrentStateHandle, MemoryRequirement, ConsiderationsBegin, ConsiderationsNum, StateWeight)`——cpp L5278-5392 **[UE 5.7+]**（旧 `EvaluateUtility` 5.7 弃用，现仅转调验证版）：

- 栈结构：`TStaticArray<EStateTreeExpressionOperand, UE::StateTree::MaxExpressionIndent + 1> Operands` + 同长 `Values` 浮点栈；`Consideration.DeltaIndent` 决定开/闭括号数（L5296-5351）。
- 每个考虑度（Consideration）：`CopyBatchWithValidation` 拷贝绑定，失败 → **整个表达式 = 0**（L5322-5330）；`Consideration.GetNormalizedScore(Context)` 取归一化分。
- 闭括号合并规则（L5362-5378）：`Copy`→覆盖、`And`→`FMath::Min`、`Or`→`FMath::Max`、`Multiply`→相乘。
- 最终 `Score = StateWeight * Values[0]`（L5387）。
- 评估作用域实例数据由 `FEvaluationScopeInstanceContainer` 栈上 alloca 承载（L5299-5309）→ 内存布局见 [instance-data.md](instance-data.md)；与条件求值 `TestAllConditionsInternal`（cpp L5056-5181）同构，但操作符是布尔 And/Or/Copy。
- 测试盲区：Considerations 求值本体无专门自动化测试；唯一触达点是启动覆盖优先于 Utility（12-tests.md §2.1 / §5 盲区 5）。

### 4.6 两个 Utility 选择器行为

| 选择器 | 算法 | 证据 |
|---|---|---|
| `TrySelectChildrenWithHighestUtility` | 全部子状态逐个 `EvaluateUtilityWithValidation` 评分 → 取最高者尝试进入；失败 `RemoveAtSwap` 剔除后取次高 | cpp L8019-8068 |
| `TrySelectChildrenAtRandomWeightedByUtility` | 仅保留 Score>0 的候选；`Exec.RandomStream.FRand() * TotalScore` 轮盘赌；失败剔除并 `TotalScore -= Score` | cpp L8095-8145 |

- 无子状态时按"向后兼容"语义选中自身（"Select this state (For backwards compatibility)"，L8010-8015）。
- 随机源 = `FStartParameters.RandomSeed`（默认 `FPlatformTime::Cycles()`）；种子可重现性无专门测试（12-tests.md §5 盲区 10）。

## 5. 转换请求与延迟转换

### 5.1 RequestTransition 两条路径

`void FStateTreeExecutionContext::RequestTransition(...)`（Public\StateTreeExecutionContext.h L761-779；cpp L2176-2244）：

| 路径 | 条件 | 行为 |
|---|---|---|
| 直接执行 | `bAllowDirectTransitions == true`（仅 `TriggerTransitions` 的 `FAllowDirectTransitionsScope` 作用域内，含任务 `TriggerTransitions` 回调） | 用当前处理 Frame/State 解析 SourceStateID → `RequestTransitionInternal(...)` **立即**尝试（可能因目标前置条件失败）；成功后 `RequestedTransition->Source` 记 `FStateTreeTransitionSource` |
| 缓冲执行 | 其余所有时机（如任务 Tick 回调内） | `InstanceData.AddTransitionRequest(...)`（Storage 缓冲，**上限 32，溢出丢弃并 VLOG Error**）+ `ScheduleNextTick(ETickReason::TransitionRequest)`；下一轮 `TriggerTransitions` 开头消费 |

- 12-tests.md §2.2 `FStateTreeTest_RequestTransition` 佐证：任务 Tick 内请求在**同一次 Tick 内**（阶段 B）完成重选，覆盖子级/兄弟/父级/自身/Linked/跨根 8 类目标。

### 5.2 RequestTransitionInternal 规则

cpp L5501-5678：

1. **优先级压制**：已有 `RequestedTransition` 且其 Priority ≥ 新 Priority → 拒绝（低优先级让位）。
2. 目标为完成态（Succeeded/Failed）→ 直接 `SetupNextTransition`（不做选择）；目标 Invalid → 同样 Setup（no-op 转换，可用来"屏蔽"父级同 tick 的其它转换）。
3. 常规：组装 `FSelectStateArguments` → `SelectState` → `SetupNextTransition` 填 `FStateTreeTransitionResult`（ChangeType=Changed）并把 Selection 挂到 `RequestedTransition->Selection`。
4. 存在上一次成功选择时，逆序清理被放弃路径的临时 LinkedAsset frame 全局节点（`StopTemporaryEvaluatorsAndGlobalTasks` + `CleanFrame`）。
5. `bConsumeEventOnSelect` 的状态消费其选择事件；CVar `StateTree.SetDeprecatedTransitionResultProperties`（默认 false）控制旧兼容字段回填。

### 5.3 TriggerTransitions 四段式

`bool FStateTreeExecutionContext::TriggerTransitions()`——cpp L5734-6386（源码注释步骤 1-4）：

1. `FAllowDirectTransitionsScope`（本函数内允许直接转换）；`RequestedTransition.Reset()`；`CurrentlyProcessedBroadcastedDelegates = Storage.StealBroadcastedDelegates()`。
2. 消费缓冲请求 → `InstanceData.ResetTransitionRequests()`（L5784-5803）。
3. 收集到期延迟转换（`TimeLeft <= 0`，SwapRemove）；收集 `FTransitionHandler`（`bShouldAffectTransitions` 的转换任务、需要 Tick 转换的状态、有到期延迟的状态、全局转换任务），`StableSort` 按**优先级降序**（同优先级保加入序）（L5821-5936）。
4. 逐 Handler：任务 → `Task.TriggerTransitions(Context)`；状态 → 遍历状态转换（跳过 disabled/优先级不高于已请求/`OnStateCompleted` 触发器），条件通过后请求转换（见 §5.4）。
5. **完成转换**：无 RequestedTransition 且（`LastTickStatus != Running || bHasPendingCompletedState`）→ 从第一个完成状态向上，按 `OnStateSucceeded/OnStateFailed/OnStateCompleted` 测试并请求（**不允许延迟、优先级固定 Normal**）；全部失败 → 请求跳回 Root；Root 也失败 → `Exec.RequestedStop = Failed`（L6141-6332）。
6. **子树完成折叠**：请求目标为完成态且源 frame 非根 → 父 frame 的 Linked 状态置完成、`bHasPendingCompletedState=true`，再以 `FTriggerTransitionsInternalArgs::CompletedSubtreeParentFrameIndex` **递归**调用自身（此时不取事件/委托）（L6335-6377）。
7. no-op 请求（Target Invalid）丢弃；返回 `RequestedTransition.IsValid()`。

### 5.4 延迟转换生命周期

| 阶段 | 行为 | 证据 |
|---|---|---|
| 登记 | 转换 `HasDelay()` 时去重（StateID+TransitionIndex+CapturedEventHash）→ `Delay.GetRandomDuration(Exec.RandomStream)`>0 则挂 `FStateTreeTransitionDelayedState{StateID, TransitionIndex, TimeLeft, CapturedEvent(+Hash)}` 进 `Exec.DelayedTransitions`，并调用虚钩子 `BeginDelayedTransition(DelayedState)`（默认空；引擎内覆写者仅 `FMassStateTreeExecutionContext`）；延迟为 0 则 fallthrough 立即请求 | cpp L5941-6136 |
| 倒计时 | 阶段 A 逐项 `TimeLeft -= DeltaTime`（**登记所在 tick 不计入**） | cpp L1887-1890；12-tests §2.2 `TransitionDelay` |
| 到期 | 阶段 B 收集 `TimeLeft <= 0` 项，用捕获的 `CapturedEvent` 触发并按 `bConsumeEventOnSelect` 消费 | cpp L5808-5816 |
| 语义 | 零延迟（DelayDuration=0）等效即时转换，同一次 Tick 内完成；延迟期间源状态继续正常 Tick | 12-tests §2.2 `TransitionDelayZero` |

### 5.5 ForceTransition（复制同步，简述）

- `EStateTreeRunStatus ForceTransition(const FRecordedStateTreeTransitionResult&)`：跳过一切条件，按记录状态路径 `SelectState(Forced)` → `BeginApplyTransition` → `ExitState` → `EnterState`，用于客户端回放服务端转换历史；录制入口为构造参数 `EStateTreeRecordTransitions::Yes` + `GetRecordedTransitions()`。证据 cpp L2886-2946；相位内调用直接失败（"Can't force a transition while %s"，L3051-3056）。

## 6. RAII Scope 体系

六个 Scope（均为 `FStateTreeExecutionContext` 私有嵌套类型，Public\StateTreeExecutionContext.h L1629-1777）：

| Scope | 保护对象 | 备注 |
|---|---|---|
| `FCurrentlyProcessedFrameScope` | `CurrentlyProcessedFrame`/`ParentFrame`/`CurrentlyProcessedSharedInstanceStorage`（进入时从 `Frame.StateTree->GetSharedInstanceData()` 解析） | Frame 维度节点回调的标准包裹（cpp L1046-1099） |
| `FCurrentlyProcessedStateScope` | `CurrentlyProcessedState` | State 维度（头内联实现） |
| `FCurrentlyProcessedTransitionEventScope` | `CurrentlyProcessedTransitionEvent` | `check(==nullptr)` 禁止嵌套；转换条件评估期间提供 TransitionEvent 数据源 |
| `FAllowDirectTransitionsScope` | `bAllowDirectTransitions = true` | 仅 `TriggerTransitions` 作用域 |
| `FNodeInstanceDataScope` | `CurrentNode`/`CurrentNodeIndex`/`CurrentNodeDataHandle`/`CurrentNodeInstanceData` | 每个节点回调前建立，`GetInstanceData(Node)` 依赖它校验 |
| `FCleanUpOnExit`（`SelectStateInternal` 局部） | 选择失败弹出 state/frame | 递归选择防泄漏 |

另有两个 `TGuardValue`：`CurrentlyProcessedTemporaryStorage`（选择期间指向 `FSelectStateResult`，让事件/临时数据可寻址）、`bAllowedToScheduleNextTick`（Start/Tick/Stop 期间 false，见 §2.2/§3.1/§8）。

## 7. 重入防护（CurrentPhase）

- `FStateTreeExecutionState::CurrentPhase`（`EStateTreeUpdatePhase`，Public\StateTreeExecutionTypes.h L25-48，共 Unset+20 值）由 `SetUpdatePhaseInExecutionState` 维护（cpp L1441-1459）。
- **粗粒度真相**：写相位的调用点只有 4 处——StartTree（cpp L1563）、StopTree（cpp L1718）、TickStateTree（cpp L1785）、Unset（cpp L1659/L1796）；枚举其余值（EnterStates/ExitStates/TickingTasks/EvaluateUtility 等）**只作为 `UE_STATETREE_DEBUG_*` 的 Trace/调试相位标签，不参与重入判定**。

| 入口 | 相位内重入行为 | 证据 |
|---|---|---|
| `Start` / `TickPrelude` | `ensureMsgf(CurrentPhase==Unset)` 失败 → 返回 Failed | cpp L1480 / L1778 |
| `Stop` | 相位 != Unset → **延迟**：`Exec.RequestedStop = CompletionStatus; return Running`，由 Start 尾部/TickPostlude 补做 | cpp L1707-1715 + L1664-1670 + L1801-1807 |
| `ForceTransition`（Internal） | 相位 != Unset → 直接失败 "Can't force a transition while %s" | cpp L3051-3056 |
| `SetCollectExternalDataCallback` | `ensure(Unset)` | cpp L1188 |

## 8. Stop 流程与延迟停止

`EStateTreeRunStatus FStateTreeExecutionContext::Stop(EStateTreeRunStatus CompletionStatus = Stopped)`——cpp L1675-1752：

1. `IsValid()` 与 `CollectActiveExternalData()` 失败 → Failed。
2. 归一化：`CompletionStatus` 为 Unset/Running → Stopped（L1699-1703）。
3. **延迟停止**：相位 != Unset（Start/Tick/Stop 递归中）→ 只置 `Exec.RequestedStop` 并返回 Running（L1707-1715）。
4. `SetUpdatePhase(StopTree)`；树仍 Running → 用空选择结果 `ExitState(EmptySelectionResult, Transition{TargetState=FromCompletionStatus(CompletionStatus), CurrentRunStatus=CompletionStatus})`，随后 `ActiveFrames.Reset()`、`Result = CompletionStatus`（L1718-1736）。
5. `Exec.TreeRunStatus = CompletionStatus`；`InstanceData.Reset()`（销毁 Exec）；`bActiveExternalDataCollected = false`（L1738-1749）。

行为契约（12-tests.md §2.1）：

- **幂等**：树已自然 Succeeded 后再 Stop → 返回值保持 Succeeded（不产生新退出上报）。
- 外部 `Stop(Stopped)` → 任务 ExitState 收 `Transition.CurrentRunStatus == Stopped`。
- 任务在 EnterStates/TickStateTree/ExitStates 任一相位内调 `Context.Stop()` 都推迟到当前阶段结束后生效（`FStateTreeTest_DeferredStop_*` ×6）。

## 9. 并行子树（FStateTreeRunParallelStateTreeTask）

文件：Private\Tasks\StateTreeRunParallelStateTreeTask.cpp（任务）+ `FStateTreeRunParallelStateTreeExecutionExtension`（同头文件）。

| 回调 | 行为 | 证据 |
|---|---|---|
| `EnterState` | 校验引用与递归（活动帧含同树或当前处理树即失败 "Trying to start a new parallel tree from the same tree"）→ 从父 Context 复制构造子树 `FStateTreeExecutionContext` → `Start(FStartParameters{ InitialGlobalParameters=FStateTreeReference::GetGlobalParameters(), ExecutionExtension=并行扩展(持 WeakExecutionContext), SharedEventQueue=主树共享队列 })` → `Context.AddScheduledTickRequest(子树 GetNextScheduledTick())` | L47-103 |
| `Tick` | 可选 `bShouldCopyParametersOnTick` 刷新参数 → **`ParallelTreeContext.TickUpdateTasks(DeltaTime)`**（分片 API）→ `UpdateScheduledTickRequest` | L105-127 |
| `TriggerTransitions` | `FEventsPendingForNextTransitionProcessingScope` 保事件活到主树下一转换阶段 → **`ParallelTreeContext.TickTriggerTransitions()`** → 运行状态变化即 `Context.FinishTask(Succeeded/Failed)` | L129-161 |
| `ExitState` | 移除调度请求 → 可选参数刷新 → `ParallelTreeContext.Stop()` | L163-192 |

- 事件语义：并行树与主树**共享同一事件队列**（`SharedEventQueue` 参数）；`EventHandlingPriority` 决定同帧同事件的先处理方（High → 并行树先，主树错失该事件）——12-tests.md §2.8 `ParallelTreeSendEvents`/`ParallelEventPriority*`。
- 递归检测不完美：互相链接的并行树无法检出（源码注释 L64）；全局任务形式自引用使 Start 直接 Failed（12-tests §2.8 `RecursiveParallelTask`）。
- 调度请求与 ScheduledTick 优先级链 → [events-async.md](events-async.md)。

## 10. 执行相关 CVar 开关

定义于 Private\StateTreeExecutionContext.cpp L36-86（调试资产兼容性时优先怀疑）：

| CVar | 默认 | 语义 |
|---|---|---|
| `StateTree.TickGlobalNodesFollowingTreeHierarchy` | true | false = 5.5 兼容行为（全局节点与状态任务分两段 Tick，§3.3 路径 4） |
| `StateTree.GlobalTasksCompleteOwningFrame` | true | false = 5.5 兼容行为（任一 frame 全局任务完成即停整树） |
| `StateTree.CopyBoundPropertiesOnNonTickedTask` | false | 非 Tick 任务也做绑定拷贝 |
| `StateTree.SetDeprecatedTransitionResultProperties` | false | 回填已弃用 `NextActiveFrames/NextActiveFrameEvents` 兼容字段 |
| `StateTree.TargetStateRequiresTheSameEventForStateSelectionAsTheRequestedTransition` | false | 目标状态选择是否要求与转换相同事件（历史行为版本未证实） |
| `StateTree.CaptureStateEventPayloadForSustainedState` | true | Sustained 态是否捕获事件 payload |

## 11. 执行层弃用 API

| API | 弃用版本 | 替代品 |
|---|---|---|
| `FStateTreeExecutionContext::Start(const FInstancedPropertyBag*, int32 RandomSeed = -1)` | 5.8 | `Start(FStartParameters)` |
| `FStartParameters::GlobalParameters` | 5.8 | `FStartParameters::InitialGlobalParameters` |
| `FStateTreeExecutionContext::SetGlobalParameters(const FInstancedPropertyBag&)` | 5.8 | `SetGlobalParameters(FConstStructView)` |
| `FStateTreeExecutionContext::FindFrame(...)` | 5.8 | `UE::StateTree::ExecutionContext::FindExecutionFrame` |
| 成员 `TriggerTransitionsFromFrameIndex` | 5.8 | `FTriggerTransitionsInternalArgs::CompletedSubtreeParentFrameIndex` |
| `FStateSelectionResult` | 5.7 | `FSelectStateResult` |
| `EnterState(FStateTreeTransitionResult&)` / `ExitState(const FStateTreeTransitionResult&)` / `UpdateInstanceData(CurrentActiveFrames, NextActiveFrames)` | 5.7 | 带 `FSelectStateResult` 参数的版本 |
| `SelectState(CurrentFrame, NextState, ...)` / `SelectStateInternal(frames 版)` | 5.7 | `FSelectStateArguments` 版 |
| `RequestTransition(CurrentFrame, NextState, Priority, [Event], [Fallback])` / `SetupNextTransition(CurrentFrame, NextState, Priority)` | 5.7 | StateID / `FTransitionArguments` 版 |
| `EvaluateUtility(...)` | 5.7 | `EvaluateUtilityWithValidation(...)` |
| `TestAllConditions(...)` | 5.7 | `TestAllConditionsWithValidation` / `TestAllConditionsOnActiveInstances` |
| `StartEvaluatorsAndGlobalTasks(FStateTreeIndex16&)` 等旧全局节点启停族 | 5.7 | 无 OutParam / 非 const 版本 |
| `MakeTransitionResult(FRecordedStateTreeTransitionResult)` | 5.7 | `ForceTransition(...)` |
| `FStateTreeExecutionExtension::ScheduleNextTick(FContextParameters)` | 5.7 | `ScheduleNextTick(FContextParameters, FNextTickArguments)` |
| `GetCurrentlyProcessedNode()` | 5.6 | `GetCurrentlyProcessedNodeInstanceData()` |
| `FinishTask(const UE::StateTree::FFinishedTask&, EStateTreeFinishTaskType)` | 5.6 | `FinishTask(const FStateTreeTaskBase&, EStateTreeFinishTaskType)` |
| `IsFinishedTaskValid` / `UpdateCompletedStateList` / `MarkStateCompleted` / `GetGlobalTasksCompletedStatesStatus` | 5.6 | `FStateTreeTasksCompletionStatus`（替代体系与被替代的 `ExecutionState` 弃用字段明细见 [instance-data.md](instance-data.md) §4「ExecutionState 弃用字段明细」表） |
| `FindAndRemoveExpiredDelayedTransitions` | 5.6 | `Exec.DelayedTransitions` 阶段 A 倒计时 + 阶段 B 到期收集（§5.4） |
| `MakeWeakTaskRef` / `MakeWeakTaskRefFromInstanceData`（`FStateTreeWeakTaskRef` 全链） | 5.6 | WeakExecutionContext + TaskIndex（[events-async.md](events-async.md)） |

证据：各 UE_DEPRECATED 标记见 Public\StateTreeExecutionContext.h / Public\StateTreeExecutionTypes.h / Public\StateTreeExecutionExtension.h 对应行（完整清单见 [version-deltas.md](version-deltas.md)）。

## 12. 开放问题

1. 【未证实】`FStartParameters::SelectStateOverrideArgs` + `UStateTree::GetStateHandleFromGameplayTag` 的引入版本：5.8 头文件无弃用标记、无版本注释，推测为 5.8 随 Start 收拢新增（需 GitHub 历史验证）。
2. 【未证实】`EStateTreeUpdatePhase` 枚举与 `CurrentPhase` 重入护栏的确切引入版本（5.6 重构期出现于本构建，无直接版本证据）。
3. 【未证实】`MaxIterations = 5`（阶段 B 重规划轮数上限）的引入版本与取值依据（源码仅注释动机）。
4. 【未证实】CVar `StateTree.TargetStateRequiresTheSameEventForStateSelectionAsTheRequestedTransition` 对应的历史行为属于哪个版本之前。
5. 【未证实】ExitState 中 "keep the wrong UE5.6 behavior" 注释（cpp L4061）所指 5.6 缺陷的来龙去脉（当前为刻意保留）。
6. 【未证实】`FStateTreeRunParallelStateTreeTask` 的分片驱动模式（Tick→TickUpdateTasks、TriggerTransitions→TickTriggerTransitions）是否自该任务引入即如此（本构建证实存在，引入版本未核）。
7. 【未证实/风险】Considerations 评估与两个 Utility 选择器无专门自动化测试（唯一触达点为启动覆盖测试）；随机种子可重现性亦无测试。
8. 【推断/风险】评估作用域实例内存来自栈上 alloca，需求大小编译期决定且无栈余量保护，极端多条件状态放大栈占用（源自 [instance-data.md](instance-data.md) 同项）。
