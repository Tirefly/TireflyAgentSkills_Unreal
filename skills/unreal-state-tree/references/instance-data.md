# StateTree 实例数据与评估作用域（Instance Data & Evaluation Scope）

> 版本基线：UE 5.8.0 (Release-5.8, CL 55116800) · 版本标记约定：**[UE 5.x+]**=该版本新增，**[仅 <5.x]**=已移除/旧行为，**[5.8 变更]**=本版变更；现行 API 判定标准=声明无 UE_DEPRECATED 标记。

## TL;DR

- `FStateTreeInstanceData` 是对外 USTRUCT 薄句柄，唯一成员 `TSharedRef<FStateTreeInstanceStorage>`；Storage 可 bitwise relocate、可安全 move，跨生命周期引用走 `TStateTreeInstanceDataStructRef`（TWeakPtr）。
- `FStateTreeInstanceStorage` 持有 12 个运行时字段 + 1 个 `WITH_STATETREE_DEBUG` 条件字段；"ActiveStates" 不是 Storage 直接字段，实际在 `ExecutionState.ActiveFrames[].ActiveStates`（定长 `MaxStates=8`）。
- 三种容器职责：`FInstancedStructContainer`（StructUtils 主缓冲）→ `FInstanceContainer`（StateTree 薄包装，ExecutionRuntimeData/默认值容器）→ `FEvaluationScopeInstanceContainer`（不拥有内存、外部提供栈内存、move-only）。
- InstanceStructs 帧布局由执行上下文维护：公共前缀校验 + `ShrinkTo` + `Append`（临时实例 Memswap 移入正式存储）。
- 评估作用域内存（条件/consideration/property function 实例）编译期由 `FMemoryRequirementBuilder` 算需求并缓存于 State/Transition/UStateTree 四处；运行期 `FMemory_Alloca_Aligned` 栈分配 + Push/Pop 缓存栈；布局 `[FItem 表][TableEndTag][struct+EndTag]×N`；UObject 默认值复制进 TransientPackage。
- 并发无真锁：`UE_MT_DECLARE_MRSW_RECURSIVE_ACCESS_DETECTOR`（DO_CHECK 门控探测器）+ AutoRTFM ONABORT 回滚；唯一真锁是 SharedInstanceData 的 `FTransactionallySafeRWLock` + per-thread 副本。
- 序列化走 `FStateTreeInstanceStorageCustomVersion`（GUID 60C4F0DE-…），**仅支持 `FArchive::IsModifyingWeakAndStrongReferences()` 场景，不是通用存档路径**。
- POD 宏迁移 **[5.8 变更]**：`STATETREE_POD_INSTANCEDATA` 弃用 → `UE_STATETREE_CONSTRUCTED/ZEROED_TRIVIALLY_COPIED_NO_DESTRUCTOR_INSTANCEDATA`。
- `FExecutionRuntimeData`（StateTreeExecutionRuntimeDataTypes.h）疑似零引用遗留；运行时真实结构是 `FExecutionRuntimeInfo` + `FInstanceContainer`。

## 目录

