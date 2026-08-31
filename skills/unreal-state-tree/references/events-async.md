# StateTree 事件、委托与异步通知全集（UE 5.8）

> 版本基线：UE 5.8.0 (Release-5.8, CL 55116800) · 版本标记约定：**[UE 5.x+]**=该版本新增，**[仅 <5.x]**=已移除/旧行为，**[5.8 变更]**=本版变更；现行 API 判定标准=声明无 UE_DEPRECATED 标记。

## TL;DR

- **两套并行唤醒/通知通道**：事件（`FStateTreeEventQueue`，Tag 广播、队列延迟消费）与委托（`FStateTreeDelegateDispatcher`/`FStateTreeDelegateListener`，编辑器绑定、`BroadcastDelegate` 同步回调）。
- 事件队列上限 `MaxActiveEvents=64`，满时**丢弃新事件**并打 Error 日志（StateTreeEvents.cpp L45-49）；事件只在一次"转换处理阶段"（`TriggerTransitions`）内存活，阶段末 `ClearEventsForCurrentTransitionProcessingPhase` 清除非 pending 事件。
- `SendEvent` 仅入队 + `ScheduleNextTick(ETickReason::Event)` 唤醒宿主；消费只发生在 `TriggerTransitions` 的 OnEvent 匹配（`DoesEventMatchDesc`）与任务 `ForEachEvent`；`bConsumeEventOnSelect` 默认 true。
- **异步模型**：`MakeWeakExecutionContext()` 抓 FrameID/StateID/NodeIndex 弱引用 [UE 5.6+]，回调线程 `MakeStrongExecutionContext()` 升级为栈上强引用并对 `FStateTreeInstanceStorage` 加 MRSW 读/写访问；`FinishTask`/`RequestTransition`/`BroadcastDelegate` 在 tick 外调用时**缓冲到下帧**。
- `GetNextScheduledTick()` 按固定优先级合并全部唤醒源（Forced/任务/请求/转换请求/事件/完成态/延迟转换/自定义率），产出 Sleep/EveryFrame/NextFrame/自定义间隔；经 `FStateTreeExecutionExtension::ScheduleNextTick` 唤醒宿主。
- **通知全集**：§6 主表收录 **58 个通知点**（树内委托 4 + 事件 5 + 节点生命周期 9 + 宿主 5 + 编辑器/Trace 12 + 模块内部 7 + 调试 16）。
- **多线程真相**：事件/委托/异步相关自动化测试全部为单线程 InstantTest，真实多线程无自动化覆盖——"线程安全用户负责"仅由头文件注释 + MRSW 探测器背书（§9）。

## 目录

1. 事件队列全语义（FStateTreeEventQueue）
2. 异步上下文：Weak → Strong 与线程约定
3. 调度：GetNextScheduledTick 优先级链与请求合并
4. FStateTreeExecutionExtension：宿主扩展点（四钩子）
5. FTaskCompletionDispatcher：任务完成分发
6. 通知点全集主表（58 个）
7. 分类语义补充
8. 弃用 API 清单
9. 测试佐证与多线程盲区
10. 注意事项与坑
11. 开放问题

## 0. 证据与引用约定

- 源码根：`E:\UnrealEngine\UE_5.8\Engine\Plugins\Runtime\StateTree\Source\StateTreeModule`，下文引用缩写为 `文件名 L行号`；GameplayStateTreeModule 位于 `E:\UnrealEngine\UE_5.8\Engine\Plugins\Runtime\GameplayStateTree\Source\GameplayStateTreeModule`。
- 证据标注：【源码】= 本机 5.8 源码直接证实；【推断】= 由证据合理推断。
- 分工边界：Tick 阶段骨架（Start/Tick/Stop 主流程、状态选择、转换应用）→ runtime-execution.md；宿主如何响应调度 → integrations.md；组件层委托详情 → gameplay-state-tree.md（本文档 §6 主表是通知全集的索引）。

## 1. 事件队列全语义（FStateTreeEventQueue）

### 1.1 数据结构

| 类型 | 要点 | 语义 |
|---|---|---|
| `FStateTreeEvent` | USTRUCT：`Tag`(FGameplayTag, meta Categories="StateTreeEvent") + `Payload`(FInstancedStruct) + `Origin`(FName)；私有位 `bIsPendingForNextTransitionProcessing`（friend 仅队列） | 事件本体【StateTreeEvents.h L48-95】 |
| `FStateTreeSharedEvent` | USTRUCT 包 `TSharedPtr<FStateTreeEvent>`；`AddStructReferencedObjects` 保证 Payload 内 UObject 引用被 GC 收集【StateTreeEvents.cpp L24-30】 | 队列元素与跨层引用形态（Trace/Debugger 引用同一事件对象） |
| `FStateTreeEventQueue` | 定容缓冲，`MaxActiveEvents = 64`（static constexpr）【StateTreeEvents.h L181】；持有于 `FStateTreeInstanceStorage`（TSharedRef，`bIsOwningEventQueue`）【StateTreeInstanceData.h L414-415/L440】 | 事件队列；`SendEvent/ConsumeEvent/ClearEventsForCurrentTransitionProcessingPhase/ForEachEvent/GetEventsView/GetMutableEventsView/Reset/HasEvents` |
| `EStateTreeLoopEvents` | `Next / Break / Consume` (uint8)【StateTreeEvents.h L234-249】 | `ForEachEvent` 迭代流控 |
| `UE::StateTree::Event::FEventsPendingForNextTransitionProcessingScope` | RAII(queue*)，作用域内新入队事件标记为"留给下一个转换处理阶段" | 跨阶段存活的开关【StateTreeEvents.cpp L13-22】 |

### 1.2 事件生命周期：入队 → 唤醒 → 消费 → 阶段末清除

1. **入队**（`FStateTreeEventQueue::SendEvent(Owner, Tag, Payload={}, Origin={}) → bool`，【StateTreeEvents.cpp L37-58】）：
   - Tag 与 Payload **同时无效** → 拒绝 + Error 日志（UE_VLOG + UE_LOG），返回 false。
   - `SharedEvents.Num() >= MaxActiveEvents(64)` → **丢弃本次（新）事件** + Error `"Too many events send on '%s'. Dropping event %s"`，返回 false（L45-49）。溢出策略=拒新留旧，无截断旧事件、无降级计数。
   - 成功 → Emplace；若队列处于 pending scope，则给该事件打 `bIsPendingForNextTransitionProcessing` 标记。
