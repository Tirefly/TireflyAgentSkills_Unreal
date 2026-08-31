# StateTree 全局坑索引（Pitfalls）

> 版本基线：UE 5.8.0 (Release-5.8, CL 55116800) · 版本标记约定：**[UE 5.x+]**=该版本新增，**[仅 <5.x]**=已移除/旧行为，**[5.8 变更]**=本版变更；现行 API 判定标准=声明无 UE_DEPRECATED 标记。

## TL;DR
- **线程安全完全由用户负责**：并发防护（MRSW 访问探测器）只在 DO_CHECK 构建存在，Shipping 下误用就是真实数据竞争。
- **队列溢出静默丢数据**：事件队列上限 64、TransitionRequests 上限 32，超限只打日志，不抛错不排队。
- **事件生命周期 = 一次转换处理阶段**；组件宿主事件驱动默认 1 帧延迟；`bConsumeEventOnSelect` 默认 true 会"抢"事件。
- **一组硬限制**：状态深度 `MaxStates=8`、同帧重规划 `MaxIterations=5`、绑定间接偏移/动态数组索引 uint16。
- **绑定是拷贝语义**；条件/Consideration 实例数据在同一资产所有使用处共享——改它 = 竞态。
- **宿主层大量静默失败**：`SendStateTreeEvent`、Linked overrides Schema 校验、Shipping 下 Link 失败都只留日志。
- **弃用壳与陈旧注释会骗人**：照抄弃用消息/注释可能编不过或解析失败（见「疑似引擎缺陷」节）。
- **调试三宏 Shipping/Test 全 0**（game 配置；UEFN Shipping-Editor 例外，见 debugging-trace.md §2）；Trace 与资产编译版本强绑定，重编译后旧 Trace 事件被丢弃。
- **真实多线程行为无自动化测试覆盖**；16 项测试盲区见「测试盲区」表。
- 证据约定：`NN-xxx.md §n` = 调研报告（C:\Users\TireflyPC\.agents\tmp\state-tree-research\）小节；源码根 = E:\UnrealEngine\UE_5.8\。

## 目录
1. 状态机语义
2. 生命周期
3. 事件与异步
4. 绑定与数据
5. 组件与宿主
6. 编辑器与资产
7. 调试
8. 性能与线程
9. 疑似引擎缺陷（未验证）
10. 测试盲区
11. 开放问题

## 1. 状态机语义

- **FStateTreeReferenceOverrides：注释 "exact match" vs `MatchesTag` 层级匹配**
  现象/根因：结构注释写 "tag is exact match"，执行路径实为 `StateTag.MatchesTag(Item.GetStateTag())` 层级匹配，父 tag 的 override 会吞掉子 tag 状态；`GetLinkedStateTreeOverrideForTag` 取第一个命中项，表内顺序敏感。规避：按层级匹配设计 tag，具体 tag 放表前。
  证据：02-asset-types.md §6.1（StateTreeExecutionContext.cpp L1288 vs StateTreeReference.h L173-175）；详见 runtime-execution.md。
- **状态深度硬上限 MaxStates=8**
  现象/根因：`FStateTreeActiveStates::MaxStates=8`，`SelectStateInternal`/`GetStatesListToState` 超限直接失败；Frame 数无此限制（TemporaryFrames 的 TInlineAllocator 只是性能暗示）。规避：状态层级设计留余量，勿假设深层嵌套可用。
  证据：01-core-execution.md §6.6（StateTreeExecutionTypes.h L320）。
- **同帧重规划上限 MaxIterations=5**
  现象/根因：一次 Tick 内转换处理最多迭代 5 轮；`EnterState` 持续失败 5 轮后停止重试——链式"完成→转换→完成"超过 5 次留到下帧，事件驱动树依赖此机制。规避：勿假设"一次 EnterState 失败 = 树失败"。
  证据：01-core-execution.md §6.7、06-events-async.md §6.11（StateTreeExecutionContext.cpp L1979-2032）。
- **零任务状态自动完成**
  现象/根因：整树无 enabled 任务且全部 Running 时，最底状态被自动置 Succeeded 触发完成转换——纯选择器树"走完即成"。规避：需要驻留时挂任务或改 SelectionBehavior。
  证据：01-core-execution.md §6.9（StateTreeExecutionContext.cpp L4893-4916）。
- **全局任务完成默认只停根 frame**
  现象/根因：CVar `StateTree.GlobalTasksCompleteOwningFrame=true`（默认）下，仅根 frame 的全局任务完成停整树；LinkedAsset 子树 frame 的全局任务完成只折叠子树。规避：按"子树全局任务完成≠整树结束"设计。
  证据：01-core-execution.md §6.10。
- **相位内 Stop 延迟生效、ForceTransition 直接失败**
  现象/根因：Start/Tick 相位内调 Stop 只置 `Exec.RequestedStop`，相位结束（Start 尾部/TickPostlude）才真正 Stop 并重置 InstanceData；`ForceTransition` 在相位内调用直接失败。规避：延迟生效逻辑放到相位边界之后。
  证据：01-core-execution.md §6.2（StateTreeExecutionContext.cpp L1707-1715/L3051-3056）。
- **RequestTransition 在转换处理阶段外只是缓冲**
  现象/根因：任务 Tick 回调里调 `RequestTransition`，实际状态选择发生在本帧稍后的 TriggerTransitions；只有该作用域内（含任务 `TriggerTransitions` 回调）才立即执行。规避：需要即时选择时用 ForceTransition（注意上一条的相位限制）。
  证据：01-core-execution.md §6.3（StateTreeExecutionContext.cpp L2192-2232）。
- **Sustained 状态刻意保留 5.6 完成位行为**
  现象/根因：ExitState 对 Sustained 状态重置完成位的代码注释自称 "keep the wrong UE5.6 behavior"（除非规则含 `CompletedTransitionStatesCreateNewStates`）——旧行为是刻意保留。规避：勿按注释自行"修复"。
  证据：01-core-execution.md §6.15（StateTreeExecutionContext.cpp L4061-4066）。