- [1. 源码地图与命名澄清](#1-源码地图与命名澄清)
- [2. 三层抽象：Data / Storage / Container](#2-三层抽象data--storage--container)
- [3. FStateTreeInstanceData（对外句柄）](#3-fstatetreeinstancedata对外句柄)
- [4. FStateTreeInstanceStorage 逐字段](#4-fstatetreeinstancestorage-逐字段)
- [5. InstanceStructs 帧布局与重排算法](#5-instancestructs-帧布局与重排算法)
- [6. 评估作用域内存（Evaluation Scope Memory）](#6-评估作用域内存evaluation-scope-memory)
- [7. ExecutionRuntimeData（执行运行期容器）](#7-executionruntimedata执行运行期容器)
- [8. SharedInstanceData（每线程副本）](#8-sharedinstancedata每线程副本)
- [9. 并发约定](#9-并发约定)
- [10. 序列化与 GC](#10-序列化与-gc)
- [11. 实例数据类型特征宏（POD 迁移）](#11-实例数据类型特征宏pod-迁移)
- [12. 弃用 API 单列表](#12-弃用-api-单列表)
- [13. 注意事项与坑](#13-注意事项与坑)
- [14. 开放问题](#14-开放问题)

---

## 1. 源码地图与命名澄清

源码根（本节所有相对引用基于此）：`E:\UnrealEngine\UE_5.8\Engine\Plugins\Runtime\StateTree\Source\StateTreeModule\`

| 文件（绝对路径后缀） | 核心类型 | 职责 |
|---|---|---|
| `Public\StateTreeInstanceData.h`（836 行）/ `Private\StateTreeInstanceData.cpp`（1232 行） | `FStateTreeInstanceData`、`FStateTreeInstanceStorage`、`FStateTreeTemporaryInstanceData`、`FStateTreeInstanceStorageCustomVersion`、`TStateTreeInstanceDataStructRef<T>`、`UE::StateTree::InstanceData::GetDataView` 族 | 对外句柄 + 真实存储 + 布局解析 |
| `Private\StateTreeInstanceDataHelpers.h` | `UE::StateTree::InstanceData::Private`（IsHandleSourceValid / GetTemporaryDataView / AppendToInstanceStructContainer 等） | 解析与追加辅助 |
| `Public\StateTreeInstanceContainer.h` | `FStateTreeInstanceObjectWrapper`、`UE::StateTree::InstanceData::FInstanceContainer` | 通用实例容器（结构体数组 + UObject 包装） |
| `Public\StateTreeEvaluationScopeInstanceContainer.h` / `Private\StateTreeEvaluationScopeInstanceContainer.cpp` | `UE::StateTree::InstanceData::FEvaluationScopeInstanceContainer`、`FMemoryRequirementBuilder`、`FEvaluationScopeMemoryRequirement`（定义于 `Public\StateTreeTypes.h` L517-530） | 评估作用域临时容器（外部内存、栈分配） |
| `Public\StateTreeExecutionRuntimeDataTypes.h`（30 行） | `UE::StateTree::InstanceData::FExecutionRuntimeData` | 仅一个"StateTreeKey + Instances 容器"结构，5.8 运行时代码零引用（见 §7） |
| 交叉依赖 | `Public\StateTree.h`（DefaultInstanceData/DefaultEvaluationScopeInstanceData/SharedInstanceData 等）、`Public\StateTreeTypes.h`（EStateTreeDataSourceType/POD 宏）、`Public\StateTreeExecutionTypes.h`（FStateTreeExecutionState/FStateTreeExecutionFrame）、`Private\StateTreeExecutionContext.cpp`（布局重排与作用域使用方）、`Private\StateTree.cpp`（GetSharedInstanceData/编译期缓存） | — |
| 引擎 Core | `E:\UnrealEngine\UE_5.8\Engine\Source\Runtime\Core\Public\Misc\MTAccessDetector.h` | `FMRSWRecursiveAccessDetector`（并发探测器实现） |

命名澄清（任务书名称 → 实际类型）【源码】：

- "StateTreeInstanceContainer" → 实际类型是 `UE::StateTree::InstanceData::FInstanceContainer`（文件 `StateTreeInstanceContainer.h`）；**不存在**名为 `FStateTreeInstanceContainer` 的类型。
- "StateTreeEvaluationScopeInstanceContainer" → 实际类型 `UE::StateTree::InstanceData::FEvaluationScopeInstanceContainer`。
- "StateTreeExecutionRuntimeDataTypes 及相关运行时数据结构" → 该文件只有 `FExecutionRuntimeData`；运行时真正使用的是 `FStateTreeInstanceStorage::ExecutionRuntimeData`（`FInstanceContainer`）+ `FExecutionRuntimeInfo`（Storage 内部私有结构，StateTreeInstanceData.h L403-408）。

## 2. 三层抽象：Data / Storage / Container

```
FStateTreeInstanceData (USTRUCT, 对外句柄)
  └─ TSharedRef<FStateTreeInstanceStorage> InstanceStorage   ← 唯一数据成员（StateTreeInstanceData.h L636）
       ├─ FInstancedStructContainer InstanceStructs          ← 主缓冲（全局参数/全局节点/状态参数/任务/事件槽）
       ├─ FStateTreeExecutionState ExecutionState            ← 活动帧树 + 运行状态
       ├─ UE::StateTree::InstanceData::FInstanceContainer ExecutionRuntimeData
       ├─ TArray<FStateTreeTemporaryInstanceData> TemporaryInstances
       ├─ TSharedRef<FStateTreeEventQueue> EventQueue
       └─ …（逐字段见 §4）
```

- 设计动机（头文件注释，StateTreeInstanceData.h L146-155）：包一层 Storage 让 `FStateTreeInstanceData` 保持 bitwise relocatable（可放进数组/UPROPERTY），同时允许委托绑定到单个任务的实例数据；数组扩容会搬移元素，不能存裸指针，跨生命周期引用必须用 `TStateTreeInstanceDataStructRef`。
- UObject 型实例数据统一用 `FStateTreeInstanceObjectWrapper`（StateTreeInstanceContainer.h L11-24，唯一字段 `TObjectPtr<UObject> InstanceObject`）混入结构体数组；`IsObject(Index)` 用 `GetScriptStruct() == TBaseStructure<FStateTreeInstanceObjectWrapper>::Get()` 判别【源码】。

三种容器职责划分【源码】：

| 容器 | 定义位置 | 内存所有权 | 用途 |
|---|---|---|---|
| `FInstancedStructContainer` | StructUtils 模块 | 自持有 | `InstanceStructs` 主缓冲；支持按 UPROPERTY 序列化与 GC 结构引用 |
| `UE::StateTree::InstanceData::FInstanceContainer` | StateTreeInstanceContainer.h L26-138 | 自持有（内部即 `FInstancedStructContainer`） | StateTree 薄包装（`Init/Append/GetStruct/GetObject/AreAllInstancesValid/GetAllocatedMemory` + 迭代器）；用于 `ExecutionRuntimeData` 与 `UStateTree::DefaultEvaluationScopeInstanceData`/`DefaultExecutionRuntimeData` 默认值 |
| `UE::StateTree::InstanceData::FEvaluationScopeInstanceContainer` | StateTreeEvaluationScopeInstanceContainer.h L16-123 | **不拥有内存**（外部/栈提供一块连续内存） | 评估作用域临时容器：构造时写入、析构/Reset 按需 `DestroyStruct`；move-only（拷贝已删除） |

## 3. FStateTreeInstanceData（对外句柄）

定义：StateTreeInstanceData.h L457-646（USTRUCT）。

拷贝/移动语义【源码，StateTreeInstanceData.cpp L854-876】：

- 拷贝 = `MakeShared<FStateTreeInstanceStorage>(*Other.InstanceStorage)`（**深拷贝全部字段**，含事件队列；PIE duplicate 即触发，wrapper UObject 按 `bDuplicateWrappedObject || 外层不同` 决定 DuplicateObject）。
- 移动 = 接管 TSharedRef，来源换成新空 Storage。

关键 API【源码】：

| API | 语义 |
|---|---|
| `Init(UObject&, TConstArrayView<FInstancedStruct\|FConstStructView>, FAddArgs)` / `Append(...)` / `ShrinkTo(int32)` / `Reset()` | 布局构建；`Append` 有 move 变体（`TConstArrayView<FInstancedStruct*>` 与 `TOptional<FInstancedStruct*>` 版，后者把临时实例 Memswap 进正式缓冲） |
| `CopyFrom(UObject&, const FStateTreeInstanceData&)` | 拷结构 + 复制 UObject 包装 |
| `Num/IsValidIndex/IsObject/GetStruct/GetMutableStruct/GetObject/GetMutableObject` | 结构访问转发 Storage |
| `GetExecutionState()/GetMutableExecutionState()` | 执行状态访问 |
| `GetMutableStorage()/GetStorage()`；`GetWeakMutableStorage()/GetWeakStorage()` | 强引用 / `TWeakPtr` 弱引用（供 StructRef 长引用） |
| `GetEstimatedMemoryUsage()` | = sizeof(FStateTreeInstanceData) + InstanceStructs 分配（含包装 UObject 类大小）+ ExecutionRuntimeData 分配；**不含** TemporaryInstances/EventQueue/BroadcastedDelegates（StateTreeInstanceData.cpp L948-957） |
| `Identical/Serialize/GetPreloadDependencies/AddStructReferencedObjects/GetRuntimeValidation` | StructOps 支撑（见 §10） |
| 队列/转换/临时实例转发 | `GetMutableEventQueue/GetEventQueue/GetSharedMutableEventQueue/IsOwningEventQueue/SetSharedEventQueue/AddTransitionRequest/GetTransitionRequests/ResetTransitionRequests/AddTemporaryInstance/GetMutableTemporaryStruct/GetMutableTemporaryObject/ResetTemporaryInstances` |
| `struct FAddArgs{ static FAddArgs Default; bool bDuplicateWrappedObject = true; }` | 追加参数：是否复制包装的 UObject |

`TStateTreeInstanceDataStructRef<T>`（StateTreeInstanceData.h L696-834）【源码】：

- 构造：`(TWeakPtr<FStateTreeInstanceStorage>, const FStateTreeExecutionFrame&, FStateTreeDataHandle)`；仅支持四个 InstanceData 源（checkf 拒绝其他源）。
- `GetPtr()→T*`：Pin 弱引用 → `FindActiveFrame(FrameID)` → `GetDataView`（或临时实例）；类型不符 ensure 返回 nullptr。
- **任务异步引用实例数据的官方姿势**：EnterState 中 `[InstanceDataRef = Context.GetInstanceDataStructRef(*this)]` 捕获，回调内 `InstanceDataRef.GetPtr()` 重解析——缓冲重排/移动安全；引用仅在任务生命周期（EnterState→ExitState）内有效（官方示例见 StateTreeInstanceData.h L668-695）。
- 5.6 弃用其 `WeakStateTree/RootState` 字段 → 改用 `FrameID`（见 §12）。

## 4. FStateTreeInstanceStorage 逐字段

定义：StateTreeInstanceData.h L377-447（已逐行核对）。私有字段无 UPROPERTY 的注明。

| # | 字段 | 声明 | 语义 |
|---|---|---|---|
| 1 | `InstanceStructs` | `UPROPERTY() FInstancedStructContainer` | 主实例缓冲。注释明确缓冲格式（L378-387）：对每个 frame 依次为 ① 全局参数（仅全局帧）② 全局节点实例（evaluator、global tasks）③ 活动状态参数 ④ 活动节点实例（tasks）。**非 Transient**：`UStateTree::DefaultInstanceData` 用同一结构落盘存默认值。重排机制见 §5 |
| 2 | `ExecutionState` | `UPROPERTY(Transient) FStateTreeExecutionState` | 执行状态（不序列化）。字段见下表 |
| 3 | `ExecutionRuntimeData` | `UPROPERTY(Transient) UE::StateTree::InstanceData::FInstanceContainer` | 执行运行期节点数据容器；注释（L395-398）："存活到拥有它的执行上下文 Stop"。布局见 §7 |
| 4 | `ExecutionRuntimeDataInfos` | `TArray<FExecutionRuntimeInfo, TInlineAllocator<1>>`（非 UPROPERTY 私有） | `FExecutionRuntimeInfo{FObjectKey StateTree; int32 StartIndex;}`：每棵 StateTree 的运行期数据起始下标 |
| 5 | `TemporaryInstances` | `UPROPERTY(Transient) TArray<FStateTreeTemporaryInstanceData>` | 状态选择期间创建的临时实例；`FStateTreeTemporaryInstanceData{FrameID; DataHandle; OwnerNodeIndex; Instance;}`（L88-122），按 (FrameID, OwnerNodeIndex, DataHandle) 线性查找 |
| 6 | `EventQueue` | `TSharedRef<FStateTreeEventQueue>`（非 UPROPERTY） | 事件队列，**共享所有权**：拷贝 Storage 得自有的新队列（StateTreeInstanceData.cpp L488）；move 接管并把来源替换为新空队列（L507/518）；`SetSharedEventQueue` 改为借用（`bIsOwningEventQueue=false`，L575-579）。`FStateTreeEventQueue` 定容 `MaxActiveEvents=64`（StateTreeEvents.h L181） |
| 7 | `BroadcastedDelegates` | `TArray<FStateTreeDelegateDispatcher>`（非 UPROPERTY） | 已广播委托记录，`AddUnique` 去重（operator== 为 default，StateTreeDelegate.h L40）；注释（StateTreeInstanceData.cpp L595-597）"数组在转换处理完后重置"；`StealBroadcastedDelegates()` MoveTemp 取走 |
| 8 | `TransitionRequests` | `UPROPERTY(Transient) TArray<FStateTreeTransitionRequest>` | 待处理转换请求缓冲，上限 `MaxPendingTransitionRequests=32`，超出**丢弃并 UE_VLOG+UE_LOG 双写报错**（`UE_VLOG_UELOG`，StateTreeInstanceData.cpp L581-592） |
| 9 | `GlobalParameters` | `UPROPERTY(Transient) FInstancedStruct` | 根全局参数快照；`SetGlobalParameters(FConstStructView)` 拷贝存入（L741-744）；`FInstancedPropertyBag` 重载已 5.8 弃用 |
| 10 | `UniqueIdGenerator` | `UPROPERTY(Transient) uint32` | `GenerateUniqueId()` 自增发号（用于 FActiveFrameID/FActiveStateID）；跳过 0 并在回绕时 ensure/log（L746-761） |
| 11 | `AccessDetector` | `UE_MT_DECLARE_MRSW_RECURSIVE_ACCESS_DETECTOR(AccessDetector)` | 多读单写递归访问**探测器**（非锁）；`ENABLE_MT_DETECTOR = DO_CHECK` 门控（MTAccessDetector.h L8/L733/L743-748）。语义见 §9 |
| 12 | `bIsOwningEventQueue` | `bool = true`（非 UPROPERTY） | 事件队列所有权标志；`Reset()` 仅在拥有时清队列（StateTreeInstanceData.cpp L776-779） |
| 13 | `RuntimeValidationData` | `TPimplPtr<UE::StateTree::Debug::FRuntimeValidationInstanceData>`（`WITH_STATETREE_DEBUG`） | 运行时校验数据；`WITH_STATETREE_DEBUG` 定义于 StateTreeTypes.h L19-21：`!(UE_BUILD_SHIPPING \|\| UE_BUILD_SHIPPING_WITH_EDITOR \|\| UE_BUILD_TEST) && 1`（Development/Debug 开、Test/Shipping 关） |

**"ActiveStates" 澄清**【源码，StateTreeExecutionTypes.h L314-320】：它不是 `FStateTreeInstanceStorage` 字段，而在 `ExecutionState.ActiveFrames[].ActiveStates`——`FStateTreeActiveStates` 为定长数组 + StateIDs，深度上限 **`MaxStates=8`**：`SelectStateInternal` 与 `GetStatesListToState` 超限直接失败（StateTreeExecutionContext.cpp L7273-7283）。

`ExecutionState`（`FStateTreeExecutionState`，StateTreeExecutionTypes.h L1121-1289）关键字段：

- `TArray<FStateTreeExecutionFrame> ActiveFrames`：活动帧（含各帧 `ActiveStates`、六个 IndexBase、`FrameID`、`StateParameterDataHandle/GlobalParameterDataHandle`、`bIsGlobalFrame`、`bHaveEntered` 等，L982-1119）。
- `TArray<FStateTreeTransitionDelayedState> DelayedTransitions`：延迟转换队列。
- `FRandomStream RandomStream`；`FStateTreeDelegateActiveListeners DelegateActiveListeners`。
- 私有 `TArray<FScheduledTickRequest> ScheduledTickRequests` + `FStateTreeScheduledTick CachedScheduledTickRequest`。
- `mutable FStateTreeInstanceDebugId InstanceDebugId`（WITH_STATETREE_TRACE）。
- `TInstancedStruct<FStateTreeExecutionExtension> ExecutionExtension`（Transient）：Start 时注入的宿主扩展。
- `EStateTreeRunStatus LastTickStatus/TreeRunStatus/RequestedStop`、`EStateTreeUpdatePhase CurrentPhase`、`uint16 StateChangeCount`、`bool bHasPendingCompletedState`。
- WITH_EDITORONLY_DATA 下另有 7 个弃用字段（FinishedTasks、CompletedFrameIndex、CompletedStateHandle、CurrentExecutionContext、EnterStateFailedFrameIndex/TaskIndex、LastExitedNodeIndex，5.6/5.7 弃用）——弃用明细见下表（归本文件自有，替代体系见 §12 弃用 API 表与 runtime-execution.md §11）。

**ExecutionState 弃用字段明细**（WITH_EDITORONLY_DATA，声明区 StateTreeExecutionTypes.h L1258-1288）【源码】：

| 弃用字段 | 弃用版本 | 说明 / 替代 |
|---|---|---|
| `TArray<UE::StateTree::FFinishedTask> FinishedTasks` | 5.6 | "Replaced with FStateTreeTasksCompletionStatus"（L1260-1262） |
| `FStateTreeIndex16 CompletedFrameIndex` | 5.6 | "Use FinishTask to completed a state."（L1264-1267） |
| `FStateTreeStateHandle CompletedStateHandle` | 5.6 | "Use FinishTask to completed a state."（L1269-1271） |
| `FStateTreeExecutionContext* CurrentExecutionContext` | 5.6 | "CurrentExecutionContext is not needed anymore. Use FrameID and StateID."（L1273-1274） |
| `FStateTreeIndex16 EnterStateFailedFrameIndex` | 5.7 | "Use FStateTreeExecutionFrame::ActiveNodeIndex instead."（L1276-1278） |
| `FStateTreeIndex16 EnterStateFailedTaskIndex` | 5.7 | "Use FStateTreeExecutionFrame::ActiveNodeIndex instead."（L1280-1282） |
| `FStateTreeIndex16 LastExitedNodeIndex` | 5.7 | "Use FStateTreeExecutionFrame::ActiveNodeIndex instead."（L1284-1286） |

（7 个字段均在 `PRAGMA_DISABLE_DEPRECATION_WARNINGS` 包裹的 WITH_EDITORONLY_DATA 块内，随执行状态内存分布、不序列化。）

Storage 拷贝/移动语义【源码，StateTreeInstanceData.cpp L482-573】：拷贝 = 深拷贝全部字段（含 AccessDetector 状态）+ 新自有事件队列；移动 = 全部接管 + 来源重置为新队列与新校验数据。

## 5. InstanceStructs 帧布局与重排算法

布局编写者是执行上下文：`FStateTreeExecutionContext::UpdateInstanceData(const TSharedRef<FSelectStateResult>&)`（StateTreeExecutionContext.cpp L2374-2729）。布局规则（函数头注释 L2376-2383）【源码】：

1. 为帧设置 `GlobalParameterDataHandle / GlobalInstanceIndexBase / ActiveInstanceIndexBase`；
2. 全局帧：追加全局参数与全局节点实例（evaluator/global tasks）；
3. 各状态：追加状态参数（`FCompactStateTreeParameters`；Linked 状态的参数存在父帧、由 `StateParameterIndexBase` 指回父帧，L2588-2599/L2646-2654）；LinkedAsset 帧参数临时取自被链接资产的 `GetDefaultParameters()`（L2621-2636）；
4. 若 `EventDataIndex` 有效则追加一个 `FStateTreeSharedEvent` 槽（StateEvent 数据源载体，L2670-2675）；
5. 追加任务实例；值取自 `UStateTree::DefaultInstanceData.GetStruct(Node.InstanceTemplateIndex)`。

重排策略："Keep 2 buffers"（L2377）——`InstanceStructs`（未变+sustained）与选择期临时缓冲双轨【源码】：

- 先在栈上构造 `TArray<FConstStructView> InstanceStructs`，与现有存储的**公共前缀**逐项校验类型一致（WITH_STATETREE_DEBUG 下 check，L2696-2714）；
- `InstanceData.ShrinkTo(NumCommonInstanceData)` 砍掉非公共尾部；
- `InstanceData.Append(Owner, 新项, 临时项 move 列表)`——`TOptional<FInstancedStruct*>` 版本会把临时实例 **Memswap 移入**正式存储（StateTreeInstanceData.cpp L1179-1219）；
- 被消费的 TemporaryInstances 事后 `RemoveTemporaryInstance`（ExecutionContext L2724-2728）。

UObject 实例复制规则（StateTreeInstanceData.cpp L59-106）：遇到 REINST 旧 BP 类经序列化中转迁移到权威类并警告"请重存资产"；其余按 `bDuplicateWrappedObject || Owner 不同外层` 决定 `DuplicateObject`。

**访问路径**：`UE::StateTree::InstanceData::GetDataView(FStateTreeInstanceStorage&, FStateTreeInstanceStorage* Shared, const FStateTreeExecutionFrame& CurrentFrame, const FStateTreeDataHandle&) → FStateTreeDataView`（[[nodiscard]]，StateTreeInstanceData.cpp L322-426）按 `EStateTreeDataSourceType`（StateTreeTypes.h L328-388，None+19 值共 20 枚举项，口径同 assets-types.md §3.7）分派【源码】：

| 数据源 | 解析方式 |
|---|---|
| Global/Active 实例数据 | 帧的 IndexBase 加偏移 |
| SharedInstanceData | 走传入的共享 Storage（见 §8） |
| ExecutionRuntimeData(Object/Any) | `ExecutionRuntimeIndexBase + Handle.Index`（Any 在运行时判 `IsObject` 分派，L357-369） |
| GlobalParameterData | 根帧 → `GetMutableGlobalParameters()`；否则父帧参数块 |
| StateParameterData/SubtreeParameterData | 参数块解 `FCompactStateTreeParameters::GetMutableValue()`（`Parameters` 直接访问已 5.8 弃用） |
| StateEvent | 解 `FStateTreeSharedEvent` 槽 |
| EvaluationScopeInstanceData(+Object) | **不在此函数**（checkf 未处理）——必须经执行上下文的缓存栈访问（见 §6） |

`GetDataViewOrTemporary`（L428-440）：先查 `IsHandleSourceValid`（L161-246，校验帧已初始化/状态在 ActiveStates/索引有效），失败再查 `TemporaryInstances`（GetTemporaryDataView，L248-316）。

TemporaryInstances 生命周期【源码，StateTreeInstanceData.cpp L652-688】：`AddTemporaryInstance(Owner, Frame, OwnerNodeIndex, DataHandle, NewInstanceData)`——存在同 (FrameID, OwnerNodeIndex, DataHandle) 项则类型不同才覆盖；UObject 包装始终 `bDuplicate=true` 复制。使用场景：状态选择尚未提交时，条件/任务的实例先落临时区；EnterState 后经 `MoveTemporaryToInstance`（ExecutionContext L2731）/Append move 语义并入正式缓冲；选择失败/未激活由 `RemoveTemporaryInstance`（RemoveAtSwap）清理。查找全部为 `FindByPredicate` 线性扫描（数量小的取舍【推断】）。

## 6. 评估作用域内存（Evaluation Scope Memory）

**是什么**：条件（enter/transition）、consideration、property function 的实例数据，若节点实例数据源是 `EvaluationScopeInstanceData(+Object)`（枚举注释："Temporary data constructor, used and destroyed immediately"，StateTreeTypes.h L350-354），则不落 Storage——同一次评估批次内由**同一块临时内存承载多个节点的实例**（评估作用域内跨节点共享缓冲）【源码】。

**编译期**（计算需求并缓存）：

- `FMemoryRequirementBuilder::Add(TNotNull<const UScriptStruct*>)`：`Alignment = max(Struct.MinAlignment, Alignment)`；`Size = Align(Size, StructAlignment) + StructSize + sizeof(DebugStructEndTag)`；记录首个结构对齐；`NumberOfElements++`（StateTreeEvaluationScopeInstanceContainer.cpp L15-34）。
- `Build()`：零元素返回空需求；否则容器表 `sizeof(FItem)*NumberOfElements + sizeof(DebugTableEndTag)`，按首结构对齐对齐后加进 Size（L36-57）。`FItem{FStructView Instance; FStateTreeDataHandle DataHandle;}`（头 L104-108）。
- `FEvaluationScopeMemoryRequirement{int32 Size; int32 Alignment; int32 NumberOfElements; bool HasMemory();}`（StateTreeTypes.h L517-530）。
- 四处缓存【源码，StateTree.cpp】：

| 缓存位置 | 构建点 |
|---|---|
| `FCompactStateTreeState::EnterConditionEvaluationScopeMemoryRequirement`（StateTreeTypes.h L835） | StateTree.cpp L948-963 |
| `FCompactStateTreeState::ConsiderationEvaluationScopeMemoryRequirement`（L838） | StateTree.cpp L964-979 |
| `FCompactStateTransition::ConditionEvaluationScopeMemoryRequirement`（L706） | StateTree.cpp L1006-1022 |
| `UStateTree::PropertyFunctionEvaluationScopeMemoryRequirements`（`TArray<FMemoryRequirement>`，StateTree.h L495-497） | `PatchBindings` StateTree.cpp L1308-1332（按 `CopyBatches` 下标对齐） |

- 默认值来源：`UStateTree::DefaultEvaluationScopeInstanceData`（`FInstanceContainer`，StateTree.h L473-475，getter L153-157），由编译器写入。PropertyFunction 的实例默认值同在此容器，按绑定批次索引取需求——评估语义细节归 property-bindings.md / nodes-builtin.md。

**运行期**（StateTreeExecutionContext.cpp，模式固定）【源码】：

```
void* Mem = FMemory_Alloca_Aligned(Requirement.Size, Requirement.Alignment);
FEvaluationScopeInstanceContainer Container(Mem, Requirement);
PushEvaluationScopeInstanceContainer(Container, Frame);
InitEvaluationScopeInstanceData(Container, StateTree, Begin, End);  // 把 DefaultEvaluationScopeInstanceData.GetStruct(Node.InstanceTemplateIndex) Add 进容器（L241-250）
// …评估…
PopEvaluationScopeInstanceContainer(Container);
```

四处使用：属性绑定批拷贝 `CopyBatchInternal`（L3346-3408）、活动实例条件 `TestAllConditionsOnActiveInstances`/验证版 `TestAllConditionsInternal`（L5045-5181）、Enter 条件（L5195-5266）、utility consideration（L5299-5384）；转换条件调用点 L6057/L6265/L8236。

**容器内存布局**（StateTreeEvaluationScopeInstanceContainer.cpp L71-118）【源码】：

```
[FItem 表 × N][TableEndTag(u32)][struct0][StructEndTag][struct1][StructEndTag]…
```

FItem 表在内存头部，结构体区跟在其后逐个对齐排布；每个结构体**后面预留 4 字节 tag 位**（需求计算时无条件计入）。`Add(DataHandle, Default)`：`InitializeStruct` → 非 `FStateTreeInstanceObjectWrapper` 子类直接 `CopyScriptStruct` 拷默认值；是包装则 `DuplicateObject(Wrapper.InstanceObject, GetTransientPackage())` 后再拷（L96-104）——**评估作用域的 UObject 实例是 TransientPackage 内的复制品**。非 POD/有析构的结构记 `bStructsHaveDestructor`，Reset 时倒序 `DestroyStruct`（L113-116/L120-152）。

调试 tag：`WITH_STATETREE_DEBUG` 时构造写 TableEndTag(0x99AABBCC)、每项写 StructEndTag(0xFFEEDDCC)，Reset 前 `TestDebugTags()` ensure 校验（内存越界哨兵，L167-210）；tag 字节在**所有构建**的需求计算里都计入，仅 Debug 构建写入/校验【源码】。

**跨节点共享的查询机制**：上下文持有 `EvaluationScopeInstanceCaches`（`TArray<FEvaluationScopeDataCache{Container, StateTree}, TInlineAllocator<4>>`，StateTreeExecutionContext.h L1585-1596）；上下文级 `GetDataView/GetDataViewOrTemporary` 遇 `EvaluationScopeInstanceData(+Object)` 源时**从栈顶向下**按 StateTree 匹配、容器内按 DataHandle 线性查 `FItem`（L2790-2800、L3131-3140）；`Push`/`Pop`（L3232-3243）以"容器指针必须匹配栈顶"成对校验。

**访问限制**【源码，StateTreeInstanceData.cpp L442-479】：`DoesRequireExecutionContext(EvaluationScopeInstanceData/Object) == true`、`DoesRequireInstanceStorage(...) == false`——Storage 级 `GetDataView` 无法访问评估作用域数据，必须持完整 `FStateTreeExecutionContext`。

## 7. ExecutionRuntimeData（执行运行期容器）

机制【源码】：

- `FStateTreeInstanceStorage::AddExecutionRuntimeData(TNotNull<UObject*> Owner, UE::StateTree::FExecutionFrameHandle)`（StateTreeInstanceData.cpp L626-650）：按 `FObjectKey(StateTree)` 查 `ExecutionRuntimeDataInfos`，命中直接返回 StartIndex（**同一棵树多帧共享一段**）；未命中则 `ExecutionRuntimeData.Append(Owner, StateTree->GetDefaultExecutionRuntimeData(), FAddArgs())` 追加一整段默认值并记录 StartIndex。
- 帧创建时缓存基址：`InitFrame.ExecutionRuntimeIndexBase = FStateTreeIndex16(Storage.AddExecutionRuntimeData(...))`（StateTreeExecutionContext.cpp L1539、L7002、L7026、L7035、L7671、L7840）。
- 节点访问：`FStateTreeExecutionContext::GetExecutionRuntimeData(const T& Node)`（StateTreeExecutionContext.h L743-749）用节点上的 `typename T::FExecutionRuntimeDataType`（基类默认 `FNoInstanceDataType`，StateTreeNodeBase.h L89）对视图做 `GetMutable<T>`。
- 生命周期：Storage::Reset 清空（StateTreeInstanceData.cpp L773）——"上下文停止即失效"（StateTreeInstanceData.h L395-398 注释）。
- 数据源三兄弟（StateTreeTypes.h L356-363）：`ExecutionRuntimeData` / `ExecutionRuntimeDataObject` / `ExecutionRuntimeDataAny`。

**遗留类型警示**【源码 rg 扫描】：`UE::StateTree::InstanceData::FExecutionRuntimeData`（StateTreeExecutionRuntimeDataTypes.h L17-27，仅"StateTreeKey + Instances 容器"结构）在 StateTreeModule/GameplayStateTreeModule/MassAIBehavior 三个最相关模块内**零引用**——运行时真实结构是 `FExecutionRuntimeInfo` + `FInstanceContainer`（§4 #3/#4）。扩展节点时不要 include/使用它。

## 8. SharedInstanceData（每线程副本）

跨树共享的条件/consideration/function 绑定实例数据【源码】：

- 资产侧 `UStateTree::SharedInstanceData`（`FStateTreeInstanceData`，StateTree.h L481-483）+ `mutable FTransactionallySafeRWLock PerThreadSharedInstanceDataLock` + `mutable TArray<TSharedPtr<FStateTreeInstanceData>> PerThreadSharedInstanceData`（L485-486）。
- `GetSharedInstanceData()`（StateTree.cpp L187-238）：线程索引用原子计数器 + thread_local（函数标 `UE_AUTORTFM_ALWAYS_OPEN`）；读锁查线程副本，未命中升级写锁、按序补建 `FStateTreeInstanceData` 并 `CopyFrom` 资产默认值——**每线程一份独立拷贝**；锁仅保护副本数组，副本内容本身靠 MRSW 探测器约束。
- 数据源 `SharedInstanceData(+Object)`（StateTreeTypes.h L344-348，注释适用对象 "Conditions, considerations and function bindings"）：`FCurrentlyProcessedFrameScope` 进入帧时取当前帧 StateTree 的共享数据并设进 `Context.CurrentlyProcessedSharedInstanceStorage`（StateTreeExecutionContext.cpp L1048-1075）；Storage 级 GetDataView 的 SharedInstanceData 分支直接下标访问（StateTreeInstanceData.cpp L340-345）。
- `ResetLinked()` 时在写锁下清空全部线程副本（StateTree.cpp L634-635）。
- 行为佐证：`FStateTreeTest_SharedInstanceData`（StateTreeTest.cpp:825）——100 实例 × ParallelFor 并行 Start/Tick/Stop：Init 期共享数据不被触碰（GlobalCounter==0）、Start 每实例恰好创建一次（==100）、Tick 不重建（保持 100）【源码，StateTreeTestSuite\Private\StateTreeTest.cpp】。

## 9. 并发约定

**核心结论：实例数据没有真锁，只有"探测器 + 事务安全原语"两层**【源码】：

1. **AccessDetector（MRSW 递归探测器）**：`FMRSWRecursiveAccessDetector`（MTAccessDetector.h L733）——多读单写语义的**调试检测器**，`ENABLE_MT_DETECTOR = DO_CHECK`（L8）：非 Shipping/Test 构建违规并发触发 "Data race detected" ensureMsgf（L696-703）；Shipping 下整组宏展开为空（L743-756）。提供 Acquire/Release Read/Write 四个入口，支持递归。
2. **使用方与访问类别**【源码，StateTreeExecutionContext.cpp / StateTreeAsyncExecutionContext.cpp】：

| 上下文 | 构造/析构 | 访问类别 |
|---|---|---|
| `FStateTreeReadOnlyExecutionContext` | 构造 `Storage.AcquireReadAccess()`，析构 Release（L390-407） | 读——N 个只读上下文可跨线程并存 |
| `FStateTreeMinimalExecutionContext` | 构造 `AcquireWriteAccess()`，析构 Release（L857-872） | 写——独占（SendEvent/StopLogic 等） |
| `TStateTreeStrongExecutionContext<bWithWriteAccess>`（异步路径） | 按模板参数 Acquire Read/Write（StateTreeAsyncExecutionContext.cpp L18-58） | WeakContext 在任意线程 Pin 成 StrongContext 后获得同样保护 |

   即同一 Storage 上：**N 个只读上下文 或 1 个写上下文**，混用即探测器报错【源码语义推断，置信度高】。
3. **AutoRTFM 事务安全**：四个 Acquire/Release 全部 `UE_AUTORTFM_OPEN` + `UE_AUTORTFM_ONABORT` 回滚对称操作（StateTreeInstanceData.cpp L788-835）；源内注释 `#jira SOL-8070`："理想情况应使用事务安全访问探测器，暂以 OPEN/ONABORT 代替"——事务中止时访问计数必须还原，避免探测器状态泄漏【源码】。
4. **`PerThreadSharedInstanceDataLock`（FTransactionallySafeRWLock）**：本范围内**唯一的真锁**，保护 UStateTree per-thread 共享数据副本数组的懒初始化与清空（StateTree.cpp L212/220/634）。
5. **无锁裸访问面**：`FStateTreeInstanceData` 的公开方法（AddTransitionRequest、GetEventQueue、GetMutableStorage 等）**不经过探测器**——探测器只在"通过执行上下文访问"时生效；绕过上下文直接多线程改 Storage，非 Test/Shipping 构建不会报警【源码 + 语义推断】。
6. **运行时校验联动**：上下文构造时 `Storage.GetRuntimeValidation().SetContext(&Owner, &RootStateTree, bWriteAccessAcquired)`（WITH_STATETREE_DEBUG，StateTreeExecutionContext.cpp L397-401/L862-866）。

宿主并发接入约定：只读探测路径构造 `FStateTreeReadOnlyExecutionContext`；需要写（SendEvent/Stop）→ `FStateTreeMinimalExecutionContext`；任意线程异步 → WeakContext + `CreateStrongContext<bWithWriteAccess>`；**不要绕过上下文裸调 Storage 写接口**。

## 10. 序列化与 GC

**实例数据侧**【源码，StateTreeInstanceData.cpp L1037-1068 + StateTreeInstanceData.h L125-144】：

- `FStateTreeInstanceStorageCustomVersion`：GUID `60C4F0DE-8B26-4C34-AA93-72015DFF09CC`（四段 0x60C4F0DE, 0x8B264C34, 0xAA937201, 0x5DFF09CC，StateTreeInstanceData.cpp L19）；仅两版：`BeforeCustomVersionWasAdded=0`、`AddedCustomSerialization=1`；经 `FCustomVersionRegistration GRegisterStateTreeInstanceStorageCustomVersion` 注册（L20）。
- `FStateTreeInstanceData::Serialize` 流程：
  - `Ar.UsingCustomVersion(GUID)`；
  - 旧版数据（CustomVer < AddedCustomSerialization）：WITH_EDITORONLY_DATA 下走 `StaticStruct()->SerializeTaggedProperties` 兼容旧**内联**存储（旧字段 `TInstancedStruct<FStateTreeInstanceStorage> InstanceStorage_DEPRECATED`，头 L638-645），读出后 Move 进 TSharedRef；**非编辑器构建直接换新空 Storage（旧数据丢弃）**；
  - 新版数据：`InstanceStorage = MakeShared<FStateTreeInstanceStorage>()` 后 `FStateTreeInstanceStorage::StaticStruct()->SerializeItem(Ar, &InstanceStorage.Get(), nullptr)`——按 Storage 反射属性序列化（InstanceStructs 非 Transient 落盘；ExecutionState/ExecutionRuntimeData/TemporaryInstances/TransitionRequests/GlobalParameters/UniqueIdGenerator 均 Transient 不落盘）。
- 头文件硬约束（StateTreeInstanceData.h L455）："Serialization is supported only for `FArchive::IsModifyingWeakAndStrongReferences()`"——仅重定向对象引用的场景（资产重存/重实例化），**不是通用存档路径**【源码】。
- StructOps 特征（L655-665）：`WithIdentical / WithAddStructReferencedObjects / WithSerializer / WithGetPreloadDependencies`。`Identical`（StateTreeInstanceData.cpp L959-1030）比较 GlobalParameters + InstanceStructs + UObject 包装内容（PIE 复制场景恒不等）。
- 编辑器本地化注册：`RegisterInstanceDataForLocalization`（WITH_EDITORONLY_DATA，StateTreeInstanceData.cpp L112-134）。

**资产侧**【源码】：

- `UStateTree::Serialize`（StateTree.cpp L594-613）注册**已弃用**的 `FStateTreeCustomVersion` GUID（结构体 `UE_DEPRECATED(all, "Use a stream custom version...")`，StateTree.h L23-81）；仅用于在 `IsModifyingWeakAndStrongReferences` 时重新 Link。"弃用"指该机制不再扩展，非立即移除。
- `FStateTreeCustomVersion` 枚举史（StateTree.h L28-74，资产格式演化记录）：SharedInstanceData → GlobalEvaluators → InstanceDataArrays → IndexTypes → AddedEvents → AddedFoo → TransitionDelay → AddedExternalTransitions → ChangedBindingsRepresentation → AddedTransitionIds → AddedDataHandlesIds → AddedLinkedAssetState → ChangedExternalDataAccess → OverridableParameters → OverridableStateParameters → StoringGlobalParametersInInstanceStorage → AddedBindingToEvents → AddedCheckingParentsPrerequisites → TickParameterBindings。
- 兼容读取点：`FStateTreeStateLink::PostSerialize`（StateTreeTypes.cpp L131-149，`< AddedExternalTransitions` 时 `LinkType = Type_DEPRECATED`）；`FStateTreeReference::PostSerialize`（StateTreeReference.cpp L120-138，`< OverridableParameters` 时全部参数视为可覆写）。

**GC 约定**【源码】：

- 宿主把 `FStateTreeInstanceData` 声明为 UPROPERTY（官方约定，StateTreeInstanceData.h L147-148）保证 GC 正确；若放在普通 USTRUCT 内部，**必须手动调用其 `AddStructReferencedObjects`**（头注释 L452-454：不会自动递归）。
- `FStateTreeInstanceStorage::AddStructReferencedObjects` 额外对 EventQueue 做 `AddPropertyReferencesWithStructARO(TBaseStructure<FStateTreeEventQueue>::Get(), &EventQueue.Get())`（StateTreeInstanceData.cpp L763-767）——事件 payload 里的 UObject 引用因此可达。

## 11. 实例数据类型特征宏（POD 迁移）

**[5.8 变更]** 定义于 StateTreeTypes.h L1349-1388（已逐行核对）；测试侧实际用例见 StateTreeTestSuite\Private\StateTreeTestTypes.h L1164（ZEROED）/ L1228（CONSTRUCTED）【源码】：

| 宏 | 展开效果 | 适用 | 内置示例 |
|---|---|---|---|
| `UE_STATETREE_CONSTRUCTED_TRIVIALLY_COPIED_NO_DESTRUCTOR_INSTANCEDATA(Type)` | `TIsPODType=true` + `TStructOpsTypeTraits{WithNoDestructor=true}` | 有默认成员初始化器（需要构造）、可 memcpy 拷贝、无析构 | `FStateTreeCompareEnumConditionInstanceData`（StateTreeCommonConditions.h L166） |
| `UE_STATETREE_ZEROED_TRIVIALLY_COPIED_NO_DESTRUCTOR_INSTANCEDATA(Type)` | 上述 + `WithZeroConstructor=true` | 整块 memset 0 即可、不能有带参构造 | `FStateTreeCompareIntConditionInstanceData`（StateTreeCommonConditions.h L29） |
| `STATETREE_POD_INSTANCEDATA(Type)` | `UE_DEPRECATED_MACRO(5.8)`，默认映射到 ZEROED 版 | **已弃用，勿再使用**（5.8 起编译期警告） | 引擎内仅剩定义、无使用点（rg 扫描） |

共同约束（头注释 L1351-1355）：不适用于需要非平凡拷贝/移动或析构的类型；`TObjectPtr` 成员在启用 GC 屏障时不可用（明令禁止，注释给出反例 `struct { TObjectPtr<UObject> A; }`）。

收益：`WithZeroConstructor/WithNoDestructor` 让 InstancedStruct 初始化/析构零开销；评估作用域容器的 `bStructsHaveDestructor` 检测（`STRUCT_IsPlainOldData | STRUCT_NoDestructor`）也会跳过销毁（StateTreeEvaluationScopeInstanceContainer.cpp L113-116）。

节点作者步骤：① 定义 `USTRUCT()` 实例数据结构，成员全部 trivially copyable 且无析构需求；② 有默认成员初始化器 → 标 `UE_STATETREE_CONSTRUCTED_...`；全零语义即可 → `UE_STATETREE_ZEROED_...`；③ 不要写 `STATETREE_POD_INSTANCEDATA`。内置条件已全部迁移到新宏（StateTreeCommonConditions.h L29/L76/L123/L166/L213/L259/L298）。

## 12. 弃用 API 单列表

| 弃用 API | 弃用版本 | 替代品 | 证据 |
|---|---|---|---|
| `STATETREE_POD_INSTANCEDATA(Type)` | UE_DEPRECATED_MACRO(5.8) | 两个 `UE_STATETREE_*_TRIVIALLY_COPIED_NO_DESTRUCTOR_INSTANCEDATA` 新宏（默认映射 ZEROED 版） | StateTreeTypes.h L1388 |
| `UE::StateTree::InstanceData::GetDataView(…, const FStateTreeExecutionFrame* ParentFrame, …)` 内联重载 | UE_DEPRECATED(5.8, "Use the version without Parent Frame instead") | 无 ParentFrame 版 | StateTreeInstanceData.h L39-48 |
| `GetDataViewOrTemporary` 带 ParentFrame 重载 | 同上 | 无 ParentFrame 版 | StateTreeInstanceData.h L57-66 |
| `FStateTreeInstanceStorage::SetGlobalParameters(const FInstancedPropertyBag&)` | UE_DEPRECATED(5.8) | `SetGlobalParameters(FConstStructView)` | StateTreeInstanceData.h L338-339 |
| `GetMutableTemporaryStruct/Object(const FStateTreeExecutionFrame&, …)`（Storage 上） | UE_DEPRECATED(5.7) | FrameID 版 | StateTreeInstanceData.h L314-324 |
| `FStateTreeTemporaryInstanceData::StateTree / RootState`（WITH_EDITORONLY_DATA） | UE_DEPRECATED(5.6) | `FrameID` | StateTreeInstanceData.h L113-121 |
| `TStateTreeInstanceDataStructRef::WeakStateTree / RootState`（WITH_EDITORONLY_DATA） | UE_DEPRECATED(5.6) | `FrameID` | StateTreeInstanceData.h L828-833 |
| `FStateTreeInstanceData::InstanceStorage_DEPRECATED`（WITH_EDITORONLY_DATA） | 内联旧存储，仅旧资产兼容路径读取 | TSharedRef `InstanceStorage` | StateTreeInstanceData.h L638-645 |
| `FStateTreeCustomVersion`（整个结构） | UE_DEPRECATED(all, "Use a stream custom version…") | 流式自定义版本（GUID 仍在 Serialize/PostSerialize 中活跃做旧资产兼容） | StateTree.h L23-26 |
| `FCompactStateTreeParameters::Parameters`（直接访问） | UE_DEPRECATED_FORGAME(5.8) | `GetValue()/GetMutableValue()` | StateTreeTypes.h L1080-1083 |

## 13. 注意事项与坑

1. **不要保存实例数据指针**：InstanceStructs 会因状态切换（ShrinkTo+Append）与数组扩容整体搬移；跨帧持有必须用 `TStateTreeInstanceDataStructRef`（StateTreeInstanceData.h L668-674）。
2. **序列化≠存档**：`FStateTreeInstanceData::Serialize` 只服务 `IsModifyingWeakAndStrongReferences` 场景；用它做游戏存档会丢 ExecutionState/TransitionRequests/EventQueue 等全部 Transient 字段（§10）。测试盲区：StateTreeTestSuite 无序列化往返测试（StateTreeTestSuite\Private\ 全模块 rg 扫描）。
3. **事件队列所有权易踩**：拷贝 `FStateTreeInstanceData` 得到的是**独立**新队列；要共享事件必须显式 `SetSharedEventQueue`，且借用方 `Reset()` 不清队列（归队列所有者管）【源码】。
4. **TransitionRequest/Event 队列静默丢弃**：32/64 上限，超限丢弃经 `UE_VLOG_UELOG` = UE_VLOG+UE_LOG 双写报错（StateTreeInstanceData.cpp L587；事件队列溢出同式，StateTreeEvents.cpp L45-49）——高频 SendEvent 的宿主要自查流量【源码】。
5. **评估作用域内存来自栈**：`FMemory_Alloca_Aligned`，需求大小由编译期决定，源码未见上限校验/栈余量保护——极端多条件状态会放大栈占用【推断/风险】。
6. **评估作用域默认值里的 UObject 是 TransientPackage 复制品**：Add 时 `DuplicateObject(..., GetTransientPackage())`，不可跨帧持有其指针【源码，StateTreeEvaluationScopeInstanceContainer.cpp L96-104】。
7. **`GetEstimatedMemoryUsage` 少算三块**：不含 TemporaryInstances、EventQueue、BroadcastedDelegates；做内存预算需自行补【源码，StateTreeInstanceData.cpp L948-957】。
8. **临时实例查找是线性扫描**：Add/Remove/Get 均 `FindByPredicate`；状态选择高频路径上临时项多时会放大（源码事实，性能影响为【推断】）。
9. **Storage 拷贝昂贵**：深拷贝全部字段含事件队列；UPROPERTY 复制（PIE duplicate）即触发——wrapper UObject 按 `bDuplicateWrappedObject || 外层不同` 决定复制。
10. **MRSW 探测器只在 DO_CHECK 构建存在**：Shipping 下无任何并发防护，多线程误用的后果是真实数据竞争而非 ensure（§9）。
11. **Storage 拷贝构造会连 AccessDetector 状态一起拷**（StateTreeInstanceData.cpp L491-493）——语义上把"来源正被读/写"的记录带给了副本，属调试器视角怪点【源码，影响面仅 DO_CHECK 构建，推断】。
12. **普通 struct 嵌 `FStateTreeInstanceData` 不会自动 GC 引用**（§10 GC 约定）。
13. **`bIsOwningEventQueue` 与 `Reset`**：Reset 在借用态不清事件——排查"事件残留"问题先查所有权（§4 #12）。
14. **Storage 拷贝 = 事件队列换新**：并行子树等需要共享同一事件流的场景，共享机制的基础是 `SetSharedEventQueue` + `bIsOwningEventQueue`（佐证：`FStateTreeRunParallelStateTreeTask` 启动时共享主树事件队列，StateTreeRunParallelStateTreeTask.cpp L92；ParallelTreeSendEvents 测试验证跨树路由，StateTreeRunParallelStateTreeTaskTest.cpp:650-696）。

## 14. 开放问题

1. 【未证实】`FStateTreeInstanceStorageCustomVersion::AddedCustomSerialization` 引入的具体引擎版本与历史（本机仅 5.8；两版枚举语义已证实）。
2. 【未证实】`FExecutionRuntimeData` 全引擎引用面——对全 `Engine\Plugins` 的扫描超时未完成；StateTreeModule / GameplayStateTreeModule / MassAIBehavior 三个最相关模块内已证实零引用。
3. 【未证实/假设】`FMemoryRequirementBuilder::Build()` 中 `FirstStructAlignment <= 0`（全部为对象包装时以 `alignof(FItem)` 兜底）分支的实际触发条件；`Reset/TestDebugTags` 跳过 UClass 的防御逻辑暗示对象实例可能以 UClass 为"结构"出现，但与 DefaultEvaluationScopeInstanceData 存储形态的精确对应关系未逐点验证。
4. 【未证实】`AddedCustomSerialization` 之前的旧格式资产在现网的存在面（代码路径证实旧数据在非编辑器构建会被丢弃）。
5. 【推断/风险】评估作用域 alloca 无大小上限或栈余量保护（源码未见校验逻辑；需求规模与状态复杂度成正比，极端场景栈溢出风险未实测）。
6. 【未证实】`UE::StateTree::Debug::FRuntimeValidationInstanceData` 的完整校验规则（WITH_STATETREE_DEBUG 数据集，仅证实挂接点与 `SetContext(Owner, StateTree, bWriteAccessAcquired)` 签名；细节留给调试专题）。
7. 【未证实】多线程并发面：`FStateTreeTest_SharedInstanceData` 仅覆盖共享条件实例数据（ParallelFor 100 实例）；`FStateTreeInstanceStorage` 的 ExecutionState/EventQueue/TransitionRequests 跨线程并发写无测试（StateTreeTestSuite 盲区清单）。

---

**分工边界**：执行流程（Start/Tick/Stop、状态选择、转换）→ `runtime-execution.md`；PropertyFunction 评估语义与内置节点 → `property-bindings.md` / `nodes-builtin.md`；本文件只写数据载体（Storage/容器/内存布局/序列化/并发）。