2. **唤醒**：`FStateTreeMinimalExecutionContext::SendEvent` 只做入队 + `ScheduleNextTick(ETickReason::Event)` 通知宿主"下帧该 Tick"【StateTreeExecutionContext.cpp L918-938】；Tick 执行期间调用则由 `bAllowedToScheduleNextTick=false` 抑制唤醒。
3. **消费**（只发生在下一次 `TriggerTransitions`，StateTreeExecutionContext.cpp L5735+）：
   - OnEvent 转换：`GetTriggerTransitionEvent` 在队列全量视图（`GetEventsToProcessView()`）按 `RequiredEvent.DoesEventMatchDesc(*Event)`（Tag 匹配 + Payload 结构 IsChildOf，StateTreeTypes.h L640-649）筛候选；每个候选事件套 `FCurrentlyProcessedTransitionEventScope` 后测转换条件【L6048-6058】。
   - 任务侧：`Context.ForEachEvent(lambda)` 自行迭代/消费（返回 `EStateTreeLoopEvents`）。
   - 状态选择成功且 `bConsumeEventOnSelect=true`（默认，StateTreeTypes.h L746）→ `ConsumeEvent` 移除【StateTreeExecutionContext.cpp L6030-6033】。
   - 带延迟的转换：触发事件捕获进 `FStateTreeTransitionDelayedState::CapturedEvent`，延迟到期后继续使用【L6013-6040】。
4. **阶段末清除**（StateTreeExecutionContext.cpp L5767-5779，ON_SCOPE_EXIT）：非子树完成路径上，若本实例**拥有**事件队列（`IsOwningEventQueue()`）→ `ClearEventsForCurrentTransitionProcessingPhase()`：删除所有未标记 pending 的事件并清标记【StateTreeEvents.cpp L69-81】。头文件注释明说"事件只在一次转换处理阶段内有效"（StateTreeEvents.h L16-20）。`MaxIterations=5` 的内层循环允许 EnterState 失败后用**同一批事件**重新选态【StateTreeExecutionContext.cpp L1979】。

### 1.3 跨阶段存活与共享队列

- **跨阶段存活**：`FEventsPendingForNextTransitionProcessingScope`（RAII）把队列 `bNewlyAddedEventsShouldBePendingForNextTransitionProcessing` 置真——此后新入队事件都被标记为"留给下一个转换处理阶段"，本轮清除跳过、下一轮清除时标记清零并删除。由 TriggerTransitions 与并行树内部使用；官方用例：`FStateTreeRunParallelStateTreeTask` 在自己的队列上开 scope 再处理事件【StateTreeRunParallelStateTreeTask.cpp L150】。
- **共享队列**：`FStateTreeInstanceStorage` 默认拥有自己的队列；`SetSharedEventQueue` 把队列共享出去并把所有权置 false（移动语义会把所有权还给接收方）【StateTreeInstanceData.cpp L564-579】。**只有所有者**在阶段末清队列，且**只有所有者**会在 `GetNextScheduledTick` 里因"有事件"返回 `NextFrame(Event)`【StateTreeExecutionContext.cpp L541-545】——共享者不会因共享队列里的事件被唤醒，也不会清它；共享队列的唤醒责任落在所有者的 tick 节奏上。

## 2. 异步上下文：Weak → Strong 与线程约定

### 2.1 两级上下文（StateTreeAsyncExecutionContext.h）

| | `FStateTreeWeakExecutionContext` | `TStateTreeStrongExecutionContext<bWithWriteAccess>` |
|---|---|---|
| 定位 | 可拷贝、可存放、供以后用；不保活任何对象 | 栈上临时强引用，即用即弃（头注释 "It should only be allocated on the stack"，L47） |
| 成员 | `TWeakObjectPtr<UObject> Owner`、`TWeakObjectPtr<const UStateTree> StateTree`、`TWeakPtr<FStateTreeInstanceStorage> Storage`、`TWeakPtr<ITemporaryStorage> TemporaryStorage` + 定位三元组 `FActiveFrameID FrameID / FActiveStateID StateID / FStateTreeIndex16 NodeIndex` [UE 5.6+] | 构造时 `TStrongObjectPtr` 钉 Owner 与 StateTree（防 GC）、`TSharedPtr` 接管存储，按模板参数对存储加 **MRSW 读或写访问**（`AcquireReadAccess/AcquireWriteAccess`）；析构对称释放【cpp L18-58】 |
| 身份体系 | FrameID/StateID/NodeIndex 取代 5.6 前的 `FStateTreeWeakTaskRef`（全链弃用，StateTreeNodeRef.h） | 别名 `FStateTreeStrongExecutionContext=<true>`、`FStateTreeStrongReadOnlyExecutionContext=<false>`（L244-245） |
| 有效性 | pinned 有效 且（ID 无效 或 帧/状态仍活跃）；在执行主循环之外创建时 ID 全部无效，仍可用于 Unbind 等 | `GetActivePathInfo()`：帧仍在 `Exec.ActiveFrames` 或临时存储、`NodeIndex <= Frame->ActiveNodeIndex`、StateID 可反查 StateHandle；状态退出/树停止/GC 后即失效 |
| 写操作 | 全部是 `MakeStrongExecutionContext()` 的一行转发【cpp L513-567】 | 全部 `requires bWithWriteAccess`——只读变体在编译期拒绝写；`GetInstanceDataPtr<T>()` 仅 lvalue 限定（rvalue 重载 `= delete`，防临时上下文丢失访问追踪） |

### 2.2 操作生效时机（半同步语义，StateTreeAsyncExecutionContext.cpp L60-273）

| 操作 | tick 内调用 | tick 外调用 |
|---|---|---|
| `SendEvent(Tag, Payload={}, Origin={}) → bool` | 入队（复用 `FStateTreeMinimalExecutionContext::SendEvent`）+ 唤醒被抑制 | 入队 + `ScheduleNextTick(Event)` |
| `RequestTransition(TargetState, Priority=Normal, Fallback=None) → bool` | 阶段内（`FAllowDirectTransitionsScope` 开启时）立即尝试激活 | `AddTransitionRequest` 缓冲（上限 32）+ `ScheduleNextTick(TransitionRequest)`，下次转换处理阶段消费 |
| `BroadcastDelegate(Dispatcher) → bool` | 监听回调**立即同步执行**；有等待该 dispatcher 的 OnDelegate 转换则标记广播 + 唤醒 | 同左（标记的广播在下次 `TriggerTransitions` 被消费） |
| `FinishTask(EStateTreeFinishTaskType{Succeeded, Failed}) → bool` | 状态立即完成 | 置任务完成位；全部任务完成 → `bHasPendingCompletedState=true` + `ScheduleNextTick(CompletedState)`，下次 tick 处理 |
| `UpdateScheduledTickRequest(Handle, ScheduledTick) → bool` | 更新请求 + 唤醒 | 同左 |
| `BindDelegate(Listener, FSimpleDelegate) / UnbindDelegate(Listener) → bool` | 注册/注销监听（记录 FrameID/StateID/NodeIndex；重复绑先解绑；广播进行中安全） | 同左 |
| `CopyInputBindings() / CopyOutputBindings() → bool` | — | 异步侧复制输入/输出属性绑定（属性函数/上下文外部源不可用则 false） |