- **Start 阶段全局评估器立即 Tick 一次（DeltaTime=0）**
  现象/根因：`UStateTree::StartTree` 流程里全局评估器被立即 Tick 一次——评估器 Tick 有副作用时"Start 即触发"。规避：副作用放首个真正的树 Tick 后。
  证据：01-core-execution.md §6.14（StateTreeExecutionContext.cpp L1571-1573）。
- **条件绑定源不可访问时表达式整体为 false；ForcedTrue/ForcedFalse 为编译期固化**
  现象/根因：绑定源不可访问是评估期保护（整体按 false），排查"转换不发生"先看告警；`EStateTreeConditionEvaluationMode::ForcedTrue/ForcedFalse` 在编译/编辑期固化，不调 `TestCondition`。规避：转换丢失先查绑定告警再查 Forced 固化。
  证据：04-nodes-builtin.md §6.9（StateTreeExecutionContext.cpp L5110-5115）。

## 2. 生命周期

- **FStateTreeExecutionContext 不可跨帧保存**
  现象/根因：拷贝/赋值均被 delete；跨帧需求用 `MakeWeakExecutionContext()`（异步语义见 3 节）。规避：任何"存住 Context 晚点用"的写法都错。
  证据：01-core-execution.md §6.1（StateTreeExecutionContext.h L277/L341-342/L401）；详见 runtime-execution.md。
- **FinishTask 只认当前节点**
  现象/根因：`FinishTask` 带 `ensure(CurrentNode == &Task)`，只能在任务自身 EnterState/ExitState/StateCompleted/Tick/TriggerTransitions 内调用；异步完成必须走 WeakContext。规避：异步回调里用 `MakeWeakExecutionContext()` 后再 FinishTask。
  证据：01-core-execution.md §6.8；详见 events-async.md。
- **FinishTask 同帧优先级不反向覆盖**
  现象/根因：同步调用只是设置 RunStatus、事件返回后生效，异步调用立即生效；`SetTaskStatusWithPriority` 中 Succeeded/Failed 覆盖 Running 但不反向——同帧"先 Tick 完再异步 Finish"的顺序决定结果。规避：完成语义依赖明确调用顺序。
  证据：04-nodes-builtin.md §6.3（StateTreeExecutionContext.cpp L5005-5008）。
- **任务 Tick 返回 Failed 的连锁**
  现象/根因：参与完成判定的任务 Failed → 后续任务不再 Tick 且当帧即触发状态结束；被跳过任务仍会复制绑定（`bCopyBoundPropertiesOnNonTickedTask`）。规避：把 Failed 当"当帧终止"对待。
  证据：04-nodes-builtin.md §6.4（StateTreeExecutionContext.cpp L5026-5033/L4933）。
- **实例数据指针跨帧失效**
  现象/根因：`InstanceStructs` 因状态切换（ShrinkTo+Append）与扩容整体搬移。规避：跨帧持有改用 `TStateTreeInstanceDataStructRef`（StateTreeInstanceData.h L668-674）。
  证据：03-instance-data.md §6.1；详见 instance-data.md。
- **条件/Consideration 实例数据全资产共享**
  现象/根因：同一 StateTree 资产的所有使用处共享条件/consideration 实例数据；在 EnterState/ExitState/StateCompleted 回调中修改 = 竞态/串扰。规避：需要 per-instance 状态放 Task。
  证据：04-nodes-builtin.md §6.1（StateTreeConditionBase.h L30-31）。
- **蓝图任务 Tick 的隐性开关**
  现象/根因：`bShouldCallTick` 故意非 UPROPERTY，仅实现 `ReceiveLatentTick` 才会打开；不实现任何 Tick 事件的任务不会 Tick。规避：只想要"事件时 Tick"显式勾 `bShouldCallTickOnlyOnEvents`。
  证据：04-nodes-builtin.md §6.2（StateTreeTaskBlueprintBase Wrapper::Compile，cpp L193-196）。
- **bConsideredForScheduling=false 的含义**
  现象/根因：Delay/RunParallel 自管 ScheduledTick，设 false 后其 tick/transition 位不计入状态的 `bCachedRequestTick`，避免重复调度。规避：自定义任务自带调度时同样应关掉，防止双重 Tick。
  证据：04-nodes-builtin.md §6.5（StateTree.cpp L940-944）。
- **Random 条件每次求值重掷**
  现象/根因：`FStateTreeRandomCondition` 放 EnterConditions 时每次进入状态都重掷。规避：需要"一次掷定"用 Task 或 InstanceData 缓存结果。
  证据：04-nodes-builtin.md §6.14。
- **InstanceData 与 ExecutionRuntimeData 是两种存储**
  现象/根因：执行运行时数据在 Context Start~Stop 间持久；只活一次 tick 的数据放局部变量即可。规避：需跨 Context 重建存活（组件 Pause/Resume 后仍在）用 `GetExecutionRuntimeDataType`。
  证据：04-nodes-builtin.md §6.11；详见 nodes-builtin.md。
- **评估作用域默认值里的 UObject 是 TransientPackage 复制品**
  现象/根因：Add 时 `DuplicateObject(..., GetTransientPackage())`。规避：不可跨帧持有其指针。
  证据：03-instance-data.md §6.6（StateTreeEvaluationScopeInstanceContainer.cpp L96-104）。
- **普通 struct 嵌 FStateTreeInstanceData 不会自动 GC 引用**
  现象/根因：非 UObject 容器内的 `FStateTreeInstanceData` 不被 GC 跟踪。规避：含 UObject 引用实例数据的宿主自行保证引用有效。
  证据：03-instance-data.md §6.13（§5.D）。
- **FStateTreeInstanceData::Serialize 不是存档通道**
  现象/根因：它只服务 `IsModifyingWeakAndStrongReferences` 场景；用它做游戏存档会丢 ExecutionState/TransitionRequests/EventQueue 等全部 Transient 字段。规避：存档方案自行设计序列化范围。
  证据：03-instance-data.md §6.2（§2.8）。
- **DebugText 任务每帧不重画**
  现象/根因：`FStateTreeDebugTextTask` 在 `bShouldCallTick=false` 时 EnterState 一次 `DrawDebugString(Duration=-1)`，运行中改 Text 属性绑定不生效；清除发生在 ExitState 画空串。规避：动态文本需开 Tick 或换实现。
  证据：04-nodes-builtin.md §6.8。

