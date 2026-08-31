# GameplayStateTreeModule：组件宿主、AI 集成与 BT 桥接

> 版本基线：UE 5.8.0 (Release-5.8, CL 55116800) · 版本标记约定：**[UE 5.x+]**=该版本新增，**[仅 <5.x]**=已移除/旧行为，**[5.8 变更]**=本版变更；现行 API 判定标准=声明无 UE_DEPRECATED 标记。

## TL;DR

- `GameplayStateTreeModule` 是 StateTree 官方 AI/Gameplay 宿主层：2 个组件（`UStateTreeComponent`/`UStateTreeAIComponent`）+ 2 个 Schema + 2 个内置 AI Task（MoveTo/RunEnvQuery）+ 2 个 BT 桥接任务；单向依赖 `StateTreeModule`，另依赖 AIModule/GameplayTasks/NavigationSystem。
- `UStateTreeComponent : UBrainComponent + IGameplayTaskOwnerInterface + IStateTreeSchemaProvider`；Start/Tick/Stop 每次即时构造 `FStateTreeExecutionContext`，`CurrentlyRunningExecContext` + `TGuardValue` 防重入；ScheduledTick 可让组件整帧休眠（2 个进程级 CVar + Schema 三态策略）。
- 归属结论：5.8 源码与官方 API 文档（5.2 起各版本页面）一致，`UStateTreeComponent` 属 `GameplayStateTreeModule`；**不存在"5.8 才迁入"的变迁**。
- Context 链路：组件 virtual `UStateTreeComponent::SetContextRequirements` → `UStateTreeComponentSchema::SetContextRequirements`（static）→ Schema virtual `SetContextData` → `FStateTreeExecutionContext::AreContextDataViewsValid`；外部数据走 `CollectExternalData` 回调（内置支持 WorldSubsystem/ActorComponent/Pawn/AIController/Actor 五族）。
- 完成语义：5.8 **不存在** `RunningStateTreeBehaviorStatus`；实际为 `EStateTreeRunStatus` + `UStateTreeComponent::OnStateTreeRunStatusChanged` + 异步任务 `FinishTask` 缓冲（tick 外调用缓冲到下一次 tick）。
- 引擎内 `OnStateTreeRunStatusChanged` 与 `UBTTask_RunDynamicStateTree::SetDynamicStateTree` 无使用者（四插件扫描范围内，见「开放问题」4）；本模块无自动化测试覆盖（StateTreeTestSuite 不依赖本模块）。

## 目录

1. 模块定位与源码地图
2. UStateTreeComponent 生命周期（宿主运行模型）
3. Context 注入与外部数据链路
4. 模块内 Schema 与 Context 槽
5. 内置 AI Task（全模块仅 2 个）
6. BT 桥接
7. 完成语义与状态通知
8. BP 库与周边
9. 版本敏感点与弃用 API
10. 常见坑
11. 交叉引用与分工边界
12. 开放问题

## 1. 模块定位与源码地图

### 1.1 模块归属与依赖