### 2.3 线程约定（三条硬规则）

1. **运行时 API 在调用者线程执行**：引擎不提供内部线程跳跃；组件宿主在 GameThread tick，MassAI 等可在工作线程驱动。
2. **线程安全用户负责**：头注释 "You are responsible for making it thread-safe if needed"（StateTreeAsyncExecutionContext.h L48/L249）；存储层 MRSW 访问探测器 `UE_MT_DECLARE_MRSW_RECURSIVE_ACCESS_DETECTOR`（StateTreeInstanceData.h L432-437，注释"多读或单写、支持递归"）是调试断言而非互斥锁——探测失败即断言，不防竞争。
3. **写操作缓冲至下帧 + 唤醒宿主**：见 §2.2；异步线程触发的 `ScheduleNextTick` 由宿主自行保证落回 GameThread（组件实现只动 Tick 开关，详见 gameplay-state-tree.md §2.4）。

另：`TStrongObjectPtr` 跨线程创建需遵守引擎 GC 约定（引擎未在此封装保护）【推断】；Weak 上下文默认"将来能写"，最小权限应传 `MakeStrongReadOnlyExecutionContext()`。

## 3. 调度：GetNextScheduledTick 优先级链与请求合并

### 3.1 FStateTreeScheduledTick：单 float 编码四种意图

| 工厂 | `NextDeltaTime` | 含义 |
|---|---|---|
| `MakeSleep()` | `>= UE_FLOAT_NON_FRACTIONAL` | 休眠 |
| `MakeEveryFrames(Reason)` | `0.0f` | 每帧 |
| `MakeNextFrame(Reason)` | `UE_KINDA_SMALL_NUMBER` | 下一帧一次 |
| `MakeCustomTickRate(DeltaTime, Reason)` | `>0`（`<=0` 回落 EveryFrames） | 自定义间隔 |

带 `ETickReason Reason` 透传给宿主。`UE::StateTree::ETickReason` [UE 5.7+]：`None, ScheduledTickRequest, Forced, StateCustomTickRate, TaskTicking, TransitionTicking, TransitionRequest, Event, CompletedState, DelayedTransition, Delegate`【StateTreeExecutionTypes.h L783-808】。

### 3.2 GetNextScheduledTick 固定优先级链【StateTreeExecutionContext.cpp L409-570】

1. 上下文无效或 `TreeRunStatus != Running` → Sleep。
2. 任一活动帧资产 `!IsScheduledTickAllowed()`（Schema 默认 false，编译期缓存进 `UStateTree::bScheduledTickAllowed`）→ `EveryFrames(Forced)`——**Schema 不支持调度就强制每帧**。
3. 扫描活动帧：全局任务要 tick（`DoesRequestTickGlobalTasks(bHasEvents)`）→ `EveryFrames`；活动状态（互斥分支，非并列——源码为 `else if (!CustomTickRate.IsSet())`）：`bHasCustomTickRate` → 记录最小自定义间隔候选；**否则**（且尚无任何候选）`DoesRequestTickTasks(bHasEvents)` → `EveryFrames(TaskTicking)`；再否则 `ShouldTickTransitions(bHasEvents, bHasBroadcastedDelegates)` → `EveryFrames(TransitionTicking)`——任一状态设了自定义 tick rate 即压制任务/转换的 EveryFrames 判定（源码注释 "If one state has a custom tick rate, then it overrides the tick rate for all states."）。
4. 自定义间隔候选 `<=0` → `EveryFrames`。
5. `ScheduledTickRequests` 缓存：EveryFrames/NextFrame 直接返回；自定义间隔并入 min。
6. 有缓冲的 `TransitionRequests` → `NextFrame(TransitionRequest)`。
7. 有事件且**本实例拥有队列** → `NextFrame(Event)`（L541-545）。
8. `bHasPendingCompletedState` → `NextFrame(CompletedState)`（覆盖只调 TickTasks 不调 TickTransitions 的宿主）。
9. `DelayedTransitions` → 取最小 `TimeLeft` 候选。
10. 有自定义间隔候选 → `MakeCustomTickRate(min, Reason)`；否则 **Sleep**。

### 3.3 请求合并、句柄与唤醒条件

- 请求列表：`FStateTreeExecutionState::ScheduledTickRequests`（`FScheduledTickRequest{FScheduledTickHandle Handle, FStateTreeScheduledTick}` 数组 + `CachedScheduledTickRequest` 派生缓存）；Add/Update/Remove（`RemoveAtSwap`）任何变更即重算缓存【StateTreeExecutionTypes.cpp L104-133】。
- **合并规则**（`GetBestRequest`）：有 `EveryFrames` 请求 → 直接用；否则有 `NextFrame` → 用之；否则取全部自定义间隔的 **min**（多个任务各要 1FPS/2FPS 时全树按 1FPS）。
- `UE::StateTree::FScheduledTickHandle::GenerateNewHandle()` 用 `static std::atomic<uint32>` 自增、跳过 0、回绕保护（cpp L267-284）——句柄生成线程安全。
- 任务侧入口：`Context.AddScheduledTickRequest(...) / UpdateScheduledTickRequest(...) / RemoveScheduledTickRequest(...)`（仅 Schema 允许调度时生效）；参考 `FStateTreeDelayTask`：EnterState 注册、Tick 更新、ExitState 务必移除（否则宿主按残留请求继续被唤醒）。
- **唤醒条件**：完整/最小上下文侧仅当 `bAllowedToScheduleNextTick`（Tick/TickUpdateTasks/TickTriggerTransitions/Start/Stop 执行期间被 `TGuardValue` 压成 false——主循环内不打扰宿主）且 `IsScheduledTickAllowed()`，才调 `ExecutionExtension->ScheduleNextTick(FContextParameters, FNextTickArguments(Reason))`【StateTreeExecutionContext.cpp L945-954、L1515/L1696/L1819/L1840/L1860】。
- 宿主如何按 `FStateTreeScheduledTick` 驱动自己的 Tick（组件 `ScheduleTickFrame`：休眠/每帧/间隔改写与 CVar 闸门）→ 详见 gameplay-state-tree.md（§2.4）；Tick 阶段骨架（Prelude→TriggerTransitions→Postlude）→ 详见 runtime-execution.md。

## 4. FStateTreeExecutionExtension：宿主扩展点（四钩子）

USTRUCT 多态基类【StateTreeExecutionExtension.h L22-81】，Start 时经 `FStartParameters.ExecutionExtension`（TInstancedStruct）注入，存于 `Exec.ExecutionExtension`。`FContextParameters{UObject& Owner, const UStateTree& StateTree, FStateTreeInstanceStorage& InstanceData}`。