## 3. 事件与异步

- **事件队列 64 上限溢出丢新事件**
  现象/根因：`FStateTreeEventQueue::MaxActiveEvents=64`，满时 `SendEvent` 失败仅打 Error 日志（VisualLogger+UE_LOG），不抛错不排队；`TransitionRequests` 上限 32 超限仅 VLOG。规避：高频事件源自查流量，勿依赖队列背压。
  证据：06-events-async.md §6.1、03-instance-data.md §6.4（StateTreeInstanceData.cpp L583，`MaxPendingTransitionRequests=32`；L581-592 为 `AddTransitionRequest` 函数区段，已复核）；详见 events-async.md。
- **事件生命周期 = 一次转换处理阶段**
  现象/根因：TriggerTransitions 结束即 `ClearEventsForCurrentTransitionProcessingPhase()`；当帧没跑 TriggerTransitions 事件留到下阶段，但阶段末必清（pending 标记除外）。规避："事件长期驻留"的设计不成立；`bShouldCallTickOnlyOnEvents` 与 OnEvent 转换都依赖此窗口。
  证据：01-core-execution.md §6.4、06-events-async.md §6.3（StateTreeExecutionContext.cpp L5767-5779）。
- **bConsumeEventOnSelect 默认 true 抢事件**
  现象/根因：第一个成功选择的状态消费事件，同级/后续状态对同一事件的转换不再触发。规避：需要多状态响应同一事件时显式关闭该选项。
  证据：06-events-async.md §6.4。
- **共享事件队列的唤醒盲区与 Reset 不清队列**
  现象/根因：非所有者实例不会因共享队列有事件而唤醒（`NextFrame(Event)`），也不会清队列；拷贝 `FStateTreeInstanceData` 得到独立新队列，共享必须显式 `SetSharedEventQueue`；借用方 `Reset()` 不清事件（归所有者管）。规避：共享队列的唤醒责任在所有者 tick 节奏上；排查"事件残留"先查所有权 `bIsOwningEventQueue`。
  证据：06-events-async.md §6.2、03-instance-data.md §6.3/§6.14（StateTreeExecutionContext.cpp L541-545/L5774）。
- **委托回调是同步重入**
  现象/根因：`BroadcastDelegate` 在遍历中直接 `ExecuteIfBound`，回调里再调 FinishTask/SendEvent/BroadcastDelegate 都会重入执行上下文；广播期间 Remove/Add 安全（墓碑+延迟清理），但 `RemoveAllDelegateListeners(FrameID/StateID)` 在广播中断言。规避：回调内只做轻量操作，重操作排下帧。
  证据：06-events-async.md §6.5（StateTreeExecutionTypes.cpp L353-394/L337/L347）。
- **事件驱动树默认 1 帧延迟【推断】**
  现象/根因：`SendEvent` 同帧即可见，但组件宿主靠 `ScheduleNextTick(Event)` 把 Tick 排到下帧消费——通常 1 帧延迟；宿主同帧 SendEvent 后再手动 Tick 可当帧消费。规避：帧序依赖宿主实现，勿假设当帧响应。
  证据：06-events-async.md §6.12+§8（推断）。
- **Strong 上下文必须栈上即用即弃**
  现象/根因：Weak→Strong 的 Pin 发生在构造时——GC 已回收后创建的 Strong 无效（测试 StrongContextInvalidAfterGC）；`TStrongObjectPtr` 钉 Owner 期间不被 GC。规避：异步回调内现取现用；异步线程创建 `TStrongObjectPtr` 的 GC 安全边界引擎未封装，需用户配合 GC 约定【推断】。
  证据：06-events-async.md §6.7+§8。
- **CopyInputBindings 的静默降级**
  现象/根因：绑定批含 PropertyFunction 或上下文/外部数据源时 `CopyInputBindings()` 返回 false 且仅 Verbose 日志；输出批永不含属性函数、总是异步安全。规避：异步重放绑定前检查返回值。
  证据：06-events-async.md §6.9（StateTreeAsyncExecutionContext.cpp L414-441）。
- **DelayedTransitions 的 CapturedEvent 去重**
  现象/根因：同状态同转换同事件哈希的重复触发在延迟期间被忽略；延迟到期后用捕获事件触发并按 `bConsumeEventOnSelect` 消费——事件可能"已被复制独占"（CaptureNewStateEvents 对在用 event 复制副本）。规避：事件驱动 + 延迟转换组合时按"每事件一次"设计。
  证据：01-core-execution.md §6.16（StateTreeExecutionContext.cpp L6062-6111/L3558-3625）。

## 4. 绑定与数据

- **绑定是拷贝语义不是持续同步**
  现象/根因：输出绑定（`bIsOutputBinding`→反向拷贝）只是方向反转的值拷贝；StructReference 拷贝的是指针，目标可能先于源失效（引擎注释自认风险）；任务/评估器实例数据不会自动清 UObject 引用。规避：需要持续同步自行建立双向通道。
  证据：05-property-bindings.md §6.3（PropertyBindingBindingCollection.cpp L680）；详见 property-bindings.md。
- **弃用 ParentFrame 壳固定传 nullptr** **[5.8 变更]**
  现象/根因：`PropertyRefHelpers::GetMutablePtrToProperty/GetMutablePtrTupleToProperty` 弃用重载转发时 TemporaryStorage 固定 nullptr——链式 PropertyRef 需查父帧（父帧在 TemporaryFrames 中）时解析失败返回 nullptr。规避：升级后改传当前 TemporaryStorage，勿继续用弃用壳。
  证据：05-property-bindings.md §6.4（StateTreePropertyRef.h L37-38/L73-74）。
- **uint16 偏移/数组索引硬限制**
  现象/根因：间接偏移 uint16（>64KB 的结构内属性不可绑定，check 失败）；动态数组索引 uint16（超限 `ResolvePaths` 失败→Link 失败→资产不可运行）；另 `FStateTreeIndex16` 的 0xffff 经 `AsInt32()` 映射回 INDEX_NONE、`FStateTreeIndex8` 上限 254。规避：大结构拆小、大数组降规模。
  证据：05-property-bindings.md §6.5、02-asset-types.md §6.12。