- 模块根：`E:\UnrealEngine\UE_5.8\Engine\Plugins\Runtime\GameplayStateTree\Source\GameplayStateTreeModule\`；下文 `【源码 文件】` 均相对此根，模块外文件用引擎根相对路径。
- `GameplayStateTree.uplugin`："StateTree for AI/Gameplay Behaviors"，插件级依赖 StateTree 插件。
- Build.cs 9 个 Public 依赖：`AIModule`、`Core`、`CoreUObject`、`Engine`、`GameplayTags`、`GameplayTasks`、`NavigationSystem`、`PropertyBindingUtils`、`StateTreeModule`【源码 `GameplayStateTreeModule.Build.cs` L14-26】。
- 依赖方向单向：本模块 → `StateTreeModule`（运行时核心），反向不存在；无 `WITH_EDITOR` 条件依赖，编译面恒定。

### 1.2 文件→类型地图（全模块 27 个源文件）

| 分组 | 关键类型 | 语义 |
|---|---|---|
| 组件 | `UStateTreeComponent`（h 201 行 / cpp 628 行） | 通用宿主（本文 §2） |
| 组件 | `UStateTreeAIComponent : UStateTreeComponent` | AI 变体，仅 override `GetSchema()` 返回 AI Schema（13 行实现） |
| Schema | `UStateTreeComponentSchema` / `UStateTreeAIComponentSchema` | 组件宿主 Schema（§4） |
| 任务基类 | `FStateTreeAITaskBase` / `FStateTreeAIActionTaskBase` | AI 任务空标记基类（§5.3） |
| 内置任务 | `FStateTreeMoveToTask` / `FStateTreeRunEnvQueryTask` | 内置 AI Task 全部 2 个（§5） |
| 条件基类 | `FStateTreeAIConditionBase` | 空标记条件基类；模块内无内置 AI Condition |
| BT 桥接 | `UBTTask_RunStateTree` / `UBTTask_RunDynamicStateTree` / `GameplayStateTreeBTUtils` | §6 |
| BP 库 | `UGameplayStateTreeBlueprintFunctionLibrary`（ScriptName="GameplayStateTreeLibrary"） | BP 一键 RunStateTree（§8） |
| PropertyFunction | `FStateTreeGetActorLocationPropertyFunction`（Private-only） | Input(AActor)→Output(FVector) |
| 模块接口 | `IGameplayStateTreeModule` / `FGameplayStateTreeModule` | 标准空模块接口 |

### 1.3 `UStateTreeComponent` 模块归属（结论性表述）

- 5.8 源码：类定义于本模块 `Public\Components\StateTreeComponent.h`；StateTree 插件全部源码无该类（仅 `IStateTreeSchemaProvider.h` 注释示例提及）。
- 官方 API 文档：5.2/5.3/5.4/5.5/5.8 各版本页面均为 `API/Plugins/GameplayStateTreeModule(/Components)/UStateTreeComponent`【文档，URL 见调研基座 `~/.agents/tmp/state-tree-research/00-overview.md` §4.3】。
- **准确表述**：`UStateTreeComponent` 属于 GameplayStateTree 插件的 `GameplayStateTreeModule`（不是 `StateTreeModule`）；至少自 UE 5.2 起官方文档即如此归属，5.8 源码与文档一致；**不存在"5.8 才从 StateTreeModule 迁入"的变迁**。5.2 之前归属未证实（见「开放问题」1）。

## 2. UStateTreeComponent 生命周期（宿主运行模型）

### 2.1 三重身份

`UCLASS(MinimalAPI, Blueprintable, ClassGroup = AI, HideCategories = (Activation, Collision), meta = (BlueprintSpawnableComponent))`【源码 `Public\Components\StateTreeComponent.h` L38-39】

| 基类 | 来源 | 带来的能力 |
|---|---|---|
| `UBrainComponent` | AIModule `Engine\Source\Runtime\AIModule\Classes\BrainComponent.h` | `GetAIOwner()`（缓存 `Cast<AAIController>(GetOwner())`，BrainComponent.cpp L257）；AI 逻辑契约 `StartLogic`/`StopLogic`/`PauseLogic`/`ResumeLogic`/`IsRunning`/`IsPaused`/`RestartLogic`/`Cleanup`；Gameplay Debugger 集成位。组件是该契约的完整实现者（基类默认 IsRunning/IsPaused 返回 false、Pause/Cleanup 空实现） |
| `IGameplayTaskOwnerInterface` | GameplayTasks `Engine\Source\Runtime\GameplayTasks\Classes\GameplayTaskOwnerInterface.h` | 作为 GameplayTask 的 Owner 参与任务资源仲裁（§2.5） |
| `IStateTreeSchemaProvider` | StateTreeModule `Public\IStateTreeSchemaProvider.h` | 向编辑器提供 `FStateTreeReference` 属性可用 Schema（要求属性 meta 带 `SchemaCanBeOverriden`，组件的 `StateTreeRef` 正是如此） |

与 BT 互操作：AIController 经 `UBrainComponent* AAIController::GetBrainComponent()` 拿到任意子类；StateTree 组件与 `UBehaviorTreeComponent` 在该接口上可互换（BP 库 `UGameplayStateTreeBlueprintFunctionLibrary::RunStateTree` 即利用此点，§8）。

### 2.2 生命周期时序（全流程）

| 阶段 | 行为要点 |
|---|---|
| 构造【`.cpp` L41-48】 | `bWantsInitializeComponent=true`；`PrimaryComponentTick.bStartWithTickEnabled=false`（默认不 tick，全按需启停）；`bIsRunning=bIsPaused=false`；`bStartLogicAutomatically=true` |
| `InitializeComponent`【L50-59】 | **跳过 `UBrainComponent`**（直接 `UActorComponent::InitializeComponent()`，避免基类副作用）；`bStartLogicAutomatically` 时调 `ValidateStateTreeReference()`（只读上下文验证，失败仅 Error 日志，BeginPlay 重试） |
| `BeginPlay`【L95-103】 | `bStartLogicAutomatically` → `StartLogic()` |
| `StartLogic` / `RestartLogic`【L160-170】 | 均转调 `StartTree()` |
| `StartTree`【L172-213】 | 见下方流程 |
| `TickComponent`【L112-158】 | `!bIsRunning \|\| bIsPaused` → 警告 + DisableTick；引用无效 → `bIsRunning=false` + DisableTick；重入 → Error return；否则"构造 Context → SetContextRequirements → `Context.Tick(DeltaTime)` → `ScheduleTickFrame(Context.GetNextScheduledTick())` → 状态变化广播"；SetContextRequirements 失败 → `ensureMsgf`（"树启动时 context 有效现在却无效"）+ DisableTick |
| `StopLogic(const FString& Reason)`【L215-263】 | `!bIsRunning` → 直接 return；先 `DisableTick()`；引用无效 → `bIsRunning=false` + 警告 return；**重入时复用 `CurrentlyRunningExecContext` 的现有 Context 调 Stop**（注释：树 Stop 延迟到帧末的重入调用之后）；否则新构造 Context + SetContextRequirements + `Context.Stop()`（默认完成状态 `EStateTreeRunStatus::Stopped`）→ 状态变化广播 |
| `Cleanup`【L265-268】 | = `StopLogic(TEXT("Cleanup"))` |
| `PauseLogic(const FString& Reason)`【L270-276】 | `bIsPaused=true` + `DisableTick()`；**不调 Super**（`UBrainComponent::PauseLogic` 空实现） |
| `ResumeLogic(const FString& Reason)`【L278-296】 | 先 `Super::ResumeLogic`（基类可能自动 `RestartLogic`，返回 `EAILogicResuming::RestartedInstead`；否则 `Continue`）；`bIsPaused=false`；`bIsRunning` 时用 `FStateTreeMinimalExecutionContext(GetOwner, StateTree, InstanceData)` 取 `GetNextScheduledTick()` 重排 tick（**轻量只读 + SendEvent 层上下文，不开新执行**）；否则 DisableTick |
| `EndPlay`【L105-110】 | `StopLogic(UEnum::GetValueAsString(EndPlayReason))` |
| `UninitializeComponent`【L77-81】 | 同样跳过 `UBrainComponent` |
| `PostLoad`（WITH_EDITOR）【L61-75】 | 把 5.1 弃用字段 `StateTree_DEPRECATED` 迁移进 `StateTreeRef`（`SetStateTree` + `SyncParameters`） |

**`StartTree` 内部流程**【`.cpp` L172-213；下文 `Context.*` 指 `FStateTreeExecutionContext`】：

1. `HasValidStateTreeReference()` 报错 → `bIsRunning=false` + `DisableTick()` + return；
2. 重入检查：`CurrentlyRunningExecContext` 非空 → Error 日志 return；
3. 构造 `FStateTreeExecutionContext(*GetOwner(), *StateTreeRef.GetStateTree(), InstanceData)` + `TGuardValue` 防重入；
4. `SetContextRequirements(Context, /*bLogErrors*/ true)`（§3.1）；
5. 构造 `FStateTreeComponentExecutionExtension{Component=this}`，以 `TInstancedStruct` 注入 `FStartParameters{ InitialGlobalParameters = StateTreeRef.GetGlobalParameters(), ExecutionExtension = … }`，调 `Context.Start(FStartParameters)` **[5.8 变更]**（旧 `Start(const FInstancedPropertyBag*, int32)` 重载已 UE_DEPRECATED(5.8)，§9）；
6. `bIsRunning = (CurrentRunStatus == EStateTreeRunStatus::Running)` → `ScheduleTickFrame(Context.GetNextScheduledTick())` → 状态变化时 `OnStateTreeRunStatusChanged.Broadcast(CurrentRunStatus)`。

### 2.3 即时构造模型与重入防护

- Start/Tick/Stop **不缓存执行上下文**：每次入口即时构造 `FStateTreeExecutionContext`，用完即弃；重入防护靠 private 成员 `FStateTreeExecutionContext* CurrentlyRunningExecContext`（`StateTreeComponent.h` L196）+ 每次入口 `TGuardValue`：同帧 Start/Tick/Stop 重叠时，Stop 复用正在执行的 Context，Tick/Start 拒绝重入。
- 运行状态双轨：组件 bit 位 `bIsRunning`/`bIsPaused`（调度层）+ `InstanceData.GetExecutionState()->TreeRunStatus`（执行层，`GetStateTreeRunStatus()` 读取；无 ExecutionState 时返回 `Failed`【`.cpp` L595-603】）。**两者可能短暂不一致**（如 `bIsRunning=false` 但 InstanceData 仍记录上次 Stop 前状态）。

### 2.4 ScheduledTick：组件休眠（2 CVar + Schema 三态策略）

`UStateTreeComponent::ScheduleTickFrame(const FStateTreeScheduledTick& NextTick)`【`.cpp` L298-346】，在 `bIsRunning && !bIsPaused` 前提下按序判定：

| 条件 | 动作 |
|---|---|
| CVar `StateTree.Component.ScheduledTickEnabled`（默认 true）关闭 | 强制每帧 tick（`UE::GameplayStateTree::Private::bScheduledTickAllowed`【`.cpp` L19-24】） |
| `NextTick.ShouldSleep()` | `SetComponentTickEnabled(false)`——组件真正休眠 |
| `NextTick.ShouldTickEveryFrames()` | `SetComponentTickIntervalAndCooldown(0.0f)` |
| 其他 | `SetComponentTickIntervalAndCooldown(NextTickDeltaTime)`：`ShouldTickOnceNextFrame()` 时用 `UE_KINDA_SMALL_NUMBER` 提示 TickTaskManager"只下一帧"，否则用 `NextTick.GetTickRate()` |

- 事件唤醒缝合点：`FStateTreeComponentExecutionExtension::ScheduleNextTick(FContextParameters, FNextTickArguments)` **[UE 5.7+]**（`StateTreeComponent.h` L30-36）——树内异步回调（如 `WeakContext.SendEvent`）需唤醒树时，执行扩展调 `Component->ConditionalEnableTick()` → `ScheduleTickFrame(FStateTreeScheduledTick::MakeNextFrame())`。
- Schema 侧闸门：`UStateTreeComponentSchema::IsScheduledTickAllowed()` 按 `ScheduledTickPolicy` 三态：`Default`→CVar `StateTree.Component.DefaultScheduledTickAllowed`（默认 true）、`Allowed`、`Denied`【源码 `Public\Components\StateTreeComponentSchema.h` L18-23/L58-70、`.cpp` L24-28】。

### 2.5 GameplayTask Owner 语义

| API（全名） | 语义 |
|---|---|
| `UStateTreeComponent::GetGameplayTasksComponent(const UGameplayTask&)` | Task 为 `UAITask` 且有 AIController → 委托该 Controller 的 `UGameplayTasksComponent`；否则用 Task 自带【`.cpp` L372-376】 |
| `GetGameplayTaskOwner(const UGameplayTask*)` / `GetGameplayTaskAvatar(const UGameplayTask*)` | AITask → `AITask->GetAIController()` / 其 Pawn；null Task → `GetAIOwner()` / 其 Pawn【L378-408】 |
| `GetGameplayTaskDefaultPriority()` | `EAITaskPriority::AutonomousAI`【L410-413】 |
| `OnGameplayTaskInitialized(UGameplayTask&)` | AITask 缺 AIController（如 BP Construct Object 创建）→ Error 日志【L415-425】 |

注意：`FStateTreeMoveToTask` 内部新建 AITask 用 `EAITaskPriority::High`（§5.1），与组件默认优先级是两层概念。

### 2.6 公开 API 速查

| API（全名） | 语义 |
|---|---|
| `UStateTreeComponent::SetStateTree(UStateTree*)` / `SetStateTreeReference(FStateTreeReference)`（BlueprintCallable） | 换资产/引用（含参数/覆盖项）；**运行中拒绝**（只读上下文查 `TreeRunStatus==Running`），换树需先 `StopLogic` |
| `UStateTreeComponent::SetLinkedStateTreeOverrides(FStateTreeReferenceOverrides)`（**无 UFUNCTION，C++ only**） **[UE 5.6+]** | 整表替换 Linked 树覆盖；逐项校验 Schema 是当前树 Schema 的子类，失败警告 + **整体拒绝**（void 无错误反馈）。⚠ 防混淆注：组件层校验是 `IsChildOf`（放行 Schema 子类，StateTreeComponent.cpp L523-533）；执行上下文层（assets-types.md §5.3）是 `GetClass()==` 严格同类（StateTreeExecutionContext.cpp L1251），两层语义不同 |
| `AddLinkedStateTreeOverrides(FGameplayTag, FStateTreeReference)` / `RemoveLinkedStateTreeOverrides(FGameplayTag)`（BlueprintCallable） | 单项增删（同样 Schema 校验） |
| `SetStartLogicAutomatically(bool)`（BlueprintCallable） | 主要供构造脚本 |
| `SendStateTreeEvent(const FStateTreeEvent&)`（BlueprintCallable）/ `SendStateTreeEvent(FGameplayTag, FConstStructView Payload = {}, FName Origin = {})` | 未运行/引用无效时**丢弃并警告**；否则经 `FStateTreeMinimalExecutionContext::SendEvent` 入队 |
| `GetStateTreeRunStatus()`（BlueprintPure） | 读 `InstanceData.GetExecutionState()->TreeRunStatus`（无则 `Failed`，§2.3） |
| `UStateTreeComponent::OnStateTreeRunStatusChanged`（`FStateTreeRunStatusChanged` 动态多播，BlueprintAssignable） | 见 §7.2 |
| `GetSchema()`（override） | 返回 `UStateTreeComponentSchema::StaticClass()`（`UStateTreeAIComponent` override 为 AI Schema） |
| `GetDebugInfoString()` / `GetActiveStateNames()`（`WITH_GAMEPLAY_DEBUGGER`） | Gameplay Debugger 面板内容；活动状态名（Linked 树可重名，仅调试） |

- 属性：`StateTreeRef`（`FStateTreeReference`，EditAnywhere，meta `Schema="/Script/GameplayStateTreeModule.StateTreeComponentSchema"` + `SchemaCanBeOverriden`）、`LinkedStateTreeOverrides`（同样 Schema meta）、`InstanceData`（Transient `FStateTreeInstanceData`）、`bStartLogicAutomatically=true`、`bIsRunning`/`bIsPaused`（bit 位）。
- protected 扩展面：`ValidateStateTreeReference()`（virtual；注释明示"引用动态后设时 override 且可不调 super"）、`HasValidStateTreeReference() -> TValueOrError<void, FString>`（virtual；三段校验：资产已设 / `UStateTree::IsReadyToRun()` / Schema 是 `UStateTreeComponentSchema` 子类；错误文案分别为 "The State Tree asset is not set." / "The State Tree schema is not ready to run." / "The State Tree schema is not compatible."）、`SetContextRequirements` / `CollectExternalData`（§3）、`StartTree`、`ScheduleTickFrame`、`ConditionalEnableTick`、`DisableTick`。
- `FStateTreeReference`（StateTreeModule `Public\StateTreeReference.h`）：`GetGlobalParameters() -> FConstStructView`（L47）、`GetParameters()`/`GetMutableParameters() -> FInstancedPropertyBag`（L61/L68）；组件 Start 时把 `GetGlobalParameters()` 传入 `FStartParameters::InitialGlobalParameters`。

## 3. Context 注入与外部数据链路

### 3.1 SetContextRequirements 完整链路（组件 virtual → Schema 静态 → SetContextData virtual → 兜底校验）

```
StartTree / TickComponent / StopLogic
  → UStateTreeComponent::SetContextRequirements(Context, bLogErrors)        [virtual, StateTreeComponent.cpp L88-93]
      → Context.SetLinkedStateTreeOverrides(LinkedStateTreeOverrides)
      → Context.SetCollectExternalDataCallback(this, &CollectExternalData)  [注册 FOnCollectStateTreeExternalData]
      → UStateTreeComponentSchema::SetContextRequirements(UBrainComponent&, Context, bLogErrors)  [static, Schema .cpp L160-177]
          → FContextDataSetter(&BrainComponent, Context)
          → GetSchema()->SetContextData(Setter, bLogErrors)                 [virtual，每个 Schema 自定义]
          → Context.AreContextDataViewsValid()                              [兜底校验]