| 钩子 | 签名 | 触发时机 |
|---|---|---|
| `GetInstanceDescription` | `(const FContextParameters&) const → FString`（默认 `Owner.GetName()`） | STATETREE_LOG / STATETREE_CLOG 组日志前缀时 |
| `ScheduleNextTick` [UE 5.7+] | `(const FContextParameters&, const FNextTickArguments{ETickReason Reason})`；旧单参签名 `UE_DEPRECATED(5.7)` 且 **final**（强制子类改实现） | 执行上下文/Weak 上下文请求"从调度休眠中唤醒"时（§3.2 全部唤醒源 + §2.2 缓冲操作） |
| `OnLinkedStateTreeOverridesSet` | `(const FContextParameters&, const FStateTreeReferenceOverrides&)` | Linked 树 Overrides 设置到执行上下文时 |
| `OnBeginApplyTransition` | `(const FContextParameters&, const FStateTreeTransitionResult&)` | 执行上下文应用转换前 |

注意：
- 不注入扩展（或 Schema `IsScheduledTickAllowed()=false`）时 `ScheduleNextTick` 全部静默无效——**宿主必须自行轮询 `GetNextScheduledTick()`**。
- `FContextParameters` 携带 `FStateTreeInstanceStorage&` 裸引用——异步线程触发的 `ScheduleNextTick` 里不要长持该引用。
- 参考实现：`FStateTreeComponentExecutionExtension`（GameplayStateTreeModule）、`FStateTreeRunParallelStateTreeExecutionExtension`（并行子树把父树唤醒转发给子树）。

## 5. FTaskCompletionDispatcher：任务完成分发

- 结构：`FTaskCompletionDispatcher{FStateTreeDelegateDispatcher Dispatcher, FStateTreeIndex16 TaskNodeIndex, ETaskCompletionCondition Condition}`（StateTreeDelegate.h）；编译进 `UStateTree::TaskCompletionDispatchers`，每"生产者任务 × 完成条件"组合生成条目，GUID 编译确定性（测试 TaskCompletionDispatcher_Compilation / DeterministicGUID）。
- 条件：`UE::StateTree::ETaskCompletionCondition{ Succeeds, Fails, Completes }`；Fails/Completes 兼容匹配 Stopped（外部 Stop 也算失败/完成）。
- 触发链路：`FinishTask(Succeeded/Failed)` 使任务完成状态**实际变化**且节点有 dispatcher → 按条件筛选后逐个 `BroadcastDelegate` → 监听回调同步执行 + 标记广播 + 唤醒（§6 行 3/行 4）。消费者可在回调里继续 `FinishTask`（测试 TaskCompletionDispatcher_ExecutionOnCompletion：当帧触发、不跨帧泄漏）。
- 注意：完成状态未变化（如对已完成任务重复 `FinishTask`）不会再次广播。

## 6. 通知点全集主表（58 个）

统一索引：API / 类别 / 触发时机 / 参数 / 线程。分类语义细节见 §7；组件专属委托的完整展开见 gameplay-state-tree.md（本文档行 23 为索引条目）。