- **SetGlobalParameters 类型不匹配静默回退**
  现象/根因：类型不匹配时 ensure+回退资产默认值——宿主参数被静默丢弃（仅编辑器日志）。规避：升级改参数结构后务必迁移 bag 并运行验证。
  证据：05-property-bindings.md §6.6。
- **ExternalGlobalParameterData：裸指针 TMap + linked tree 直接 checkf 崩溃**
  现象/根因：映射是裸指针 TMap，宿主需保证绑定集合不变期间内存有效；`GetDataView` 对该源在 linked tree 内直接 `checkf(false, "External global parameter data currently not supported for linked state-trees")`。规避：linked 子树勿用该数据源。
  证据：05-property-bindings.md §6.6、01-core-execution.md §6.12（StateTreeExecutionContext.cpp L2852-2854）。
- **PropertyRef 取值的上下文约束**
  现象/根因：PropertyRef 不能指向 Context/External 数据（解析硬编码空 ContextAndExternalDataViews），不能引用 Condition/Consideration/PropertyFunction 内部；`GetMutablePtr(Context)` 依赖 `GetCurrentlyProcessedFrame()`，只能在节点处理栈内调用。规避：回调/延迟场景用 StrongContext 版本取值。
  证据：05-property-bindings.md §6.2（StateTreePropertyRef.cpp L16-17）。
- **object 拷贝语义差异与静默跳过**
  现象/根因：soft/weak/lazy object 互拷走 CopyComplex（拷引用路径不解引用），普通 object 拷指针值；`Copy.Type==None` 条目静默跳过并视为成功；`ResolvePaths` 未成功就 `CopyProperty` 会 ensure。规避：绑定表审查时区分引用拷贝与值拷贝。
  证据：05-property-bindings.md §6.6。

## 5. 组件与宿主

- **ScheduleTickFrame 接管组件 Tick 间隔**
  现象/根因：`ScheduleTickFrame` 会改写 `SetComponentTickIntervalAndCooldown`——手设的 tick interval 被覆盖；树休眠时组件 tick 整个关闭。规避：依赖组件 tick 的其他逻辑不要挂在 `UStateTreeComponent` 自身上。
  证据：07-gameplay-state-tree.md §6.2；详见 gameplay-state-tree.md。
- **SendStateTreeEvent 静默丢弃**
  现象/根因：未 Start 或引用无效时仅警告日志，事件不入队。规避：事件驱动设计先保证组件已启动。
  证据：07-gameplay-state-tree.md §6.4。
- **SetStateTree 运行中拒绝；overrides Schema 校验失败静默**
  现象/根因：运行中 `SetStateTree/SetStateTreeReference` 被拒（先 StopLogic，BP 库 RunStateTree 已处理）；`SetLinkedStateTreeOverrides/AddLinkedStateTreeOverrides` 在 Schema 不匹配时只警告并放弃（整表替换全部丢弃），返回 void 无错误反馈。规避：换树先 Stop；overrides 注入后自校验。
  证据：07-gameplay-state-tree.md §6.5/§6.6。
- **从未 Start 调 StopLogic 无效果**
  现象/根因：StopLogic 早退条件 `!bIsRunning` 直接 return——不会清理 InstanceData；EndPlay 依赖正常启动路径。规避：清理逻辑勿寄望于未启动组件的 StopLogic。
  证据：07-gameplay-state-tree.md §6.15。
- **OnStateTreeRunStatusChanged 在 StopLogic 中广播的时序**
  现象/根因：广播时 `bIsRunning` 已为 false；处理器内再调 StartLogic 允许（注释明示）。规避：勿在同帧造成 Start/Stop 风暴。
  证据：07-gameplay-state-tree.md §6.3。
- **AI Schema 的 "Actor" Context 是 Pawn 不是 Controller**
  现象/根因：`UStateTreeAIComponentSchema` 构造把 ContextActorClass 改成 APawn；`CollectExternalData` 中 AActor/AAPawn 类目在 Controller 场景都指向 Pawn（`AIOwner->GetPawn()` 优先）。规避：要绑 Controller 数据用 "AIController" 槽；要"Controller 本体"需自定义收集。
  证据：07-gameplay-state-tree.md §6.11/§6.12。
- **RunStateTree BT 任务每 tick 重建 Context**
  现象/根因：Interval 默认 0.01s（每帧），每 tick 重建 `FStateTreeExecutionContext` + 重收集外部数据；两次 tick 间 Actor context 必须稳定（ensureMsgf）。规避：高成本 `CollectExternalData` 自缓存。
  证据：07-gameplay-state-tree.md §6.9。
- **MoveTo 异步完成的瞬间完成特判**
  现象/根因：两个源码 @todo 限制——重入状态实例数据保留问题；"temporary task 瞬间完成时 WeakContext 找不到活跃 frame/state"（首查状态特判直接返回结果，PerformMoveTask L143-148）。规避：自定义异步 AI Task 复制同样的瞬间完成特判模式。
  证据：07-gameplay-state-tree.md §6.7/§6.8。
- **RunDynamicStateTree 的 delegate 是普通（非动态）委托**
  现象/根因：只能 C++ 注入；`bCreateNodeInstance=true` 使 delegate 存于节点实例（per-instance），BT 资产复制/网络同步场景下 InstancedNode 生命周期需自查。规避：蓝图侧改走其他注入路径。
  证据：07-gameplay-state-tree.md §6.10。
- **Mass 集成三约束：客户端不跑、插件级 Experimental、Schema 禁队列编译**
  现象/根因：`UE::MassStateTree::ExecutionFlags = Standalone|Server`，客户端预期落空；9 个接入点插件中 8 个 .uplugin 标 `IsExperimentalVersion: true`（含 Mass 全家，仅 Avalanche/Motion Design 无）；Mass/UAF Schema `AllowQueuedCompilation=false` 与 `FCompilerManager` 队列机制相斥。规避：以本机源码证据为准做集成决策。
  证据：11-integrations.md §6.2/§6.12/§7；详见 integrations.md。