```

- 失败语义：静态入口失败 + `bLogErrors` → 日志 "Missing external data requirements. StateTree will not update."；`StartTree` 中失败 → 树不启动；`TickComponent` 中失败 → `ensureMsgf` + DisableTick。
- `CollectExternalData` 触发时机：执行上下文在 Start/Tick 处理任务与条件的外部数据需求（`FStateTreeExternalDataDesc` 数组）时回调，宿主按 Desc 填 `OutDataViews`，返回 false 视为收集失败。委托声明：`DECLARE_DELEGATE_RetVal_FourParams(bool, FOnCollectStateTreeExternalData, const FStateTreeExecutionContext&, const UStateTree*, TArrayView<const FStateTreeExternalDataDesc>, TArrayView<FStateTreeDataView>)`【源码 StateTreeModule `Public\StateTreeExecutionContext.h` L65】。

### 3.2 内置 CollectExternalData 收集规则

`UStateTreeComponentSchema::CollectExternalData(const FStateTreeExecutionContext&, const UStateTree*, TArrayView<const FStateTreeExternalDataDesc>, TArrayView<FStateTreeDataView>) -> bool`（静态实现，按 `Desc.Struct` 类型分发）【源码 `Private\Components\StateTreeComponentSchema.cpp` L179-245】：

| `Desc.Struct` 是…子类 | 填入 `OutDataViews` 的对象 |
|---|---|
| `UWorldSubsystem` | `World->GetSubsystemBase(StructClass)` |
| `UActorComponent` | `Owner->FindComponentByClass(…)` |
| `APawn` | Owner 是 `AAIController` → `AIOwner->GetPawn()`；否则 `Cast<APawn>(Owner)` |
| `AAIController` | `Cast<AAIController>(Owner)` |
| `AActor`（其余） | Owner 是 `AAIController` → `AIOwner->GetPawn()`；否则 Owner |

缺失计数非 0 → 返回 false。注意 `Context.GetOwner()` 是**组件 Owner Actor**（AIController 场景即 Controller 本身）。

### 3.3 两条互补通道

| 通道 | 声明/校验 | 注入 |
|---|---|---|
| Context 对象（编译期校验） | Schema `GetContextDataDescs()`（§4）+ `IsExternalItemAllowed` | `SetContextData` / `FContextDataSetter::SetContextDataByName` |
| 任务/条件外部数据（运行期收集） | `FStateTreeExternalDataDesc` + `IsExternalItemAllowed` | `CollectExternalData` 回调（§3.2） |

最常用接入路径（零代码）：数据放在 Owner 的 `UActorComponent` 子类或 `WorldSubsystem` 上，树内任务/条件直接把该类型声明为外部数据（`IsExternalItemAllowed` 已放行 Actor/Component/WorldSubsystem 三族）。**自定义宿主组件 / 自定义外部数据接入 / 自定义 Schema 的操作步骤 → [customization-guide.md](customization-guide.md)**（本节只负责链路事实）。

## 4. 模块内 Schema 与 Context 槽

模块内 Schema 全部 2 个，均为 CommonSchema；Context 对象声明载体 **[UE 5.4+]** 为 `UStateTreeSchema::GetContextDataDescs()`（`TConstArrayView<FStateTreeExternalDataDesc>`，基类声明于 StateTreeModule `Public\StateTreeSchema.h` L79；组件 Schema 用 `ContextDataDescs` 数组字段实现）——5.4 起从单 Actor Desc 扩为多 Desc 数组，自定义 Context 对象成为一等公民。

### 4.1 UStateTreeComponentSchema

（`Public\Components\StateTreeComponentSchema.h`，DisplayName="StateTree Component"）

| 成员 | 语义 |
|---|---|
| 构造函数 | `ContextActorClass=AActor::StaticClass()`；`ContextDataDescs = { {Name="Actor", Struct=AActor, GUID=0x1D971B00-28884FDE-B5436802-36984FD5} }`【源码 `.cpp` L31-35】 |
| `SetContextData(FContextDataSetter&, bool bLogErrors)`（virtual） | Context Actor 解析优先级：① `BrainComponent->GetAIOwner()`（或 Owner 本身是 AAIController）且 `IsA(ContextActorClass)` → 用 Controller；② 否则 `AIOwner->GetPawn()` / `GetOwner()` 且 IsA → 用 Pawn/Actor；③ 找不到 + bLogErrors → Error "Could not find context actor of type %s. StateTree will not update."；最后 `SetContextDataByName("Actor", ContextActor)`【`.cpp` L121-158】 |
| `FContextDataSetter`（protected nested） | 封装 `(BrainComponent, Context)`：`SetContextDataByName(FName, FStateTreeDataView)`、`GetStateTree()`、`GetSchema()`——**子类 Schema 定制 Context 注入的官方钩子** |
| `IsStructAllowed` | 放行 5 个 CommonBase 族子结构：Condition/Evaluator/Task/Consideration/PropertyFunction CommonBase【`.cpp` L37-44】 |
| `IsClassAllowed` | `IsChildOfBlueprintBase(InClass)`（放行 BP 基类族）【`.cpp` L46-49】 |
| `IsExternalItemAllowed` | 放行 `AActor`/`UActorComponent`/`UWorldSubsystem` 子类【`.cpp` L51-56】 |
| `IsScheduledTickAllowed` | 三态策略（§2.4） |
| `ContextActorClass` / `ScheduledTickPolicy` | EditAnywhere/NoClear：期望 Owner Actor 类；`EStateTreeComponentSchemaScheduledTickPolicy{Default, Allowed, Denied}` |
| `PostLoad` / `PostEditChangeChainProperty` | 同步 `ContextDataDescs[0].Struct = ContextActorClass`（资产加载与编辑器改动两个入口） |
| `GetContextActorDataDesc()` | 返回 `ContextDataDescs[0]`（5.4 弃用字段的等价访问器，§9） |

### 4.2 UStateTreeAIComponentSchema

（`Public\Components\StateTreeAIComponentSchema.h`，DisplayName="StateTree AI Component"）

| 成员 | 语义 |
|---|---|
| 构造函数 | `AIControllerClass=AAIController::StaticClass()`；check `ContextDataDescs[0]` 为 Actor；**把 `ContextActorClass` 改为 `APawn`**（注释："Make the Actor a pawn by default so it binds to the controlled pawn instead of the AIController"）→ `ContextDataDescs[0].Struct=APawn`；追加 `ContextDataDescs[1] = {Name="AIController", Struct=AAIController, GUID=0xEDB3CD97-95F94E0A-BD15207B-98645CDC}`【源码 `.cpp` L19-27】 |
| `AIControllerClass` | EditAnywhere/NoClear（protected） |
| `PostLoad` / `PostEditChangeChainProperty` | 同步 `ContextDataDescs[1].Struct = AIControllerClass` |
| `IsStructAllowed` | Super + `FStateTreeAITaskBase` + `FStateTreeAIConditionBase` 子类放行——**AI Task/Condition 只在 AI Schema 下可选**【`.cpp` L35-40】 |
| `SetContextData` | 先 `SetContextDataByName("AIController", BrainComponent->GetAIOwner())`，再 `Super::SetContextData`（"Actor"→受控 Pawn）【`.cpp` L42-48】 |

槽位速记：AI Schema 下 "Actor" 槽 = 受控 Pawn、"AIController" 槽 = AIController；Component Schema 下 "Actor" 槽在 Owner 为 AIController 且 `IsA(ContextActorClass)` 通过时优先返回 Controller 自身，否则 Pawn/Owner。

### 4.3 Context 槽 GUID 稳定性

- `FStateTreeExternalDataDesc{FName Name, const UStruct* Struct, FGuid ID(editor-only)}`【源码 StateTreeModule `Public\StateTreeExecutionTypes.h` L177-190】；GUID 是 Context 槽的稳定标识（编译产物按它索引），**一旦发布不可更改**；两个内置 Schema 均使用固定常量 GUID（上表）。
- GUID 跨版本稳定性本身未与旧版源码比对（见「开放问题」2）。另一构造 `FStateTreeExternalDataDesc(UStruct*, EStateTreeExternalDataRequirement)` 用于任务/条件侧外部数据描述（Requirement={Required, Optional}）。

## 5. 内置 AI Task（全模块仅 2 个）

内置任务完整清单 = `FStateTreeMoveToTask` + `FStateTreeRunEnvQueryTask`；**不存在 RunBehaviorTree 方向的内置任务**——BT↔StateTree 桥接只有"BT 节点内跑 StateTree"一个方向（§6）。

### 5.1 FStateTreeMoveToTask（"Move To"，Category="AI|Action"）

继承 `FStateTreeAIActionTaskBase`；依赖 AIModule（`UAITask_MoveTo`、`FAIMoveRequest`、`UAITask::NewAITask`、`PathFollowingComponent`、`EAITaskPriority`）、NavigationSystem（`UNavigationQueryFilter`）、GameplayTasks。

实例数据 `FStateTreeMoveToTaskInstanceData`（`Public\Tasks\StateTreeMoveToTask.h` L22-81）：
- Context：`AIController`（TObjectPtr，可绑定）；
- 参数：`Destination`(FVector)、`TargetActor`(TObjectPtr)、`AcceptableRadius`（默认 `GET_AI_CONFIG_VAR(AcceptanceRadius)`）、`DestinationMoveTolerance=0`（<AcceptableRadius 推荐）、`FilterClass`（None→Controller 默认 filter）、`bAllowStrafe`/`bAllowPartialPath`（AIConfig）、`bTrackMovingGoal=true`、`bRequireNavigableEndLocation=true`、`bProjectGoalLocation=true`、`bReachTestIncludesAgentRadius`/`bReachTestIncludesGoalRadius`（AIConfig bFinishMoveOnGoalOverlap）；
- Transient：`MoveToTask`（`UAITask_MoveTo*`）、`TaskOwner`（`TScriptInterface<IGameplayTaskOwnerInterface>`）。

行为（`Private\Tasks\StateTreeMoveToTask.cpp`）：
- Tick 启用条件（编译期 `Compile()` 写入 `bSavedShouldCallTick`，`Link()` 恢复，非保存字段）：仅"Destination 有绑定 +（bTrackMovingGoal 或其绑定）+ 无 TargetActor 及其绑定"才开 Tick【L16-29/L167-185】。
- `EnterState`【L31-47】：无 AIController → Failed（VLOG Error）；`TaskOwner` = Controller 上 `FindComponentByInterface(UGameplayTaskOwnerInterface)`，否则 Controller 自身；转 `PerformMoveTask`。
- `Tick`【L49-68】（仅追踪场景）：无 TargetActor 且 bTrackMovingGoal 时，当前目的地与绑定 Destination 距离平方 > `DestinationMoveTolerance²` → 重发 `PerformMoveTask`；否则 Running；无 MoveToTask → Failed。
- `ExitState`【L70-81】：MoveToTask 未 Finished → `ExternalCancel()`；随后 `MoveToTask=nullptr`（@todo：重入状态实例数据保留问题）。
- 定制点（均 virtual）：`PrepareMoveToTask`【L83-93】（复用 ExistingTask 或 `UAITask::NewAITask<UAITask_MoveTo>(Controller, *TaskOwner, EAITaskPriority::High)` → `SetUp`）；`PerformMoveTask`【L95-164】（组装 `FAIMoveRequest`：filter/partial path/radius/strafe/reach test/navigable end/project goal/use pathfinding=true；TargetActor 有值且 bTrackMovingGoal → `SetGoalActor`（`UAITask_MoveTo` 内建追踪）否则取当前位置；无 TargetActor 用 Destination；已激活 → `ConditionalPerformMove()`，否则 `ReadyForActivation()`）。
- 异步完成：`OnMoveTaskFinished` lambda → `WeakContext.FinishTask(Succeeded/Failed)`；瞬间完成时直接返回 Succeeded/Failed（见坑 7）【L143-148】。

### 5.2 FStateTreeRunEnvQueryTask（"Run Env Query"，**Category="Common"**）

继承 `FStateTreeTaskCommonBase`——**不是 AI Task 族**；依赖 AIModule EQS（`UEnvQuery`、`FEnvQueryRequest`、`UEnvQueryManager`、`EEnvQueryRunMode`、`FAIDynamicParam`）。

实例数据（`Public\Tasks\StateTreeRunEnvQueryTask.h` L13-39）：`Result`（`FStateTreePropertyRef`，meta `RefType="/Script/CoreUObject.Vector, /Script/Engine.Actor", CanRefToArray`——结果写回外部绑定参数）、`QueryOwner`(AActor)、`QueryTemplate`(UEnvQuery)、`QueryConfig`（`FAIDynamicParam[]`，EditFixedSize）、`RunMode`（默认 `EEnvQueryRunMode::SingleResult`）、`RequestId=INDEX_NONE`。

行为（`Private\Tasks\StateTreeRunEnvQueryTask.cpp` L21-86）：
- `EnterState`：无模板 → Failed；`FEnvQueryRequest(Template, QueryOwner)` + 逐个 `SetDynamicParam` + `Execute(RunMode, lambda)`；lambda：`WeakContext.MakeStrongExecutionContext()` → 按绑定类型写回（`FVector*`→`GetItemAsLocation(0)`；`AActor**`→`GetItemAsActor(0)`；`TArray<FVector>`→`GetAllAsLocations`；`TArray<AActor*>`→`GetAllAsActors`）→ `StrongContext.FinishTask(Succeeded/Failed)`；返回 RequestId 有效 ? Running : Failed。
- `ExitState`：RequestId 有效 → `UEnvQueryManager::GetCurrent(Owner)->AbortQuery(RequestId)`。
- 数组写回：RunMode 选 All 类枚举时写回数组类型，`Result` PropertyRef 需绑定数组参数（CanRefToArray）；单结果枚举取 item 0。
- 推荐拓扑（头文件注释 L41-47）：任务与结果使用者放在同一父状态下的兄弟状态，结果存父状态参数（Parent 持 EQS 结果参数 → 子状态 Run Env Query / Use Query Result）。

### 5.3 AI 节点基类：空标记类

| 基类 | 继承 | 说明 |
|---|---|---|
| `FStateTreeAITaskBase` | `FStateTreeTaskBase` | meta Hidden, Category="AI"；"期望运行在 AIController 或派生类上的 AI 任务"；无新增成员/虚函数 |
| `FStateTreeAIActionTaskBase` | `FStateTreeAITaskBase` | meta Hidden, Category="AI\|Action"；"做物理动作的 AI 任务" |
| `FStateTreeAIConditionBase` | `FStateTreeConditionBase` | meta Hidden, Category="AI"；**5.8 模块内无任何内置实现** |

## 6. BT 桥接

两个任务，NodeName 分别为 "Run State Tree" / "Run Dynamic State Tree"；均 `bCreateNodeInstance=true`、`bTickIntervals=true`。

### 6.1 差异表

| 维度 | `UBTTask_RunStateTree` | `UBTTask_RunDynamicStateTree` |
|---|---|---|
| 树来源 | 编辑器配 `StateTreeRef`（BP/编辑器可选树） | 运行时 `SetDynamicStateTree` 注入（`StateTreeRef`/`InstanceData` 均 Transient） |
| Context 数据 | `UStateTreeAIComponentSchema::SetContextRequirements` 自动收集（AIController/Pawn/Actor/组件/子系统）+ `CollectExternalData` 回调 | 完全交给注入方 `FSetContextDataDelegate`（自由注入任意 Context） |
| Schema 校验 | 有（AIComponentSchema 静态入口） | 无（**无 IStateTreeSchemaProvider**） |
| 默认刷新 | `Interval=0.01f`（ClampMin 0.001） | `Interval=1.f` |
| 运行中换树 | 不支持（StateTreeRef 非 Transient，运行时改需 StopLogic） | 支持（`SetStateTreeToRun` 先 Stop 旧树再换） |
| 典型用途 | BT 某分支"内嵌一段 StateTree 行为" | "行为注入"：外部系统按 `InjectionTag` 替换 BT 内占位任务的树 |

### 6.2 UBTTask_RunStateTree

- `UBTTaskNode + IStateTreeSchemaProvider`；配置：`StateTreeRef`（meta `Schema=StateTreeAIComponentSchema, SchemaCanBeOverriden`——**BT 内嵌树用 AI Schema**）+ Transient `InstanceData` + `Interval=0.01f` + `RandomDeviation=0`。
- `ExecuteTask`【`.cpp` L31-50】：引用有效 → 构造 Context → `SetContextRequirements(OwnerComp, Context)`（注册 `CollectExternalData` 回调 + 把 `UBehaviorTreeComponent` 当 BrainComponent 传入 AI Schema 静态入口）→ `Context.Start(StateTreeRef.GetGlobalParameters())`；Running 时缓存 `SchemaActor`（`GetContextDataByName("Actor")`）；返回 `GameplayStateTreeBTUtils::StateTreeRunStatusToBTNodeResult(StartStatus)`。
- `TickTask`【L52-74】：同样重建 Context + SetContextRequirements；`ensureMsgf(SchemaActor == 当前 Actor context)`；`Context.Tick`；非 Running → `FinishLatentTask`；Running → `SetNextTickTime(NodeMemory, Max(0, Interval + FRandRange(-RandomDeviation, RandomDeviation)))`——**BT 自身 interval 节流，不是每帧 tick**。
- `OnTaskFinished`【L76-92】：重建 Context + SetContextRequirements；失败则手动 `SetContextDataByName("Actor", SchemaActor.Get())`（注释：临时修复——Controller 在任务结束前被销毁/GC 导致树无法正常 Stop）；`ensure(AreContextDataViewsValid())` → `Context.Stop()`。
- 扩展点：protected virtual `SetContextRequirements`/`CollectExternalData`（BT 版定制点，默认转发 AIComponentSchema 静态实现）；`GetSchema()` → `UStateTreeAIComponentSchema`。
- 编辑器：`GetAssociatedAsset()` → `StateTreeRef.GetStateTree()`（BT 编辑器跳转）。

### 6.3 UBTTask_RunDynamicStateTree

- **只继承 `UBTTaskNode`，无 SchemaProvider**；`StateTreeRef`/`InstanceData` 均 Transient（不可编辑器配置）；`InjectionTag`（EditAnywhere，供注入匹配）；`FSetContextDataDelegate`（**三参普通委托**：`FStateTreeExecutionContext&, UBehaviorTreeComponent&, FGameplayTag InjectionTag`——只能 C++ 注入）；`Interval=1.f`、`RandomDeviation=0`。
- `static UBTTask_RunDynamicStateTree::SetDynamicStateTree(OwnerComp, InInjectTag, InStateTree, InSetContextDataDelegate, InInterval, InRandomDeviation, UBTCompositeNode* OptionalStartNode=nullptr) -> bool`【`.cpp` L15-51】：遍历 BT 任务（可选从某 composite 子树起）匹配 `Cast<UBTTask_RunDynamicStateTree>` 且 `InjectionTag==InInjectTag` → 对 InstancedNode 调 `SetStateTreeToRun`；VLOG 记录替换；**若被替换任务正是当前 ActiveTask → `OwnerComp.RequestExecution(父节点, instanceIndex, 任务, childIdx, EBTNodeResult::Aborted)` 中止并重启该任务**；返回注入是否成功。
- `ExecuteTask`【L63-74】：引用无效 → Failed；构造 Context → `SetContextDataDelegate.ExecuteIfBound(Context, OwnerComp, InjectionTag)` → `Context.Start(GetGlobalParameters())`。
- `TickTask`【L76-98】：引用无效 → `FinishLatentTask(Failed)`；然后（**疑似缺陷：无 return**）继续构造 Context + delegate → `Context.Tick`；非 Running → FinishLatentTask；Running → SetNextTickTime（同 §6.2 公式）。
  - **疑似缺陷（静态可读，未运行验证）**：无效引用分支缺 `return`，后续仍解引用 `*StateTreeRef.GetStateTree()` 构造 Context（构造参数为 `TNotNull`，预期 ensure 崩溃）。正常流程 `ExecuteTask` 已拦截无效引用，触发窗口窄；派生/极端用法注意。
- `SetStateTreeToRun`【L110-126】：当前树 Running → delegate + `Context.Stop()`；再替换 StateTreeRef/delegate/Interval/RandomDeviation。
- 调试：`GetStaticDescription`（含 InjectionTag）、`DescribeRuntimeValues`（树名/路径/Interval）、`GetAssociatedAsset`（从 RuntimeDescription 用正则 `[\n\r].*state tree path:\s*([^\n\r]*)` 反查 `UStateTree`）【L128-159】。

### 6.4 状态映射

`GameplayStateTreeBTUtils::StateTreeRunStatusToBTNodeResult`（`Public\BehaviorTree\GameplayStateTreeBTUtils.h` + 实现 `.cpp` L10-23）：`EStateTreeRunStatus::Succeeded→EBTNodeResult::Succeeded`；`Running→InProgress`；`Failed/Stopped/其他→Failed`。

## 7. 完成语义与状态通知

### 7.1 5.8 实际完成语义

- **`RunningStateTreeBehaviorStatus` 在 5.8 不存在**（本机限定验证：GameplayStateTree/StateTree/MassAI/GameplayInteractions 四插件 rg 全文无匹配 + Engine\Source 零 StateTree 引用推断）。
- 实际模型：任务返回 `EStateTreeRunStatus`（Running/Succeeded/Failed/…）+ 组件 `OnStateTreeRunStatusChanged` 通知 + 异步任务 `FinishTask` 缓冲：
  - `FStateTreeAsyncExecutionContext::FinishTask`（StateTreeModule `Public\StateTreeAsyncExecutionContext.h` L344-348）：**tick 处理期间调用 → 状态立即完成；tick 外调用 → 请求缓冲，下一次 tick 处理**。MoveTo/EQS 的异步完成都遵守此模型。
  - `FStateTreeWeakExecutionContext` 持 `TWeakObjectPtr` Owner/StateTree/Storage + FrameID/StateID/NodeIndex——树停止后回调安全失效。
  - 事件队列 / Weak/Strong 上下文完整模型 → [events-async.md](events-async.md)。

### 7.2 组件层委托/回调一览（本模块全部）

| 名称 | 类型 | 方向 | 触发时机与语义 |
|---|---|---|---|
| `FStateTreeRunStatusChanged` + `UStateTreeComponent::OnStateTreeRunStatusChanged` | 动态多播，BlueprintAssignable，参数 `EStateTreeRunStatus` | 组件→外部 | `StartTree`/`TickComponent`/`StopLogic` 三处，在 `Context.Start/Tick/Stop` 返回值 ≠ 之前状态时广播；StopLogic 注释明示"广播可能再次启用 tick"（处理器内可再 `StartLogic`，注意同帧 Start/Stop 风暴） |
| `UStateTreeComponent::CollectExternalData`（`FOnCollectStateTreeExternalData` 目标） | 非动态委托 | ExecutionContext→组件 | 每次构造完整 Context（Start/Tick/Stop/SetContextRequirements）时回调收集外部数据（§3.2） |
| `FStateTreeComponentExecutionExtension::ScheduleNextTick` | C++ virtual override | ExecutionContext→组件 | 树内异步请求下一帧唤醒（§2.4） |
| `UAITask_MoveTo::OnMoveTaskFinished` lambda | AIModule 委托 | AITask→任务 lambda | 移动结束；经 `FStateTreeWeakExecutionContext::FinishTask` 报告 Succeeded/Failed |
| EQS `FQueryFinishedSignature` lambda | AIModule 委托 | EQS Manager→任务 lambda | 查询完成；`StrongContext.FinishTask` |
| `UStateTreeComponent::OnGameplayTaskInitialized` | 接口回调 | GameplayTasks→组件 | 任务初始化校验 AIController |
| `GetDebugInfoString()`（`WITH_GAMEPLAY_DEBUGGER`） | 调试接口 | 调试器→组件 | Gameplay Debugger 面板取数（经 `FConstStateTreeExecutionContextView` 只读上下文） |

事件/委托全集（含 StateTreeModule 层事件队列与全部通知点）→ [events-async.md](events-async.md)。

### 7.3 引擎内使用与测试覆盖

- `OnStateTreeRunStatusChanged` 在 GameplayInteractions/MassAI/Avalanche/GameplayCameras 四插件源码中无引用（rg 限定扫描）；`UBTTask_RunDynamicStateTree::SetDynamicStateTree` 同样无调用方；GameplayInteractions 的 StateTree 用法走 StateTreeModule 层（**不经本模块组件层**）——本模块运行时使用者基本只有项目代码与 BP 库。完备性限制见「开放问题」4。
- `StateTreeTestSuite` 不依赖本模块——组件/AI Task/BT 桥接**无官方自动化测试**。其他宿主（MassAI::MassAIBehavior 等）→ [integrations.md](integrations.md)。

## 8. BP 库与周边

`UGameplayStateTreeBlueprintFunctionLibrary::RunStateTree(AActor* Actor, UStateTree* StateTreeAsset) -> bool`（BlueprintCallable，Category="AI"，meta ReturnDisplayName="bSuccess"）【源码 `Private\GameplayStateTreeBlueprintFunctionLibrary.cpp` L13-74】：

1. Actor 为 `AAIController` → `GetBrainComponent()` 转 `UStateTreeComponent`；否则 `GetComponentByClass<UStateTreeComponent>()`；
2. 都没有 → `NewObject<UStateTreeComponent>(Actor)` + `SetStartLogicAutomatically(false)` + `RegisterComponent()`；
3. AIController 时**直接写 `AIController->BrainComponent = StateTreeComponent`**；
4. 组件在跑 → `StopLogic(TEXT("Starting logic with new asset"))`；`SetStateTree` + `SetStartLogicAutomatically(true)`；`HasBegunPlay()` → `StartLogic()`；返回 true。

`FStateTreeGetActorLocationPropertyFunction`（`Private\PropertyFunctions\`，DisplayName="Get Actor Location"，继承 `FStateTreePropertyFunctionCommonBase`）：`Output = Input ? Input->GetActorLocation() : ZeroVector`（Private-only，头文件不对外，项目内不可引用）。

## 9. 版本敏感点与弃用 API

**[5.8 变更]** 组件 `StartTree` 已用 `FStateTreeExecutionContext::Start(FStartParameters{InitialGlobalParameters, ExecutionExtension})` 新形态（`.cpp` L195-199）；旧 `Start(const FInstancedPropertyBag*, int32 RandomSeed=-1)` 重载与 `FStartParameters::GlobalParameters` 字段弃用（StateTreeModule `Public\StateTreeExecutionContext.h` L467/L492-493）。

| API（全名） | 弃用版本 | 替代品 |
|---|---|---|
| `UStateTreeComponent::StateTree_DEPRECATED` | 5.1 | `UStateTreeComponent::StateTreeRef`（`FStateTreeReference`）；`PostLoad` 自动迁移【`StateTreeComponent.h` L166-168、`.cpp` L61-75】 |
| `UStateTreeComponentSchema::ContextActorDataDesc_DEPRECATED` | 5.4 | `UStateTreeComponentSchema::GetContextActorDataDesc()` / `ContextDataDescs`【`StateTreeComponentSchema.h` L92-95】 |
| `FStateTreeExecutionContext::SetLinkedStateTreeOverrides(const FStateTreeReferenceOverrides*)`（指针版） | 5.6 | 按值版 `SetLinkedStateTreeOverrides(FStateTreeReferenceOverrides)`（组件已用新版，`.cpp` L90）【StateTreeExecutionContext.h L348-359】 |
| `FStateTreeExecutionExtension::ScheduleNextTick(const FContextParameters&)`（单参版） | 5.7 | 双参版 `ScheduleNextTick(const FContextParameters&, const FNextTickArguments&)`（组件已用新版）【StateTreeExecutionExtension.h L62-68】 |
| `FStateTreeExecutionContext::Start(const FInstancedPropertyBag*, int32 RandomSeed=-1)` 等旧重载 | 5.8 | `Start(FStartParameters)`（`InitialGlobalParameters` + `ExecutionExtension`） |

模块自身 5.6/5.7/5.8 **无任何新弃用标记**（全模块仅上表前两处 UE_DEPRECATED，rg 扫描证实）——三个版本的破坏性影响全部经核心模块 API 演化传导（组件是跟随者而非推动者）。版本差异总表与升级核对 → [version-deltas.md](version-deltas.md)。

## 10. 常见坑

1. **`UBTTask_RunDynamicStateTree::TickTask` 无效引用分支缺 return**（疑似缺陷，未运行验证）——见 §6.3。
2. **组件 Tick 间隔被调度接管**：`ScheduleTickFrame` 会改写 `SetComponentTickIntervalAndCooldown`（手设 tick interval 被覆盖）；树休眠时组件 tick 整个关闭——依赖组件 tick 的其他逻辑不要挂在 `UStateTreeComponent` 自身上。
3. **`OnStateTreeRunStatusChanged` 在 StopLogic 中广播的时序**：广播时 `bIsRunning` 已为 false；处理器内再 `StartLogic` 允许（注释明示），但避免同帧 Start/Stop 风暴。
4. **`SendStateTreeEvent` 静默丢弃**：未 Start 或引用无效时仅警告，事件不入队——事件驱动设计需保证组件已启动。
5. **`SetStateTree`/`SetStateTreeReference` 运行中拒绝**：换树需先 `StopLogic`（BP 库 `RunStateTree` 已处理：先 Stop 再 Set）。
6. **Linked overrides Schema 校验失败静默拒绝**：`SetLinkedStateTreeOverrides`/`AddLinkedStateTreeOverrides` Schema 不匹配时只警告并放弃（整表替换全部丢弃），返回 void 无错误反馈。
7. **MoveTo 异步完成的两个已知限制（源码 @todo）**：① 重入状态实例数据保留（`ExitState` 置空 `MoveToTask`）；② "temporary task 瞬间完成时 WeakContext 找不到活跃 frame/state"——`PerformMoveTask` L143-148 首查特判直接返回结果。**自定义异步 AI Task 应复制同样的"瞬间完成特判"模式**。
8. **MoveTo 的 Tick 只服务 Destination 追踪**：TargetActor 追踪完全依赖 `UAITask_MoveTo` 内建（`SetGoalActor`）；绑定 Destination 变化但 Tick 未启用（编译期条件不满足，如同时配了 TargetActor）时不会重寻路。
9. **`UBTTask_RunStateTree` 每 tick 重建 Context + 重收集外部数据**：Interval 默认 0.01s（每帧），高成本 `CollectExternalData` 需自缓存；`ensureMsgf(SchemaActor==…)` 要求两次 tick 间 Actor context 稳定。
10. **RunDynamicStateTree 的 delegate 是普通（非动态）委托**：只能 C++ 注入；`bCreateNodeInstance=true` 使 delegate 存于节点实例，BT 资产复制/网络同步场景 InstancedNode 生命周期需自查。
11. **AI Schema 的 "Actor" 槽默认是 Pawn**：绑 Controller 数据用 "AIController" 槽（§4.2）；Component Schema 的 "Actor" 在 Owner 为 AIController 时优先返回 Controller 自身（§4.1）。
12. **CollectExternalData 中 AActor/APawn 类目在 Controller 场景都指向 Pawn**（`AIOwner->GetPawn()` 优先）：要拿"Owner Controller Actor 本身"需自定义收集（§3.2）。
13. **两个 CVar 进程级生效**：`StateTree.Component.ScheduledTickEnabled` / `StateTree.Component.DefaultScheduledTickAllowed` 是全局开关（非 per-instance）；排查"树不 tick/不休眠"先查这两项与 Schema `ScheduledTickPolicy`（§2.4）。
14. **EQS 结果数组写回**：RunMode 选 All 类枚举时写回数组类型，`Result` PropertyRef 需绑定数组参数（CanRefToArray）；单结果枚举取 item 0（§5.2）。
15. **StopLogic 早退**：`!bIsRunning` 直接 return——**从未 Start 的组件调 `StopLogic` 无效果**（不会清理 InstanceData）；EndPlay 依赖正常启动路径。

全局坑索引 → [pitfalls.md](pitfalls.md)。

## 11. 交叉引用与分工边界

| 主题 | 文档 |
|---|---|
| 自定义宿主组件 / 外部数据接入 / 自定义 Schema / 自定义 AI Task 的操作步骤 | [customization-guide.md](customization-guide.md)（本文 §3/§4/§5 是事实基座，步骤在那边） |
| 其他宿主（MassAI::MassAIBehavior、GameplayInteractions 等走 StateTreeModule 层的集成） | [integrations.md](integrations.md) |
| 事件队列 / Weak/Strong 上下文 / 全部通知点 | [events-async.md](events-async.md) |
| 节点基类虚函数契约 / FinishTask 范式细节 | [nodes-builtin.md](nodes-builtin.md) |
| 版本差异与升级核对 | [version-deltas.md](version-deltas.md) |
| 全局坑索引 / 疑似引擎缺陷清单 | [pitfalls.md](pitfalls.md) |

## 开放问题

1. `UStateTreeComponent` 在 5.2 之前（5.0/5.1）的模块归属未证实：本机仅 5.8 源码；文档 5.2 页已挂 GameplayStateTreeModule，但 Epic 是否对旧版本文档回填重组无法排除；需 GitHub UE 源历史验证。
2. 两个 Schema `ContextDataDescs` 固定 GUID 的跨版本稳定性未证实（资产兼容依赖 GUID 不变；本机无法与旧版源码比对）。
3. §6.3 `UBTTask_RunDynamicStateTree::TickTask` 缺 `return` 的实际可触发性未运行验证（Ensure/TNotNull 断言行为依赖构建配置）。
4. "引擎内 `OnStateTreeRunStatusChanged` 使用者为 0"的完备性未证实：仅扫描 GameplayInteractions/MassAI/Avalanche/GameplayCameras 四插件，其余插件（如 UAFStateTree、StateTreeToolset）未扫描（全量 rg 超时）。
5. `FStateTreeMoveToTask::Tick` 中 `bTrackMovingGoal && !TargetActor` 的语义组合（绑定 Destination 变位才重寻路）与属性注释一致【推断】；边角（`DestinationMoveTolerance=0` 时每 tick 重发）未运行验证。
6. BT 桥接经 `UBehaviorTreeComponent` 传入 `UStateTreeAIComponentSchema::SetContextRequirements(UBrainComponent&, …)` 时 `GetAIOwner()` 生效前提是 Owner 为 `AAIController`（`BrainComponent::AIOwner=Cast(GetOwner())`）——BT 挂在 Pawn 而非 Controller 上时 "AIController" Context 槽为 null【推断，未运行验证】。
7. §7.1 "RunningStateTreeBehaviorStatus 不存在" 为本机限定验证（四插件 rg 无匹配 + Engine\Source 零 StateTree 引用推断），非全引擎证明。