| # | 通知点（API） | 类别 | 触发时机 | 参数 / 形态 | 线程 |
|---|---|---|---|---|---|
| 1 | 监听回调（`BindDelegate(Listener, FSimpleDelegate)` 注册） | 树内委托 | `BroadcastDelegate(Dispatcher)` 被调用时对每个匹配且仍活跃的监听器同步 `ExecuteIfBound`【StateTreeExecutionTypes.cpp L353-394】 | `FSimpleDelegate`（无参）；监听器登记 FrameID/StateID/OwningNodeIndex | 调用者线程 |
| 2 | OnDelegate 转换（`EStateTreeTransitionTrigger::OnDelegate`） | 树内委托 | 广播被 `MarkDelegateAsBroadcasted` 标记（存在等待该 dispatcher 的转换才标记，StateTreeExecutionContext.cpp L299-329）后，下次 `TriggerTransitions` 以哑事件迭代【L197-204】 | `RequiredDelegateDispatcher`（FCompactStateTreeState） | 调用者线程 |
| 3 | 任务完成 dispatcher 广播（`FTaskCompletionDispatcher`） | 树内委托 | `FinishTask` 使任务完成状态实际变化且节点有 dispatcher：按 `ETaskCompletionCondition` 筛选后逐个 `BroadcastDelegate`【StateTreeExecutionContext.cpp L2286-2304；异步路径 StateTreeAsyncExecutionContext.cpp L198-215】 | `FTaskCompletionDispatcher{Dispatcher, TaskNodeIndex, Condition}` | 调用者线程 |
| 4 | 完成状态处理（`StateCompleted` / `bHasPendingCompletedState`） | 树内委托 | 全部任务完成后：同步路径立即 `StateCompleted()`（StateTreeExecutionContext.cpp L1906-1908）；异步路径置 pending + `ScheduleNextTick(CompletedState)` 下次 tick 处理 | `FStateTreeTasksCompletionStatus`（StateTreeTasksStatus.h） | 调用者线程 |
| 5 | `FStateTreeEventQueue::SendEvent` 入队 | 事件 | 入队成功即返回 true；消费在下次 `TriggerTransitions`【StateTreeEvents.cpp L37-58】 | `Tag` + `Payload(FInstancedStruct)` + `Origin(FName)`；Owner 仅日志 | 调用者线程（队列无锁） |
| 6 | OnEvent 转换（`EStateTreeTransitionTrigger::OnEvent`） | 事件 | 转换处理阶段在队列全量视图按 `DoesEventMatchDesc`（Tag + Payload 结构 IsChildOf）筛候选【StateTreeExecutionContext.cpp L170-209；StateTreeTypes.h L640-649】 | `FCompactEventDesc RequiredEvent` | 调用者线程 |
| 7 | 任务侧 `ForEachEvent` | 事件 | 任务 `TriggerTransitions` 回调内自行迭代/消费（`Next/Break/Consume` 流控）【StateTreeEvents.h L234-249】 | `FStateTreeSharedEvent` → `EStateTreeLoopEvents` | 调用者线程 |
| 8 | `bConsumeEventOnSelect` 选中即消费 | 事件 | 状态选择成功且开关打开（默认 true，StateTreeTypes.h L746）时 `ConsumeEvent` 移除【StateTreeExecutionContext.cpp L6030-6033】 | — | 调用者线程 |
| 9 | 延迟转换捕获事件 `CapturedEvent` | 事件 | 带延迟的转换把触发事件存入 `FStateTreeTransitionDelayedState::CapturedEvent`，到期后继续使用并按需消费【StateTreeExecutionContext.cpp L6013-6040】 | `FStateTreeSharedEvent CapturedEvent` | 调用者线程 |
| 10 | `FStateTreeTaskBase::EnterState` | 生命周期 | 状态进入（EnterStates 阶段）；绑定委托的常规时机 | `(FStateTreeExecutionContext&, const FStateTreeTransitionResult&) → EStateTreeRunStatus` | 调用者线程 |
| 11 | `FStateTreeTaskBase::Tick` | 生命周期 | 每帧任务 tick（`bShouldCallTick` / `bShouldCallTickOnlyOnEvents` 控制） | `(Context, DeltaTime) → EStateTreeRunStatus` | 调用者线程 |
| 12 | `FStateTreeTaskBase::ExitState` | 生命周期 | 状态退出（ExitStates 阶段），子→父→全局逆序 | `(Context, const FStateTreeTransitionResult&)` | 调用者线程 |
| 13 | `FStateTreeTaskBase::StateCompleted` | 生命周期 | 状态完成后、新状态选择前，**反序**调用；条件转换改变状态时不调用（BP 基类注释） | `(Context, EStateTreeRunStatus CompletionStatus, const FStateTreeActiveStates&)` | 调用者线程 |
| 14 | `FStateTreeTaskBase::TriggerTransitions` | 生命周期 | 每次转换处理阶段回调任务；任务侧消费即行 7 的 `ForEachEvent`（同一机制的两个观测面） | `(Context, DeltaTime)` | 调用者线程 |
| 15 | BP `UStateTreeTaskBlueprintBase::ReceiveLatentEnterState` | 生命周期 | 对应 EnterState；任务状态改由 `FinishTask` 节点控制 | `const FStateTreeTransitionResult& Transition` | 组件宿主=GT |
| 16 | BP `ReceiveExitState` | 生命周期 | 对应 ExitState | `const FStateTreeTransitionResult& Transition` | GT |
| 17 | BP `ReceiveStateCompleted` | 生命周期 | 对应 StateCompleted（反序） | `(EStateTreeRunStatus CompletionStatus, const FStateTreeActiveStates CompletedActiveStates)` | GT |
| 18 | BP `ReceiveLatentTick` | 生命周期 | 对应 Tick | `const float DeltaTime` | GT |
| 19 | `FStateTreeExecutionExtension::ScheduleNextTick` [UE 5.7+] | 宿主 | 执行上下文/Weak 上下文请求"从调度休眠唤醒"（§3.2 全部唤醒源）；主循环执行期间被抑制 | `(const FContextParameters&, const FNextTickArguments{ETickReason})` | 触发者线程（异步上下文可任意线程） |
| 20 | `FStateTreeExecutionExtension::OnBeginApplyTransition` | 宿主 | 执行上下文应用转换前 | `(const FContextParameters&, const FStateTreeTransitionResult&)` | 调用者线程 |
| 21 | `FStateTreeExecutionExtension::OnLinkedStateTreeOverridesSet` | 宿主 | Linked 树 Overrides 设置到执行上下文时 | `(const FContextParameters&, const FStateTreeReferenceOverrides&)` | 调用者线程 |
| 22 | `FStateTreeExecutionExtension::GetInstanceDescription` | 宿主 | STATETREE_LOG / STATETREE_CLOG 组日志前缀时 | `(const FContextParameters&) const → FString`（默认 `Owner.GetName()`） | 调用者线程 |
| 23 | `UStateTreeComponent::OnStateTreeRunStatusChanged` | 宿主 | 组件 Start / Tick 后状态变化 / Stop / Resume 后（GameplayStateTreeModule；详情 → gameplay-state-tree.md） | `EStateTreeRunStatus`（`FStateTreeRunStatusChanged` 多播） | GT |
| 24 | `UE::StateTree::Delegates::OnIdentifierChanged` | 编辑器·Trace | StateTree 内 linkable 名称变化 | `const UStateTree&` | 编辑器/GT |
| 25 | `UE::StateTree::Delegates::OnSchemaChanged` | 编辑器·Trace | EditorData 的 Schema 变化（编译成功回写 Schema **不**触发） | `const UStateTree&` | 编辑器/GT |
| 26 | `UE::StateTree::Delegates::OnParametersChanged` | 编辑器·Trace | EditorData 参数变化 | `const UStateTree&` | 编辑器/GT |
| 27 | `UE::StateTree::Delegates::OnStateParametersChanged` | 编辑器·Trace | 状态参数变化 | `(const UStateTree&, const FGuid StateID)` | 编辑器/GT |
| 28 | `UE::StateTree::Delegates::OnGlobalDataChanged` | 编辑器·Trace | 全局任务/评估器变化 | `const UStateTree&` | 编辑器/GT |
| 29 | `UE::StateTree::Delegates::OnVisualThemeChanged` | 编辑器·Trace | 主题色变化 | `const UStateTree&` | 编辑器/GT |
| 30 | `UE::StateTree::Delegates::OnBreakpointsChanged` | 编辑器·Trace | 断点变化（调试器 UI 刷新） | `const UStateTree&` | 编辑器/GT |
| 31 | `UE::StateTree::Delegates::OnPostCompile` | 编辑器·Trace | 编译完成 | `const UStateTree&` | 编辑器/GT |
| 32 | `UE::StateTree::Delegates::OnRequestCompile` | 编辑器·Trace | 请求编译；**[5.8 变更]** UE_DEPRECATED(5.8) → `UStateTreeEditingSubsystem` | 单播 `bool(UStateTree&)` | 编辑器/GT |
| 33 | `UE::StateTree::Delegates::OnRequestEditorHash` | 编辑器·Trace | 请求编辑器哈希 | 单播 `uint32(const UStateTree&)` | 编辑器/GT |
| 34 | `UE::StateTree::Delegates::OnTracingStateChanged` | 编辑器·Trace | Trace 启停（WITH_STATETREE_TRACE） | `EStateTreeTraceStatus` | 编辑器/GT |
| 35 | `UE::StateTree::Delegates::OnTraceAnalysisStateChanged` / `OnTracingTimelineScrubbed` | 编辑器·Trace | Trace 分析启停 / Rewind Debugger 时间线擦洗（WITH_STATETREE_TRACE_DEBUGGER） | `EStateTreeTraceAnalysisStatus` / `double InScrubTime` | 编辑器/GT |
| 36 | `UE::StateTree::Delegates::Private::OnStateTreeAssetLoaded` | 内部 | 资产加载（任意构建） | 单播（签名见 StateTreeDelegatesInternal.h） | 加载线程 |
| 37 | `Private::OnStateTreeEditorBindingUpdated` | 内部 | 编辑绑定更新（任意构建） | 单播（同上） | 调用者线程 |
| 38 | `Private::OnCompileIfChanged` | 内部 | `UStateTree::CompileIfChanged` 回调（WITH_EDITOR） | — | GT |
| 39 | `Private::OnStateTreeMarkedAsModified` | 内部 | `UStateTree::MarkAsModified`（WITH_EDITOR） | — | GT |
| 40 | `Private::OnRequestAssetRegistryTags` | 内部 | `GetAssetRegistryTags`（WITH_EDITOR） | — | GT |
| 41 | `Private::OnAppendToClassSchema` | 内部 | `AppendToClassSchema`（WITH_EDITOR） | — | GT |
| 42 | `Private::OnPreCookStateTreeAsset` | 内部 | 资产将要 Cook（UStateTree.cpp L417）；StateTreeEditorModule 的 CompilerManager 挂编译（WITH_EDITOR） | — | GT |
| 43 | `UE::StateTree::Debug::OnConditionEnterState_AnyThread` | 调试 | 条件节点激活 | `FNodeDelegate`：`(const FStateTreeExecutionContext&, FNodeDelegateArgs{FNodeReference, FGuid NodeId})`【StateTreeDebug.h L113/L97-101】 | StateTree 逻辑线程（任意线程） |
| 44 | `Debug::OnTestCondition_AnyThread` | 调试 | 条件求值前 | 同行 43 | 同行 43 |
| 45 | `Debug::OnConditionExitState_AnyThread` | 调试 | 条件节点失活 | 同行 43 | 同行 43 |
| 46 | `Debug::OnEvaluatorEnterTree_AnyThread` | 调试 | 评估器激活 | 同行 43 | 同行 43 |
| 47 | `Debug::OnTickEvaluator_AnyThread` | 调试 | 评估器 tick 前 | 同行 43 | 同行 43 |
| 48 | `Debug::OnEvaluatorExitTree_AnyThread` | 调试 | 评估器失活 | 同行 43 | 同行 43 |
| 49 | `Debug::OnTaskEnterState_AnyThread` | 调试 | 任务激活 | 同行 43 | 同行 43 |
| 50 | `Debug::OnTickTask_AnyThread` | 调试 | 任务 tick 前 | 同行 43 | 同行 43 |
| 51 | `Debug::OnTaskExitState_AnyThread` | 调试 | 任务失活 | 同行 43 | 同行 43 |
| 52 | `Debug::OnBeginUpdatePhase_AnyThread` | 调试 | 进入更新阶段 | `FPhaseDelegate`：`(Context, EStateTreeUpdatePhase, FStateTreeStateHandle)`【StateTreeDebug.h L114】 | 同行 43 |
| 53 | `Debug::OnEndUpdatePhase_AnyThread` | 调试 | 退出更新阶段 | 同行 52 | 同行 43 |
| 54 | `Debug::OnStateEvent_AnyThread` | 调试 | 状态动作执行（entering/exiting/selecting 等） | `FStateDelegate`：`(Context, FStateTreeStateHandle, EStateTreeTraceEventType)`【L115】 | 同行 43 |
| 55 | `Debug::OnTransitionEvent_AnyThread` | 调试 | 转换动作执行（requesting/evaluating 等） | `FTransitionDelegate`：`(Context, const FStateTreeTransitionSource&, EStateTreeTraceEventType)`【L116】 | 同行 43 |
| 56 | `Debug::OnEventSent_AnyThread` | 调试 | `SendEvent` 内触发 | `FEventSentDelegate`：`(const FStateTreeMinimalExecutionContext&, FEventSentDelegateArgs{StateTree, Tag, Payload, Origin})`【L103-111】 | 同行 43 |
| 57 | `Debug::OnEventConsumed_AnyThread` | 调试 | `ConsumeEvent` 内触发 | `FEventConsumedDelegate`：`(Context, const FStateTreeSharedEvent&)`【L112】 | 同行 43 |
| 58 | `Debug::OnStateUtilityEvaluated_AnyThread` | 调试 | 状态效用分计算 | `FStateUtilityEvaluatedDelegate`：`(Context, FStateTreeStateHandle, float Score)`【L117】 | 同行 43 |