- **自定义 Extension 的 ScheduleNextTick 签名** **[5.7 变更]**
  现象/根因：`FStateTreeExecutionExtension::ScheduleNextTick` 旧单参版弃用且 final → 必须改带 `FNextTickArguments(ETickReason)` 的新签名。规避：5.7 起宿主自定义扩展必改。
  证据：06-events-async.md §7、07-gameplay-state-tree.md §7（StateTreeExecutionExtension.h L53-68）。
- **GetNextScheduledTick 的强制每帧回退**
  现象/根因：Schema 未开 `IsScheduledTickAllowed` 时整体回退 EveryFrame(Forced)；组件侧还有模块级私有 CVar `bScheduledTickAllowed`。规避：排查"为什么没休眠"先查这两层。
  证据：06-events-async.md §6.10（StateTreeComponent.cpp L22-24）。

## 6. 编辑器与资产

- **ECompileStatus 默认是 Link，不是"编译完成"**
  现象/根因：新建/未编译的 UStateTree 一开始就是 Link 态；`Link()` 遇 Public/Internal 直接失败——Link 态语义是"数据可能已编译、需要（重新）链接"。规避：判定可用性用 `IsReadyToRun()` 而非 CompileStatus。
  证据：02-asset-types.md §6.10；详见 assets-types.md。
- **bCanOverrideLinkedAssetAtRuntime 被编译器静默关闭**
  现象/根因：只在参数/事件绑定到该状态时被关——覆盖不生效且无报错。规避：LinkedAsset 模板 + 参数覆盖优先用 `FStateTreeReference` 的参数覆盖而不是绑定向导。
  证据：02-asset-types.md §6.2。
- **运行时打包构建 Link 失败不自动重编译**
  现象/根因：`IsReadyToRun()` 只在 `bCompilationPending`（编辑器）时刷；Shipping 下 Link 失败的资产直接不可用（PostLoad 只打 Warning）。规避：Cook 前用 `StateTreeCompileAllCommandlet` 批编译验证。
  证据：02-asset-types.md §6.4（StateTree.cpp L560-569）；详见 editor.md。
- **ExternalDataDescs 是 Transient**
  现象/根因：不序列化，依赖每次加载 Link 重建。规避：任何绕过 Link 的手工拷贝资产方式会得到空外部数据描述。
  证据：02-asset-types.md §6.5。
- **FStateTreeCustomVersion 弃用但仍必须注册；UENUM 旧名永久保留**
  现象/根因：struct 上的 UE_DEPRECATED(all) 只表示"不再扩展"，GUID 注册和 `UsingCustomVersion` 调用仍在，删除会破坏全部旧资产读取；`EStateTreeStateSelectionBehavior` 两个旧枚举名弃用也必须保留。规避：自订枚举/版本机制照此办理。
  证据：02-asset-types.md §6.8/§6.9。
- **FStateTreeCompiler 一次性 + 失败语义 + PIE 禁手动重编**
  现象/根因：实例化后只能 `Compile*` 一次；编译失败把 dirty 清为 None（"再编译一次结果相同"），靠 CompileStatus 表达失败；`UStateTreeEditorMode::CanCompile()` 在 PIE 返回 false。规避：排查"为何没自动重编"先看 CompileStatus 与 LastCompiledEditorDataHash=0。
  证据：08-editor-compiler.md §6.1/§6.2/§6.6；详见 editor.md。
- **排队编译约束与资产加载默认同步编译**
  现象/根因：`FlushCompilationQueue` 仅 game thread；CVar `StateTree.Compiler.EnableQueuedCompilationOnAssetLoad` 默认 false=加载即同步编译；`NumberOfQueuedCompilationPerBatch` 默认每帧 1 个。规避：大量 StateTree 资产的关卡加载打开排队或自行预热。
  证据：08-editor-compiler.md §6.3/§6.5、09-editor-ui.md §6.9。
- **程序化改绑定不触发重编译（UE-337309）**
  现象/根因：`UStateTreeEditorData::OnPropertyBindingChanged` 只在 DetailsView 改绑定时被调（官方 TODO 注释）。规避：程序化改节点/状态后务必手动 `UpdateBindings()`/`ValidateStateTree()`。
  证据：08-editor-compiler.md §6.8（StateTreeEditorData.h L108-109）。
- **BP/UDS 重实例化的已知盲区**
  现象/根因：`HandleObjectsReinstanced` 对 property 用途（Input/Output 互换）与节点特殊 flag 变化无法检测（@TODO 5/6），行为未定义直到下次加载/编译。规避：改属性用途后强制重编译。
  证据：08-editor-compiler.md §6.9（StateTreeCompilerManager.cpp L833-843）。
- **编译产物 outer 必须在 StateTree 下**
  现象/根因：UObject 型节点实例数据必须 duplicate 到 StateTree（不得挂在 EditorData 下），`CheckCompiledStateTreeOuters` 专抓此错误。规避：自定义节点实现检查实例数据 outer。
  证据：08-editor-compiler.md §6.11（StateTreeCompiler.cpp L153-161）。
- **Subtree 参数不能有绑定**
  现象/根因：编译注释明令禁止；全局参数默认也不允许绑定 dispatcher（CVar 实验特性）。规避：参数传递用覆盖机制而非绑定。
  证据：08-editor-compiler.md §6.12（StateTreeCompiler.cpp L1243-1244）。
- **绑定 UI 可用性依赖属性元数据与手动挂载**
  现象/根因：自定义节点不打对 `EStateTreePropertyUsage`（Input/Context/Parameter/Output）、`RefType/CanRefToArray`、`AllowAnyBinding`、`BaseStruct` 等元数据，绑定 UI 不显示或绑不上；`SetDetailPropertyHandlers` 需每个 DetailsView 单独调用；Output 绑定源限 Parameter/StateParameter。规避：自定义节点按元数据清单逐项补齐。
  证据：09-editor-ui.md §6.4/§6.5/§6.6。
- **编辑器能力边界：无 Merge、Find 不进全局、编辑/运行 DataModel 分离**
  现象/根因：StateTreeEditorModule 无 merge 代码（SCC 冲突只能 Diff 手改）；`SFindInAsset` 的全局 Find Results 被注释禁用；直接改运行时 `UStateTree` 字段不反映到编辑器视图且会被编译覆盖。规避：团队协作按"只能 Diff"规划流程。
  证据：09-editor-ui.md §6.7/§6.8/§6.12。

## 7. 调试

- **Trace 与资产版本强绑定**
  现象/根因：Analyzer 用 `FindObject` 按路径解析 UStateTree 并比对 `LastCompiledEditorDataHash`；录制后重新编译该资产（或分析进程内没有该资产）→ 告警并丢弃该资产事件。规避：回放前保证资产版本一致。
  证据：10-debugging-trace.md §6.1（StateTreeTraceAnalyzer.cpp L51-81）；详见 debugging-trace.md。
- **StartTraces 会关掉其他所有 Trace 通道**
  现象/根因：新建连接时先枚举并禁用全部已开通道，只开 StateTreeDebugChannel+FrameChannel；仅"复用已有连接"路径才恢复原通道集合。规避：同时做性能 trace 时留意通道被抢。
  证据：10-debugging-trace.md §6.2（StateTreeModule.cpp L222-246/L309-318）。
- **断点是资产粒度且需断点处理者**
  现象/根因：不能按实例设断点；`CanProcessBreakpoints()` 要求 `OnBreakpointHit` 已绑定（编辑器 UI）；运行时 game 进程没有断点概念（TRACE_DEBUGGER=0 根本不编译）。规避：断点只在编辑器调试流里预期。
  证据：10-debugging-trace.md §6.3/§6.4。
- **帧内不可 scrub**
  现象/根因：`ActiveStatesChanges` 每帧仅保留最后一条活动状态快照——帧内多次状态变化在时间线上看不到中间态。规避：需要中间态时缩小步长或加日志。
  证据：10-debugging-trace.md §6.5（StateTreeDebugger.cpp L1036-1045）。
- **调试宏 Shipping/Test 一刀切 + 主机无回放**
  现象/根因：`WITH_STATETREE_TRACE`/`WITH_STATETREE_TRACE_DEBUGGER`/`WITH_STATETREE_DEBUG` 在 Shipping/Test（game 配置；UEFN Shipping-Editor 例外，见 debugging-trace.md §2）全 0（DEBUG 连 Test 配置都不含）；`IsStateTreeDebuggerSupported` 限定 Desktop，主机只能录制。规避：Shipping 代码路径勿引用调试 API。
  证据：10-debugging-trace.md §6.7/§6.8（StateTreeModule.Build.cs L24-28）。
- **RuntimeValidation 报错自灭**
  现象/根因：每个校验 CVar 首次 ensure 后自动置 false（防刷屏）。规避：复现"第二次报错"需手动把 CVar 改回 1 并重启相关实例上下文。
  证据：10-debugging-trace.md §6.13。
- **CVar 改变运行时语义，排查兼容性先查开关**
  现象/根因：`StateTree.CopyBoundPropertiesOnNonTickedTask`(false)、`StateTree.TickGlobalNodesFollowingTreeHierarchy`(true)、`StateTree.GlobalTasksCompleteOwningFrame`(true)、`StateTree.SetDeprecatedTransitionResultProperties`(false)、`StateTree.TargetStateRequiresTheSameEventForStateSelectionAsTheRequestedTransition`(false)、`StateTree.CaptureStateEventPayloadForSustainedState`(true)；组件级 `StateTree.Component.ScheduledTickEnabled`/`DefaultScheduledTickAllowed` 是进程级开关。规避：升级资产兼容性排查从这些开关开始。
  证据：01-core-execution.md §6.11（StateTreeExecutionContext.cpp L36-86）、07-gameplay-state-tree.md §6.13。
- **Trace 文本导出过滤属性且有成本**
  现象/根因：`ExportText` 用 `PPF_PropertyWindow`（仅编辑器可见属性）+`PPF_IncludeTransient`——非编辑器可见属性不进 Trace；序列化有 `TRACE_CPUPROFILER_EVENT_SCOPE` 成本。规避：想看的数据打成编辑器可见或自定义 trace。
  证据：10-debugging-trace.md §6.6（StateTreeTrace.cpp L586-621）。
- **非编辑器目标默认不自动录制 Trace**
  现象/根因：需要 `UStateTreeSettings::bAutoStartDebuggerTracesOnNonEditorTargets=true` 或控制台命令；录制写 localhost Trace Store，分析端需同机（或 Store 转发）。规避：远端设备调试先配好 Store 转发。
  证据：10-debugging-trace.md §6.12（StateTreeModule.cpp L128-139/L200-274）。

## 8. 性能与线程

- **并发无真锁，线程安全用户负责**
  现象/根因：MRSW 访问探测器只在 DO_CHECK 构建——ReadOnly 可并存、Minimal/Full/Weak 独占写的约定在 Shipping 下无任何防护，违规是真实数据竞争而非 ensure。规避：多线程宿主自行串行化；`UE_MT` 探测器只在检查构建兜底。
  证据：03-instance-data.md §6.11、01-core-execution.md §6.13（StateTreeExecutionContext.cpp L390-402/L857-867）；详见 instance-data.md。
- **异步测试全单线程，真多线程无自动化覆盖**
  现象/根因：StateTreeTestAsyncExecution/StateTreeDelegate/StateTreeWeakContext 三个测试文件全部为单线程 `InstantTest`（测试未用 std::thread/AsyncTask 起线程；static atomic 存在于测试基建——`FStateTreeTestCondition` 的 `GlobalCounter` 计数器，12-tests.md §6.6）；唯一并发触达 `FStateTreeTest_SharedInstanceData` 的 ParallelFor 仅覆盖共享条件实例数据。规避："线程安全由用户负责"目前只有头注释 + MRSW 探测器背书，自行压测。
  证据：06-events-async.md §8、12-tests.md §5.4。