计数核对：树内委托 4 + 事件 5 + 节点生命周期 9（行 14 `TriggerTransitions` 与行 7 任务侧消费为同一机制的两个观测面，计 1 条）+ 宿主 5 + 编辑器/Trace 12 + 模块内部 7 + 调试 16 = **58 个独立通知点**（按主表行计；行 35 含 2 个委托名 `OnTraceAnalysisStateChanged`/`OnTracingTimelineScrubbed`，按 API 名计为 59）。带明确线程注记的是调试组（任意线程）与异步上下文组（用户负责）。

## 7. 分类语义补充

### 7.1 树内委托（行 1-4）

- **同步重入**：`BroadcastDelegate` 在遍历中直接 `ExecuteIfBound`（StateTreeExecutionTypes.cpp L353-394）；回调里再调 `FinishTask`/`SendEvent`/`BroadcastDelegate` 都会重入执行上下文。
- **广播中增删安全**：广播期间 Remove 安全（墓碑 + 延迟清理，测试 Delegate_SelfRemoval 佐证）、Add 安全；但 `RemoveAll(FrameID/StateID)` 在广播中断言（StateTreeExecutionTypes.cpp L337/L347）。
- **监听器寿命绑定帧/状态**：状态退出时按 StateID/FrameID 清监听器（`CleanFrame/CleanState`，StateTreeExecutionContext.cpp L221-233）；只有全局任务监听器跨状态转换存活（测试 GlobalTaskWeakContextSurvivesTransitions）；树结束 `RemoveAllDelegateListeners`（L1649/L2007）。
- **退出阶段广播不触达**：树 `Stop()` 期间 ExitState 广播的委托不触发监听器（即使 `bRemoveOnExit=false`，测试 ListeningToDelegateOnExit×2）。
- 类型：`FStateTreeDelegateDispatcher`（发送端，私有 `FGuid ID` 编译期生成，资产内唯一不可跨资产）/ `FStateTreeDelegateListener`（接收端，编辑器绑定到 dispatcher）。Dispatcher/Listener 可分别放节点属性或实例数据（测试 ListenerDispatcherOnNode）。

### 7.2 事件（行 5-9）

- **事件驱动树通常有 1 帧延迟**：SendEvent → `ScheduleNextTick(Event)` → 下帧 Tick 的 TriggerTransitions 消费【源码+推断；宿主同帧 SendEvent 后手动 Tick 可当帧消费，帧序依赖宿主实现】。
- 同帧 SendEvent 后 `HasEventToProcess`/`GetEventsToProcessView` 立即可见（同一队列）。
- **`bConsumeEventOnSelect` 默认 true**：第一个成功选择的状态消费事件，同级/后续状态对同一事件的转换不再触发；多状态响应同一事件必须显式关闭。
- 事件匹配：`DoesEventMatchDesc` = Tag 匹配 + Payload 结构 IsChildOf（兼容子结构）。

### 7.3 节点生命周期（行 10-18）