- **ID/状态映射 O(n) 线性查找**
  现象/根因：`GetStateHandleFromId/GetNodeIndexFromId/GetTransitionIndexFromId/GetStateHandleFromGameplayTag` 均 FindByPredicate；临时实例 Add/Remove/Get 也是线性扫描。规避：高频调用（如每帧按 Tag 找状态）缓存结果。
  证据：02-asset-types.md §6.3、03-instance-data.md §6.9。
- **Storage 拷贝昂贵且内存估算少算三块**
  现象/根因：`FStateTreeInstanceStorage` 深拷贝全部字段含事件队列（`FStateTreeInstanceData` 的 UPROPERTY 复制即 PIE duplicate 触发）；`GetEstimatedMemoryUsage` 不含 TemporaryInstances、EventQueue、BroadcastedDelegates。规避：内存预算自行补齐三块。
  证据：03-instance-data.md §6.7/§6.10（StateTreeInstanceData.cpp L948-957）。
- **评估作用域 alloca 无上限风险【推断/风险】**
  现象/根因：评估作用域内存来自 `FMemory_Alloca_Aligned`，需求由编译期决定，源码未见上限校验/栈余量保护——极端多条件状态放大栈占用。规避：控制单状态条件/consideration 规模；栈溢出风险未实测。
  证据：03-instance-data.md §6.5+§8.4-5。
- **每帧重建 Context 是宿主通用模式**
  现象/根因：Camera/Avalanche/GameplayInteractions/Mass 全部每次 Start/Tick/Stop 前重建 `FStateTreeExecutionContext`；Mass 用 CSV 盯 ExternalDataValidation/Execute。规避：自定义高频宿主的性能预算按此模式估算。
  证据：11-integrations.md §6.6（MassStateTreeProcessors.cpp L26/L63/L317-318）；详见 integrations.md。

## 9. 疑似引擎缺陷（未验证）

以下条目均为静态阅读发现，**疑似，未验证**（未在真实运行/编译中复现）；使用前自行复核。

- **UBTTask_RunDynamicStateTree::TickTask 无效引用分支缺 return（疑似，未验证）**
  现象：`if (!StateTreeRef.IsValid()) { FinishLatentTask(Failed); }` 后无 return，继续 `*StateTreeRef.GetStateTree()` 解引用构造 Context（参数 TNotNull，预期 ensure 崩溃）；正常流程 ExecuteTask 已拦截，触发窗口窄。
  规避：派生/极端用法自行加引用检查；勿在 latent 运行中清空引用。
  证据：07-gameplay-state-tree.md §6.1/§8.2-3；E:\UnrealEngine\UE_5.8\Engine\Plugins\Runtime\GameplayStateTree\Source\GameplayStateTreeModule\Private\BehaviorTree\Tasks\BTTask_RunDynamicStateTree.cpp L78-88。
- **FStateTreePropertyRef::GetMutablePtrTuple 5 参调 4 参（疑似，未验证）**
  现象：StateTreePropertyRef.h L172 调 `PropertyRefHelpers::GetMutablePtrTupleToProperty` 传 5 实参，现行重载只 4 参（L85，弃用重载 L71 同）；按模板实例化规则，引擎内零实例化故 5.8.0 Release 可编过，用户一旦调用（含 `TStateTreePropertyRef<T>::GetMutablePtrTuple` L269-272 转发）即编译错误【推断：5.8 重构漏改残骸；未编译验证】。
  规避：改用 `GetPtrTupleFromStrongExecutionContext` 或逐类型 `GetMutablePtr<T>`；详见 property-bindings.md §5.5。
  证据：05-property-bindings.md §6.1/§8.2-1；E:\UnrealEngine\UE_5.8\Engine\Plugins\Runtime\StateTree\Source\StateTreeModule\Public\StateTreePropertyRef.h L172/L85/L71。
- **UAF 宿主不调用树 Stop（UE-240683）（疑似，未验证）**
  现象：`FStateTreeTrait::FInstanceData::Destruct` 的 Stop 逻辑整段注释，@TODO UE-240683——动画域宿主没有干净的树停止路径。
  规避：UAF 下任务依赖 ExitState 清理需自行评估兜底。
  证据：11-integrations.md §6.1；E:\UnrealEngine\UE_5.8\Engine\Plugins\Experimental\UAF\UAFStateTree\Source\UAFStateTree\Private\AnimStateTreeTrait.cpp L33-72。
- **OnPreCookStateTreeAsset "类型笔误"实为非缺陷（疑似笔误，未验证是否本意）**
  现象：StateTreeDelegates.cpp L45 用 `FOnStateTreeAssetLoaded` 类型定义 `OnPreCookStateTreeAsset`——delegate 宏展开为同一 `TDelegate` typedef 而等效，行为无差；阅读源码勿误判为两个变量。
  规避：检索/重构时按同一 typedef 理解。
  证据：06-events-async.md §6.13；E:\UnrealEngine\UE_5.8\Engine\Plugins\Runtime\StateTree\Source\StateTreeModule\Private\StateTreeDelegates.cpp L45。
- **FExecutionRuntimeData 疑似零引用遗留类型（疑似，未验证）**
  现象：StateTreeModule/GameplayStateTreeModule/MassAIBehavior 范围 grep 零引用（仅测试内 `FExecutionRuntimeDataType` typedef 同名概念）；运行时真实结构是 `FExecutionRuntimeInfo`+`FInstanceContainer`；全 Engine\Plugins 扫描超时未完成。
  规避：勿基于该类型写代码；以 `FExecutionRuntimeInfo` 为准。
  证据：03-instance-data.md §6.8/§8.4-2；E:\UnrealEngine\UE_5.8\Engine\Plugins\Runtime\StateTree\Source\StateTreeModule\Public\StateTreeExecutionRuntimeDataTypes.h L17-27。