- `StateCompleted` 在状态完成后、新状态选择前、**反序**调用（让树中更早执行的任务传播状态；条件转换改变状态时不调用——BP 基类注释）。
- EnterState 是**绑定委托的常规时机**（测试模板即在此 `Context.BindDelegate(...)`，StateTreeTestTypes.h L1344/1406/1449）。
- BP 可调用通知动作（经 `GetWeakExecutionContext()` 转发，StateTreeTaskBlueprintBase.cpp L107-130）：`FinishTask(bSucceeded=true)`、`BroadcastDelegate(Dispatcher)`、`BindDelegate(Listener, FStateTreeDynamicDelegate)`、`UnbindDelegate(Listener)`。
- BP 弃用事件 `ReceiveEnterState / ReceiveTick`（带返回值）→ 见 §8；任务状态改由 `FinishTask` 节点控制。

### 7.4 宿主（行 19-23）

- 自定义扩展步骤：继承四钩子（必须用 [UE 5.7+] 新签名）→ `FStartParameters.ExecutionExtension = TInstancedStruct<FStateTreeExecutionExtension>::Make(MoveTemp(Ext))` 注入 → 每次 Start/Tick/Stop/Pause/Resume 后轮询 `GetNextScheduledTick()` 并按结果驱动自己的 tick。
- `ScheduleNextTick` 的宿主消费（组件 `ScheduleTickFrame`：ShouldSleep 关 Tick / NextFrame 极小间隔 / 自定义 `SetComponentTickIntervalAndCooldown`）→ 详见 gameplay-state-tree.md（§2.4）。
- 组件专属委托（`OnStateTreeRunStatusChanged`、`FStateTreeComponentExecutionExtension` 等）的完整清单 → gameplay-state-tree.md；本文档行 23 为全集索引条目。

### 7.5 编辑器 / Trace 全局委托（行 24-35）

- 全部为 `UE::StateTree::Delegates` 命名空间模块级单例多播/单播（StateTreeDelegates.h/.cpp）；WITH_EDITOR 组供编辑器/GT 使用。
- 编译守卫：`OnTracingStateChanged` 需 WITH_STATETREE_TRACE；`OnTraceAnalysisStateChanged`/`OnTracingTimelineScrubbed` 需 WITH_STATETREE_TRACE_DEBUGGER。
- `OnSchemaChanged` 在编译成功回写 Schema 时**不**触发（StateTreeDelegates.h L22-26 注释）。
- `OnRequestCompile` **[5.8 变更]** 弃用 → 改用 `UStateTreeEditingSubsystem` 触发编译。

### 7.6 模块内部委托（行 36-42）

- `UE::StateTree::Delegates::Private`（StateTreeDelegatesInternal.h）：宿主插件经此挂钩资产生命周期；前两项任意构建可用，其余 WITH_EDITOR。
- **命名怪点（非缺陷）**：`OnPreCookStateTreeAsset` 的 cpp 定义写成 `FOnStateTreeAssetLoaded OnPreCookStateTreeAsset;`（StateTreeDelegates.cpp L45）——`DECLARE_DELEGATE_OneParam` 展开为同一 `TDelegate` typedef，两者是同一类型，可编译可链接；阅读源码时勿误判为两个变量【源码，已核实宏展开】。

### 7.7 调试委托（行 43-58）

- `UE::StateTree::Debug`（StateTreeDebug.h L143-253），16 个模块级 `DECLARE_TS_MULTICAST_DELEGATE`（TS=thread-safe 声明），需 WITH_STATETREE_DEBUG。
- 每个都注明 "The callback executes inside the StateTree logic" + "**The StateTree can execute on any thread**"——回调在 StateTree 逻辑线程内同步执行，可能是任意工作线程。
- 事件钩子触发点：`OnEventSent_AnyThread` 在 SendEvent 内、`OnEventConsumed_AnyThread` 在 ConsumeEvent 内。
- 参数类型定义：`FNodeDelegateArgs{FNodeReference Node, FGuid NodeId}`、`FEventSentDelegateArgs{TNotNull<const UStateTree*> StateTree, FGameplayTag Tag, FConstStructView Payload, FName Origin}`（StateTreeDebug.h L97-109）。

## 8. 弃用 API 清单

| API | 弃用版本 | 替代品 |
|---|---|---|
| `FStateTreeWeakExecutionContext::BindDelegate(const FStateTreeWeakTaskRef&, ...)` / `FinishTask(const FStateTreeWeakTaskRef&, ...)` | UE_DEPRECATED(5.6) | 去掉 TaskRef 参数的重载（StateTreeAsyncExecutionContext.cpp L534-561 直接转发） |
| `FStateTreeWeakExecutionContext::RemoveDelegateListener(Listener)` | UE_DEPRECATED(5.6) | `UnbindDelegate` |
| `FStateTreeExecutionContext::AddDelegateListener / RemoveDelegateListener` | UE_DEPRECATED(5.6) | `BindDelegate / UnbindDelegate`（cpp L2113-2118/L2145-2149 转发） |
| `FStateTreeExecutionContext::FinishTask(const UE::StateTree::FFinishedTask&, ...)` | UE_DEPRECATED(5.6) | Weak 上下文 `FinishTask`（异步）或当前节点版 `FinishTask(FStateTreeTaskBase, ...)` |
| `FStateTreeMinimalExecutionContext` 引用版构造（UObject&, const UStateTree&, ...） | UE_DEPRECATED(5.6) | TNotNull 指针版构造（StateTreeExecutionContext.h L227-232） |
| `FStateTreeEventQueue::GetEventsArray()` | protected 成员，注释 "Used by FStateTreeExecutionState to implement deprecated functionality"（非公开弃用面） | — |
| `FStateTreeExecutionState::FindAndRemoveExpiredDelayedTransitions` | UE_DEPRECATED(5.6) | TriggerTransitions 内联收集（ExecutionTypes.h L1144-1161） |
| `FStateTreeTransitionDelayedState::StateTree` | UE_DEPRECATED(5.6) | `StateID`（ExecutionTypes.h L725-727） |
| `FStateTreeExecutionState::FinishedTasks / CompletedFrameIndex / CompletedStateHandle / CurrentExecutionContext` | UE_DEPRECATED(5.6) | `FinishTask` + FrameID/StateID + `FStateTreeTasksCompletionStatus`（WITH_EDITORONLY_DATA 区，L1258-1288） |
| `FStateTreeFrameStateSelectionEvents`（结构体本身） | UE_DEPRECATED(5.7) | `FSelectStateResult::Selection.SelectionEvents`（ExecutionTypes.h L1291-1297） |
| `UStateTreeTaskBlueprintBase::ReceiveEnterState / ReceiveTick`（带返回值 BP 事件） | UE_DEPRECATED(all) | 无返回值 `ReceiveLatentEnterState / ReceiveLatentTick` + `FinishTask` 节点（StateTreeTaskBlueprintBase.h L70-76） |
| `UStateTreeTaskBlueprintBase::WeakTaskRef` | UE_DEPRECATED(5.6) | Weak 上下文（FrameID/StateID/NodeIndex） |
| `FStateTreeExecutionExtension::ScheduleNextTick(const FContextParameters&)` | UE_DEPRECATED(5.7)，且 **final** | 新签名 `ScheduleNextTick(Context, FNextTickArguments)`——自定义扩展升级 5.7 必改 |
| `UE::StateTree::Delegates::FOnRequestCompile / OnRequestCompile` | UE_DEPRECATED(5.8) | `UStateTreeEditingSubsystem`（StateTreeDelegates.h L70-76） |