- **源码陈旧注释/文案错位清单（疑似，未验证修复意愿）**
  现象（引擎源）：`CalculateEstimatedMemoryUsage` 把 `DefaultInstanceData.GetStruct(0)` 注释为 "Exec state"，但编译布局索引 0 是首个 Evaluator 实例（02 §6.7）；StateTreeAsyncExecutionContext.h L52 注释 `CreateStrongContext()` 实际 API 是 `MakeStrongExecutionContext()`（05 §6.6）；`UpdateBindingsInstanceStructs` 弃用消息的替代名 UpdateEditorBindings 在 5.8 公开 API 不存在，现行 `UpdateBindings()`（08 §6.14，注意与 09 §7 记录矛盾，见开放问题）。
  现象（测试源，引用"注释意图"以断言为准，12-tests.md §6.13）：StateTreeTest.cpp:1687 断言消息 "Tree should be running" 实际期望 Stopped、:1333/:1531 Tick/Stop 返回值消息误标、:2063-2069 注释图与任务挂载不符；StateTreeLinkedStateTest.cpp:1053 断言方向相反、:1260-1261 Task3/Task4 赋值笔误；StateTreeWeakContextTest.cpp:195 重置错误旗标、:648 任务名与挂载状态不符；StateTreeRunParallelStateTreeTaskTest.cpp:83/:92/:431/:917 注释过时/误标。

## 10. 测试盲区

以下运行时行为在 StateTreeTestSuite 中**没有任何测试**（主体来源：12-tests.md §5 盲区清单；其中「环形委托绑定」项的测试本体另见 12-tests.md §2.5（Delegate_CircularBinding，StateTreeDelegateTest）、「WITH_STATETREE_DEBUG 校验」项的唯一触达测试另见 §2.7；"无测试"≠"行为不存在"）：

| 盲区 | 含义 | 风险 |
|---|---|---|
| 事件队列满溢出 | `MaxActiveEvents=64` 溢出语义零测试 | 满后行为只能靠源码推断 |
| 宿主组件层 | UStateTreeComponent/UStateTreeAIComponent 全链零测试 | 组件调度/暂停/事件入口变化无回归网 |
| ScheduledTick 回路 | 真实调度顺序仅浅层触达 | 自定义 Extension/调度改造无保护 |
| 真实多线程 | 仅 ParallelFor 覆盖共享条件实例数据 | Storage 并发写与多宿主并发无覆盖 |
| Considerations | 效用求值/响应曲线零断言 | 评分回归不可检测 |
| 内置 PropertyFunctions | 测试只用自造函数 | 内置函数缺陷不会被发现 |
| Trace/Debugger | WITH_STATETREE_TRACE 全链零测试 | 调试器回归靠人工 |
| 序列化/持久化 | InstanceData SaveGame 往返零测试 | 存档方案需自行验证 |
| 编译器失败模式 | 仅 1 个编译校验有测试 | 报错路径回归不可控 |
| 随机种子 | RandomSeed 可重现性零测试 | 种子复现排查不可靠 |
| Tag 层级事件过滤 | 仅精确 Tag 有测试 | 层级匹配行为无断言 |
| AutoRTFM | 无事务回滚验证 | 事务语义纯靠声明 |
| WITH_STATETREE_DEBUG 校验 | 唯一触达是显式关闭 | 校验器自身缺陷无网 |
| 环形委托绑定 | 名为 Circular 实为 A→B→C 链 | 引用该测试注意名实不符 |
| CVar 组合面 | CVar 门控双开覆盖仅 3 处：双跑 ×1（`StateTree.TickGlobalNodesFollowingTreeHierarchy`，StateTreeLinkedStateTest.cpp:475/:750）、四跑 ×1（`StateTree.GlobalTasksCompleteOwningFrame`，:1692-1698）、仅关闭 ×1（`StateTree.RuntimeValidation.EnterExitState`） | 其余开关组合行为未知 |
| DeltaTime=0/极大步长 | 测试均用非零小步长 | 0 dt 边界行为未知 |

另注（12-tests.md §6，复用测试 DSL 时）：测试全部为 InstantTest 单函数体，"时长"语义是累计 Tick 时间而非真实帧数；`Expect().Then()` 是相对顺序非相邻；`ExpectInActiveStates` 是全等；`AITEST_TRUE/FALSE/EQUAL` fail-fast（失败即 return，后续断言不执行）；`FLogOrder::Then` 消息匹配大小写不敏感（StringView.h UEOpEquals→Equals(IgnoreCase)，测试内 "Exitstate102" 与 "ExitState102" 混用仍通过）。

## 11. 开放问题

以下为各报告未证实项中与坑直接相关者（均未经真实运行/编译验证）：

| 事项 | 出处 |
|---|---|
| GetMutablePtrTuple "实例化即编译失败"判定基于 C++ 规则+全引擎零调用检索，未实际编译验证 | 05 §8.2-1 |
| RunDynamicStateTree 缺 return 的实际可触发性未运行验证 | 07 §8.2-3 |
| FExecutionRuntimeData 全 Engine\Plugins 引用面扫描超时未完成 | 03 §8.4-2 |
| 评估作用域 alloca 栈溢出风险未实测 | 03 §8.4-5 |
| 事件驱动树"1 帧延迟"为代码链推断，帧序依赖宿主实现 | 06 §8-3 |
| 异步线程创建 TStrongObjectPtr 的 GC 安全边界为推断 | 06 §8-4 |
| Mass 对 Weak/Strong 上下文的真实跨线程调用点未逐一复核 | 06 §8-2、11 §8 |
| ~~UpdateBindingsInstanceStructs 替代名两报告矛盾~~ 已裁决：亲核 StateTreeEditorData.h L254-261——弃用的是 UpdateBindingsInstanceStructs，现行替代 UpdateBindings()，"UpdateEditorBindings" 系弃用消息笔误（与 editor.md §9、version-deltas.md §5.12 一致；customization-guide 弃用表已同步修正） | editor.md §9、version-deltas.md §5.12 |
| 事件队列满溢出的真实行为未知（无测试≠行为不存在） | 12 §8-3 |
| "keep the wrong UE5.6 behavior" 注释所指 5.6 缺陷来龙去脉 | 01 §8.2-5 |
| CalculateEstimatedMemoryUsage "Exec state" 注释矛盾对估算数值的影响未验证 | 02 §6.7/§8.2-4 |
| bCopyBoundPropertiesOnNonTickedTask 默认值与配置入口未追踪 | 04 §8.2-6 |
| GetPtrFromStrongExecutionContext 非 const（元组版 const）是否有意 | 05 §8.2-2 |