## 9. 测试佐证与多线程盲区

事件/委托/异步相关自动化测试共 **47 个用例**（StateTreeTestAsyncExecution 21 + StateTreeWeakContextTest 2 + StateTreeDelegateTest 24；06 报告按 17+2+24=43 计，系 AsyncExecution 旧口径，以 12-tests.md 逐条清点为准），**全部为单线程 `InstantTest`**（无 std::thread/AsyncTask/std::atomic 跨线程用例）：

| 测试文件（StateTreeTestSuite\Private\） | 用例数 | 覆盖契约（关键例证） |
|---|---|---|
| StateTreeTestAsyncExecution.cpp | 21 | Strong 上下文随状态退出/树停止/GC 失效（StrongContextInvalidAfterStateExit/Stop/GC）；tick 外 `SendEvent/FinishTask/RequestTransition` 缓冲到下帧；只读/写实例数据；`CopyInput/OutputBindings` 成功与失败面（属性函数返回 false 不覆盖已写值）；全局任务 WeakContext 跨转换存活 |
| StateTreeWeakContextTest.cpp | 2 | `FinishTask` 在/不在 tick 内的即时 vs 缓冲矩阵（全局任务=整树完成、状态任务=只完成该状态）；18 个 WeakContext 实例数据可见性矩阵（Linked 子树去激活后旧上下文失效） |
| StateTreeDelegateTest.cpp | 24 | 并发/互斥监听、OnDelegate 转换同帧触发、广播中自解绑（墓碑）、ManyToMany 收敛（25 绑定→每监听器 1 条）、31 监听器压测、TaskCompletionDispatcher 编译/GUID 确定性/Succeeds-Fails 条件过滤/执行链 |

**多线程盲区**：引擎自动化测试没有覆盖真实多线程下的 Weak→Strong 行为；`FStateTreeTest_SharedInstanceData` 仅用 ParallelFor 验证共享条件实例数据的创建时机，不覆盖 EventQueue/ExecutionState/TransitionRequests 的并发写。**其他盲区**：事件队列满（64）溢出行为零测试；ScheduledTick 宿主调度回路（组件 ScheduleTickFrame）零测试；组件宿主层（GameplayStateTreeModule）零测试。

## 10. 注意事项与坑

1. **事件溢出丢新事件**：队列满（64）时 `SendEvent` 失败只打 Error 日志（VisualLogger + UE_LOG），不抛错不排队——高频事件源可能静默丢事件；`TransitionRequests` 同理上限 32（StateTreeInstanceData.cpp L581-592）。
2. **共享队列唤醒盲区**：非所有者不会因共享队列里有事件被唤醒、也不会清队列（§1.3）——并行/共享设计中唤醒责任在所有者 tick 节奏上。
3. **事件生命周期 = 一次转换处理阶段**：SendEvent 后当帧没跑 TriggerTransitions 就留到下一阶段，但阶段末必清（pending 标记除外）；依赖"事件长期驻留"的设计不成立。
4. **`bConsumeEventOnSelect` 默认 true**：需要多状态响应同一事件时必须显式关闭。
5. **委托回调同步重入**：回调里再调 FinishTask/SendEvent/BroadcastDelegate 都会重入执行上下文；广播中 Remove 安全（墓碑）、`RemoveAll(FrameID/StateID)` 断言。
6. **监听器寿命绑定帧/状态**：状态退出即清；只有全局任务监听器跨转换存活；树结束全清。
7. **Strong 上下文栈上即用即弃**：Pin 发生在构造时——GC 已回收后创建的 Strong 无效（测试 StrongContextInvalidAfterGC）而非悬挂指针；跨线程创建 `TStrongObjectPtr` 需用户配合 GC 约定【推断】。
8. **Weak 默认可写**：拿 Weak 就等于"将来能写"，最小权限要传 `MakeStrongReadOnlyExecutionContext()`。
9. **CopyInputBindings 静默降级**：绑定批含属性函数或上下文/外部数据源时返回 false 且仅 Verbose 日志（StateTreeAsyncExecutionContext.cpp L414-441）；输出绑定批永不含属性函数、总是异步安全。
10. **GetNextScheduledTick 强制每帧**：Schema 未开 `IsScheduledTickAllowed` → `EveryFrames(Forced)`；组件侧还有模块级 cvar 开关（GameplayStateTreeModule 私有 `bScheduledTickAllowed`，StateTreeComponent.cpp L22-24）——排查"为什么没休眠"先查这两层。
11. **MaxIterations=5**：一次 Tick 内转换处理最多迭代 5 次（StateTreeExecutionContext.cpp L1979），链式"完成→转换→完成→…"超过 5 次留到下帧。
12. **事件入队 ≠ 当帧转换可见**：同帧入队立即可见（队列视图），但转换是否响应取决于该帧是否还会跑 TriggerTransitions——组件宿主通常 1 帧延迟（§7.2）。
13. **文件名陷阱**：`StateTreeDelegate.h`（单数）装的是树内委托与 `FTaskCompletionDispatcher`，`StateTreeDelegates.h`（复数）才是编辑器/Trace 全局委托——两文件职责与命名复数形式相反，检索时易混【源码】。

## 11. 开放问题

1. `UE_FLOAT_NON_FRACTIONAL` 的精确数值未核实（Sleep 判定 `NextDeltaTime >= UE_FLOAT_NON_FRACTIONAL` 的语义已由源码证实，仅哨兵常量值未查 float.h）。
2. MassAI（MassStateTree 层）等引擎插件对 Weak/Strong 上下文的真实跨线程调用点未逐一复核（线程跳跃方式与锁策略未验证）。
3. 事件驱动树的"1 帧延迟"是代码链推断；宿主同帧 SendEvent 后再手动 Tick 可当帧消费，具体帧序依赖宿主实现。
4. 异步线程创建 `TStrongObjectPtr` 的 GC 安全边界：引擎未封装保护，"需用户配合 GC 约定"为推断，源码无显式断言。
5. `FEventsPendingForNextTransitionProcessingScope` 的引入版本未核实（未见版本标记，5.6/5.7 疑似）。
6. 编辑器/Trace 全局委托（行 24-35）与内部委托（行 36-42）的触发点行号未逐一回查源码，依据 StateTreeDelegates.h 注释与 06 调研报告。
