# UE 5.8 StateTree 自定义扩展路线图（customization-guide）

> 版本基线：UE 5.8.0 (Release-5.8, CL 55116800) · 版本标记约定：**[UE 5.x+]**=该版本新增，**[仅 <5.x]**=已移除/旧行为，**[5.8 变更]**=本版变更；现行 API 判定标准=声明无 UE_DEPRECATED 标记。

## TL;DR

- 本文是「想自定义 X」的入口枢纽：12 类扩展各给 何时用 / 步骤 / 现行 API 锚点 / 详见；机制细节不在此复制，一律跳目标文档。
- 节点五族（Task / Condition / Consideration / Evaluator / PropertyFunction）C++ 零注册可用（编辑器反射扫描五个基类 StaticStruct）；Blueprint 走 `UStateTree*BlueprintBase`。
- Blueprint Task 现行范式 = 无返回值事件 `ReceiveLatentEnterState`/`ReceiveLatentTick` + `FinishTask` 节点；异步完成走 `FStateTreeWeakExecutionContext`（带返回值的旧事件与 `FStateTreePropertyRefExternalHandle` 已弃用，见 §14）。
- `UStateTreeSchema` 决定节点/外部数据白名单、Context 声明与编辑器裁剪；宿主筛选资产靠 meta `Schema` 或 `IStateTreeSchemaProvider`。
- 组件宿主扩展点 = `GetSchema` / `HasValidStateTreeReference` / `SetContextRequirements` / `CollectExternalData`；ContextDataDescs 槽位 GUID 发布后不可更改。
- 外部数据三路线：复用内置收集（零代码）/ override `CollectExternalData` / 新 Context 对象（§9）。
- Parameters 走 `FStateTreeReference::GetGlobalParameters` → `FStartParameters::InitialGlobalParameters`；PropertyRef 异步取值用 `MakeStrongExecutionContext`（§10）。
- 编辑器定制入口：`RegisterCustomPropertyTypeLayout` / `SetDetailPropertyHandlers` / `UStateTreeEditorDataExtension` / `RegisterEditorSchemaClass`（§11）。

源码根缩写（下文【源码:…】以其为前缀）：`ST` = `E:\UnrealEngine\UE_5.8\Engine\Plugins\Runtime\StateTree\Source\StateTreeModule`；`GST` = `E:\UnrealEngine\UE_5.8\Engine\Plugins\Runtime\GameplayStateTree\Source\GameplayStateTreeModule`；`STE` = `E:\UnrealEngine\UE_5.8\Engine\Plugins\Runtime\StateTree\Source\StateTreeEditorModule`。

## 目录

1. 通用前置（节点五族共享）
2. 自定义 Task（C++ / Blueprint 双路径）
3. 自定义 Condition
4. 自定义 Consideration
5. 自定义 Evaluator（含 GlobalTask 对照）
6. 自定义 PropertyFunction
7. 自定义 Schema（白名单 / Context 声明 / UI 裁剪）
8. 自定义 Component 宿主
9. 自定义外部数据（三路线）
10. Parameters 与 PropertyRef 使用要点
11. 编辑器定制
12. Trace / 调试扩展
13. 自定义宿主（三路线取舍）
14. 弃用 API 速查（自定义相关）
15. 开放问题

## 1. 通用前置（节点五族共享）

1. 模块依赖：项目 Build.cs 加 `StateTreeModule`；用组件宿主/AI 任务再加 `GameplayStateTreeModule`。
2. 节点 = `USTRUCT()`，继承领域基类或其 `FStateTree*CommonBase`（CommonBase 是 Schema 默认放行的「通用无状态」命名空间，域 Schema 惯例只放行它 + 域基类）。
3. 实例数据：`using FInstanceDataType = FMyData;` + override `FStateTreeNodeBase::GetInstanceDataType() const → const UStruct*` 返回 `FMyData::StaticStruct()`；实例数据 USTRUCT 用 5.8 现行宏 `UE_STATETREE_ZEROED_TRIVIALLY_COPIED_NO_DESTRUCTOR_INSTANCEDATA(FMyData)` 或 `UE_STATETREE_CONSTRUCTED_TRIVIALLY_COPIED_NO_DESTRUCTOR_INSTANCEDATA(FMyData)`（旧 `STATETREE_POD_INSTANCEDATA` 弃用，见 §14）。
4. 编辑器识别零注册：`FStateTreeNodeClassCache` 在 OnPostEngineInit 以五个节点基类 StaticStruct 为根扫描反射类型【源码:STE\Private\StateTreeEditorModule.cpp L69-83】。
5. 编辑器体验：override `GetDescription(const FGuid&, FStateTreeDataView, const IStateTreeBindingLookup&, EStateTreeNodeFormatting)`（WITH_EDITOR）、`GetIconName() → FName`、`GetIconColor() → FColor`；类 `Category` 元数据决定节点选择器分组。
6. 编译期校验（可选）：override `Compile(UE::StateTree::ICompileNodeContext&) → EDataValidationResult`（WITH_EDITOR）；返回 Invalid 使编译失败。

## 2. 自定义 Task

**何时用**：状态内执行动作/等待/查询/并行子树，需要 Enter→Tick→Exit 完整生命周期与完成语义。

**步骤（C++ 路径）**：

1. `USTRUCT()` 继承 `FStateTreeTaskBase`（【源码:ST\Public\StateTreeTaskBase.h】）；AI 域任务继承 `FStateTreeAITaskBase`/`FStateTreeAIActionTaskBase`（只在 AI Schema 树中可选）。
2. 按 §1 声明实例数据与 `GetInstanceDataType()`。
3. override 现行虚函数：`EnterState(FStateTreeExecutionContext&, const FStateTreeTransitionResult&) const → EStateTreeRunStatus`（Succeeded/Failed 立即结束状态并触发选态，Running 继续）；`Tick(FStateTreeExecutionContext&, const float DeltaTime) const → EStateTreeRunStatus`；`ExitState(FStateTreeExecutionContext&, const FStateTreeTransitionResult&) const`（清理）；可选 `StateCompleted(FStateTreeExecutionContext&, const EStateTreeRunStatus, const FStateTreeActiveStates&) const`、`TriggerTransitions(FStateTreeExecutionContext&) const`。
4. 构造函数设行为位：`bShouldCallTick`（false 同时关 Tick 前绑定复制）、`bShouldCopyBoundPropertiesOnTick`/`bShouldCopyBoundPropertiesOnExitState`、`bShouldAffectTransitions`（TriggerTransitions 参与转换处理的前提）、`bConsideredForScheduling`、`TransitionHandlingPriority`。
5. 异步完成：EnterState/Tick 内存 `FStateTreeWeakExecutionContext WeakContext = Context.MakeWeakExecutionContext()`；异步回调里 `WeakContext.MakeStrongExecutionContext()` → `StrongContext.FinishTask(EStateTreeFinishTaskType::Succeeded/Failed)`；「瞬间完成」需特判（官方范本 MoveTo，【源码:GST\Private\Tasks\StateTreeMoveToTask.cpp L143-164】）。
6. 编译即用（零注册）；官方范例：Delay `ST\Private\Tasks\StateTreeDelayTask.h`、并行树 `ST\Public\Tasks\StateTreeRunParallelStateTreeTask.h`。

**步骤（Blueprint 路径）**：

1. 工具栏 New Task 建 Blueprint 继承 `UStateTreeTaskBlueprintBase`（【源码:ST\Public\Blueprint\StateTreeTaskBlueprintBase.h】；可见性受 Schema `IsClassAllowed` 门控）。
2. 实现无返回值事件 `ReceiveLatentEnterState(const FStateTreeTransitionResult&)` / `ReceiveLatentTick(float)` / `ReceiveExitState(const FStateTreeTransitionResult&)` / `ReceiveStateCompleted(EStateTreeRunStatus, FStateTreeActiveStates)`；完成时调 `FinishTask(bool bSucceeded = true)`——不调用则保持 Running。
3. FinishTask 语义：Tick/EnterState 处理期间调用立即生效；回调中调用自动经 WeakExecutionContext 缓冲到下一次处理；ExitState 自动清蓝图 latent action 与 timer。
4. `bShouldCallTick` 非 UPROPERTY——蓝图任务不可改，需 C++ 派生；带 `EStateTreeRunStatus` 返回值的 `ReceiveEnterState/ReceiveTick` 已弃用（§14）。

**现行 API 锚点**：`FStateTreeTaskBase::EnterState/Tick/ExitState/StateCompleted/TriggerTransitions`（签名同步骤 3）；`UStateTreeTaskBlueprintBase::FinishTask(bool bSucceeded = true)`；`FStateTreeWeakExecutionContext::MakeStrongExecutionContext()`；`UE_STATETREE_ZEROED_TRIVIALLY_COPIED_NO_DESTRUCTOR_INSTANCEDATA(Type)`。

**详见** nodes-builtin.md（虚函数语义表 / 行为位 / 每帧时序）

## 3. 自定义 Condition

**何时用**：进入条件 / 转换条件 / 效用考虑的布尔判定。

**步骤**：

1. `USTRUCT()` 继承 `FStateTreeConditionBase`（【源码:ST\Public\StateTreeConditionBase.h】）+ §1 实例数据。
2. override `TestCondition(FStateTreeExecutionContext&) const → bool`；数值比较用 `UE::StateTree::EComparisonOperator`（**[5.8 变更]** 取代 `EGenericAICheck`）与 `UE::StateTree::Conditions::CompareNumbers<T>(...)`。
3. 可选状态变更事件 `EnterState/ExitState(FStateTreeExecutionContext&, const FStateTreeTransitionResult&) const`、`StateCompleted(FStateTreeExecutionContext&, const EStateTreeRunStatus, const FStateTreeActiveStates&) const`——条件实例数据为该资产全部使用处**共享**，回调内不得修改实例数据。
4. And/Or 组合与括号由 `Operand`/`DeltaIndent` 与表达式栈统一处理，条件自身不实现组合逻辑。
5. Blueprint：继承 `UStateTreeConditionBlueprintBase` 实现 `ReceiveTestCondition()`（返回 bool；未实现 = false）。

**现行 API 锚点**：`FStateTreeConditionBase::TestCondition(FStateTreeExecutionContext&) const`；`UE::StateTree::EComparisonOperator`；`UE::StateTree::Conditions::CompareNumbers<T>`；`UStateTreeConditionBlueprintBase::ReceiveTestCondition()`。

**详见** nodes-builtin.md（表达式求值 / 事件门槛位）

## 4. 自定义 Consideration

**何时用**：状态选择效用评分（**Experimental**：头文件注释明示 API 预期变更）。

**步骤**：

1. `USTRUCT()` 继承 `FStateTreeConsiderationBase`（【源码:ST\Public\StateTreeConsiderationBase.h】）+ §1 实例数据。
2. override `protected virtual float GetScore(FStateTreeExecutionContext&) const`——原始分必须落在 [0,1]（公有 `GetNormalizedScore` = `FMath::Clamp(GetScore(...), 0.f, 1.f)`，勿 override）。
3. 多 consideration 组合经 `Operand`：And→Min、Or→Max、Multiply→a*b（状态选择行为选 Utility 系时生效）。
4. 曲线评分参考 `FStateTreeConsiderationResponseCurve` + `FStateTreeFloatInputConsideration`（【源码:ST\Public\Considerations\StateTreeCommonConsiderations.h】）。
5. Blueprint：继承 `UStateTreeConsiderationBlueprintBase` 实现 `ReceiveGetScore()`（未实现 = 0）。

**现行 API 锚点**：`FStateTreeConsiderationBase::GetScore(FStateTreeExecutionContext&) const`；`FStateTreeConsiderationBase::GetNormalizedScore(FStateTreeExecutionContext&) const`；`EStateTreeExpressionOperand`；`UStateTreeConsiderationBlueprintBase::ReceiveGetScore()`。

**详见** nodes-builtin.md

## 5. 自定义 Evaluator（含 GlobalTask 对照）

**何时用**：树级跨状态数据聚合 / 每帧计算（无完成语义）。

**步骤**：

1. `USTRUCT()` 继承 `FStateTreeEvaluatorBase`（【源码:ST\Public\StateTreeEvaluatorBase.h】）+ §1 实例数据。
2. override `TreeStart(FStateTreeExecutionContext&) const`、`Tick(FStateTreeExecutionContext&, const float DeltaTime) const`（预选期间 DeltaTime=0）、`TreeStop(FStateTreeExecutionContext&) const`。
3. Gameplay Debugger 文本 override `GetDebugInfo(const FStateTreeReadOnlyExecutionContext&) const → FString`（WITH_GAMEPLAY_DEBUGGER；`AppendDebugInfoString` 弃用 5.8，§14）。
4. 与 GlobalTask 区别：两者都挂树根全局区（编译产物 Nodes 切片 Evaluators→GlobalTasks，【源码:ST\Public\StateTree.h】；执行时序 Evaluator=TreeStart/Tick/TreeStop、GlobalTask=Start 时 EnterState + 每帧 Tick，【源码:ST\Private\StateTreeExecutionContext.cpp L4402-4522】）；GlobalTask 有任务完成语义（参与完成判定与 TaskCompletion 绑定），Evaluator 没有。
5. Schema 可用 `AllowEvaluators()` 关闭编辑器分区；Blueprint：`UStateTreeEvaluatorBlueprintBase` + `ReceiveTreeStart()`/`ReceiveTreeStop()`/`ReceiveTick(float)`。

**现行 API 锚点**：`FStateTreeEvaluatorBase::TreeStart/Tick/TreeStop`；`FStateTreeEvaluatorBase::GetDebugInfo(const FStateTreeReadOnlyExecutionContext&) const`；`UStateTreeSchema::AllowEvaluators()`；`UStateTreeEvaluatorBlueprintBase::ReceiveTick(float)`。

**详见** nodes-builtin.md（时序）· references/gameplay-state-tree.md（组件侧全局任务）

## 6. 自定义 PropertyFunction

**何时用**：把「输入属性 → 输出属性」的纯计算做成可绑定节点（在宿主节点绑定求值前执行）。

**步骤**：

1. `USTRUCT()` 继承 `FStateTreePropertyFunctionBase`（【源码:ST\Public\StateTreePropertyFunctionBase.h】）。
2. 实例数据约定：若干 `Category="Input"`（或 Context）属性 + **恰好一个** `Category="Output"` 属性（`GetUsageFromMetaData` 认 Input/Inputs/Output/Outputs/Context 五种；多 Output 违约——编辑器靠单一 Output 定位可用属性；引擎内 Break Transform 双输出是内置例外，勿仿）。
3. override `Execute(FStateTreeExecutionContext&) const → void`：读输入成员 → 写输出成员；函数实例数据存于评估作用域内存（alloca），不进任务实例存储。
4. 约束：含 PropertyFunction 的绑定 batch 在异步上下文不可用（异步场景改用 PropertyRef，§10）；无输出绑定回调。
5. 官方范例：`ST\Private\PropertyFunctions\StateTreeFloatPropertyFunctions.h`、`GST\Private\PropertyFunctions\StateTreeActorPropertyFunctions.h`（头文件在 Private 属布局例外）。

**现行 API 锚点**：`FStateTreePropertyFunctionBase::Execute(FStateTreeExecutionContext&) const`；`EStateTreePropertyUsage`（属性 Usage 元数据）；`UE::StateTree::GetStructSingleOutputProperty`（编辑器单输出判定）。

**详见** property-bindings.md（求值时机 / 评估作用域）· references/nodes-builtin.md（基类契约）

## 7. 自定义 Schema（白名单 / Context 声明 / UI 裁剪）

**何时用**：定义一类资产的可用节点、外部数据与 Context；或裁剪编辑器 UI。

**步骤**：

1. `UCLASS()` 继承 `UStateTreeSchema`（【源码:ST\Public\StateTreeSchema.h】）；组件域直接继承 `UStateTreeComponentSchema`/`UStateTreeAIComponentSchema`（【源码:GST\Public\Components\StateTreeComponentSchema.h】）。
2. 节点白名单：override `IsStructAllowed(const UScriptStruct*)` / `IsClassAllowed(const UClass*)`——惯例只放行域基类 + `FStateTree*CommonBase` 族。
3. 外部数据白名单：override `IsExternalItemAllowed(const UStruct&)`（组件 Schema 放行 AActor/UActorComponent/UWorldSubsystem 三族）。
4. Context 声明：override `GetContextDataDescs()` 返回 `FStateTreeExternalDataDesc{Name, Struct, GUID}` 数组（GUID 稳定性警示见 §8）。
5. 状态形态约束：`IsStateTypeAllowed`/`IsStateSelectionAllowed`/`IsScheduledTickAllowed`；Mass worker 线程场景设 `AllowQueuedCompilation() = false`（Mass/UAF 先例）。
6. 宿主筛选资产二选一：属性 `meta=(Schema="/Script/模块.类")`；或宿主实现 `IStateTreeSchemaProvider::GetSchema()`（纯虚）+ 属性 `meta=(SchemaCanBeOverriden)`（【源码:ST\Public\IStateTreeSchemaProvider.h】）。
7. 编辑器 UI 裁剪：按需 override `AllowEnterConditions`/`AllowUtilityConsiderations`/`AllowEvaluators`/`AllowMultipleTasks`/`AllowGlobalParameters`/`AllowTasksCompletion`；「虚函数 → UI 效果」完整表见 editor.md。

**现行 API 锚点**：`UStateTreeSchema::IsStructAllowed/IsClassAllowed/IsExternalItemAllowed`；`UStateTreeSchema::GetContextDataDescs()`；`IStateTreeSchemaProvider::GetSchema() const`；`UStateTreeSchema::AllowQueuedCompilation()`。

**详见** editor.md（UI 裁剪表）· references/gameplay-state-tree.md（组件 Schema 实例）

## 8. 自定义 Component 宿主

**何时用**：在 Actor 上常驻跑树，且要定制校验、Context 注入、外部数据收集或调度。

**步骤**：

1. `UCLASS()` 继承 `UStateTreeComponent`（【源码:GST\Public\Components\StateTreeComponent.h】；已聚合 `UBrainComponent` + `IGameplayTaskOwnerInterface` + `IStateTreeSchemaProvider`）。
2. override `GetSchema() const → TSubclassOf<UStateTreeSchema>` 返回自定义 Schema（属性 meta 未改时靠 `SchemaCanBeOverriden` 运行时覆盖生效）。
3. 校验：override `HasValidStateTreeReference() → TValueOrError<void, FString>`（先调 Super 再追加检查）；动态换树组件可 override `ValidateStateTreeReference()`。
4. 注入：override `protected virtual bool SetContextRequirements(FStateTreeExecutionContext&, bool bLogErrors)`——保留 `Context.SetLinkedStateTreeOverrides(...)` 与 `Context.SetCollectExternalDataCallback(...)` 再调 Super（基类实现【源码:GST\Private\Components\StateTreeComponent.cpp L88-93】）。
5. 启动参数：`StartTree` 非 virtual；在 StartLogic 前用 `FStateTreeReference::GetMutableParameters()` 设参。
6. ExecutionExtension：组件自带 `FStateTreeComponentExecutionExtension`，其 `ScheduleNextTick(const FContextParameters&, const FNextTickArguments&)` 接 `ConditionalEnableTick()` + `ScheduleTickFrame(...)`（休眠-唤醒缝合点）；自建宿主的四钩子取舍见 integrations.md。
7. **ContextDataDescs GUID 稳定性警示**：Context 槽 GUID 是编译产物索引该槽的稳定标识，**发布后不可更改**；同步时机（`PostLoad`/`PostEditChangeChainProperty`）、内置常量 GUID 与单 Desc 形态 5.4 弃用迁移的细节见 gameplay-state-tree.md §4.3/§9。

**现行 API 锚点**：`UStateTreeComponent::SetContextRequirements(FStateTreeExecutionContext&, bool)`；`UStateTreeComponent::CollectExternalData(...)`；`UStateTreeComponentSchema::SetContextData(FContextDataSetter&, bool)`；`FStateTreeExecutionExtension::ScheduleNextTick(const FContextParameters&, const FNextTickArguments&)`；`FStateTreeExternalDataDesc`。

**详见** gameplay-state-tree.md（生命周期 / 调度 / 重入）

## 9. 自定义外部数据（三路线）

**何时用**：任务/条件需要读宿主侧数据（组件、子系统、任意结构/对象）。

**路线 A——复用内置收集（零代码，首选）**：

1. 数据放 Owner 的 `UActorComponent` 子类、`UWorldSubsystem` 子类或 Actor 上（`UStateTreeComponentSchema::IsExternalItemAllowed` 已放行三族）。
2. 任务/条件实例数据声明 `TStateTreeExternalDataHandle<T> Handle;`，override `Link(FStateTreeLinker&)` 调 `Linker.LinkExternalData(Handle)`；运行时 `FStateTreeExecutionContext::GetExternalData(Handle)`。

**路线 B——override CollectExternalData（自定义 Desc.Struct）**：

1. 继承 `UStateTreeComponent`，override `protected virtual bool CollectExternalData(const FStateTreeExecutionContext&, const UStateTree*, TArrayView<const FStateTreeExternalDataDesc>, TArrayView<FStateTreeDataView>) const`：先调 `UStateTreeComponentSchema::CollectExternalData(...)` 静态版处理内置类型，再对自定义 Desc.Struct 匹配后填 `OutDataViews[i]`；有缺失返回 false。
2. 若同时 override `SetContextRequirements`，必须保留 `SetCollectExternalDataCallback` 注册，否则回调永不触发。

**路线 C——新 Context 对象（编译期校验 + 命名注入）**：

1. Schema `GetContextDataDescs()` 声明槽（GUID 警示同 §8）；override Schema `SetContextData(FContextDataSetter&, bool bLogErrors)`，内部 `Setter.SetContextDataByName("MyContext", FStateTreeDataView(MyObjectPtr))` 后调 Super 保留内置注入。
2. Context 结构若非 Actor/Component/WorldSubsystem 子类，需 `IsExternalItemAllowed` 放行。
3. 通道取舍：Context = Schema 声明 + `AreContextDataViewsValid()` 编译/启动期校验，适合「必须存在」的数据；外部数据 = 节点 Link 声明 + 每次构造上下文按 Desc 运行期收集，适合「节点自选」的数据。

**现行 API 锚点**：`TStateTreeExternalDataHandle<T>` + `FStateTreeLinker::LinkExternalData(...)`；`UStateTreeComponentSchema::CollectExternalData(...)`（static）；`FStateTreeExecutionContext::SetCollectExternalDataCallback(FOnCollectStateTreeExternalData)`；`UStateTreeSchema::SetContextData(FContextDataSetter&, bool)`；`FContextDataSetter::SetContextDataByName(FName, FStateTreeDataView)`。

**详见** gameplay-state-tree.md（收集链路与内置规则表）

## 10. Parameters 与 PropertyRef 使用要点

**何时用**：需要「引用语义」取值（PropertyRef）或宿主级树参数（Parameters）。

**PropertyRef 步骤**：

1. 实例数据声明 `UPROPERTY(EditAnywhere, meta=(RefType="float")) FStateTreePropertyRef Ref;` 或类型安全 `TStateTreePropertyRef<float>`（【源码:ST\Public\StateTreePropertyRef.h】；meta：`RefType` 逗号分隔多类型、struct/object 用完整路径、`IsRefToArray`/`CanRefToArray`、`Optional`）。
2. 同步读（仅限节点处理栈内）：`Ref.GetMutablePtr<T>(Context)`——脱离处理栈的回调禁止使用（内部依赖 GetCurrentlyProcessedFrame）。⚠ **[5.8 变更]** `GetMutablePtrTuple(Context)` 存在 5.8.0 编译死代码坑（业务代码实例化即编译错误），勿用，详见 property-bindings.md。
3. 异步读：EnterState/Tick 内 `FStateTreeWeakExecutionContext WeakContext = Context.MakeWeakExecutionContext()`；回调里 `WeakContext.MakeStrongExecutionContext()` → `Ref.GetPtrTupleFromStrongExecutionContext<T...>(StrongContext)`；官方范本 `FStateTreeRunEnvQueryTask`【源码:GST\Private\Tasks\StateTreeRunEnvQueryTask.cpp L36-70】。
4. 白名单：PropertyRef 不能指向 Context/External 数据；Task/Evaluator/GlobalTask 源须 Output 属性或 PropertyRef 链。

**Parameters 步骤**：

1. 树参数 = `UStateTree::Parameters`（FInstancedPropertyBag）；宿主覆盖经 `FStateTreeReference::GetGlobalParameters()`（组件 StartTree 自动注入 `FStartParameters::InitialGlobalParameters`）。
2. 代码启动：`Context.Start(FStartParameters{.InitialGlobalParameters = Bag.GetValue()})`——bag struct 必须与资产 `UStateTree::GetDefaultParameters().GetPropertyBagStruct()` 一致，否则 ensure 回退默认参数（宿主值被静默丢弃）。
3. **[5.8 变更]** `Start(const FInstancedPropertyBag*, int32)` 与 `SetGlobalParameters(const FInstancedPropertyBag&)` 弃用 → `Start(FStartParameters)` / `SetGlobalParameters(FConstStructView)`（§14）。
4. 外部全局参数（Schema override `GetGlobalParameterDataType() → EStateTreeParameterDataType::ExternalGlobalParameterData`）：宿主构造 `FExternalGlobalParameters` 逐绑定 `Add(CopyInfo, &MyMemory)`，再 `Context.SetExternalGlobalParameters(&Params)`；**linked tree 内禁用（checkf）**。

**自定义绑定拷贝语义扩展点（仿 StructReference 机制）**：

1. 继承 `FPropertyBindingBindingCollection`（或 StateTree 场景扩展 `FStateTreePropertyBindings`），构造函数设 `PropertyReferenceStructType = T::StaticStruct()` + `PropertyReferenceCopyFunc`/`PropertyReferenceResetFunc`（官方示例【源码:ST\Private\StateTreePropertyBindings.cpp L161-178】：目标收到源 struct 的 `FStructView`）。
2. 需要额外判定时覆写虚 `ResolveBindingCopyInfo`（先改 `OutCopyInfo` 再调 Super，同文件 L219-226 模式）。
3. 自定义解析后处理覆写 `OnResolvingPaths()` / `OnReset()`（StateTree 用 `OnResolvingPaths` 把 PropertyReferencePaths 编译为 PropertyAccesses）。
4. 仅「目标 leaf 恰为 `PropertyReferenceStructType` 且方向正向」才路由到自定义 functor（PropertyBindingBindingCollection.cpp L680-697）。

**现行 API 锚点**：`TStateTreePropertyRef<T>`；`FStateTreePropertyRef::GetPtrTupleFromStrongExecutionContext<T...>(...)`；`FStateTreeReference::GetGlobalParameters() → FConstStructView`；`FStartParameters::InitialGlobalParameters`；`FStateTreeExecutionContext::SetExternalGlobalParameters(const FExternalGlobalParameters*)`。

**详见** property-bindings.md（绑定机制 / CopyType / 迁移）

## 11. 编辑器定制

**何时用**：给自定义结构做 Details 定制、在任意 DetailsView 挂绑定 UI、扩展资产级编辑行为。

**步骤**：

1. 属性/类定制（标准 PropertyEditor）：实现 `IPropertyTypeCustomization` / `IDetailCustomization`；自己模块 StartupModule 调 `FPropertyEditorModule::RegisterCustomPropertyTypeLayout("MyStruct", ...)` / `RegisterCustomClassLayout("MyClass", ...)`，ShutdownModule 对称注销（StateTree 自身 12+2 个注册可对照【源码:STE\Private\StateTreeEditorModule.cpp L264-278】）。
2. 绑定 UI：公开静态 `FStateTreeEditorModule::SetDetailPropertyHandlers(IDetailsView&)`（【源码:STE\Public\StateTreeEditorModule.h L57-58】）——把 `FStateTreeBindingExtension` 挂到任意 DetailsView；**每个 DetailsView 需单独调用**（嵌套内层不自动继承）。复用范本：Avalanche `SAvaTransitionSelectionDetails.cpp`。
3. 资产级 Details 注入：派生 `UStateTreeEditorDataExtension`（Within=StateTreeEditorData），override `CustomizeDetails(UStateTreeState*, IDetailLayoutBuilder&)`，经 `UStateTreeEditorData::GetOrCreateExtension<T>()` 挂载。
4. 编辑行为扩展：派生 `UStateTreeEditorSchema`（`PreValidate/Validate`、`GetTransitionEditingRules()`、`GetParametersSchemaClass()`、`AllowExtensions()`），用 `FStateTreeEditorModule::RegisterEditorSchemaClass(RuntimeSchemaClass, EditorSchemaClass)` 注册；同法 `RegisterEditorDataClass(Schema, EditorDataClass)` 配自定义 `UStateTreeEditorData` 子类。
5. 自定义节点的编辑器呈现零注册（§1-4/§1-5）：分组靠 `Category` 元数据，图标靠 `GetIconName`/`GetIconColor`；BP 节点图表变量自动按 Context/Input/Output 三类分组。

**现行 API 锚点**：`FStateTreeEditorModule::SetDetailPropertyHandlers(IDetailsView&)`；`FPropertyEditorModule::RegisterCustomPropertyTypeLayout/RegisterCustomClassLayout`；`UStateTreeEditorDataExtension::CustomizeDetails(UStateTreeState*, IDetailLayoutBuilder&)`；`FStateTreeEditorModule::RegisterEditorSchemaClass(...)`；`FStateTreeEditorModule::RegisterEditorDataClass(...)`。

**详见** editor.md（ViewModel / 绑定 UI 工作流 / Diff）

## 12. Trace / 调试扩展

**何时用**：让自定义节点/宿主在 Trace 录制与 Gameplay Debugger 中可见。

**步骤**：

1. 节点自定义 Trace 文本：在 TestCondition/Tick 等处用宏 `SET_NODE_CUSTOM_TRACE_TEXT(Context, MergePolicy, Format, ...)`（`WITH_STATETREE_TRACE`；MergePolicy 常用 Override）——全部内置条件/任务均用此宏【源码:ST\Public\StateTreeNodeBase.h L14-24】。
2. Gameplay Debugger 文本：Task/Evaluator override `GetDebugInfo(const FStateTreeReadOnlyExecutionContext&) const → FString`（§5；弃用旧接口见 §14）。
3. Rewind Debugger 集成：StateTree 编辑器模块以 ModularFeature 注册 `IRewindDebuggerExtension`（播放扩展）与 `IRewindDebugger::IRewindDebuggerTrackCreator`（轨道创建器），消费 `IRewindDebugger` 服务接口【源码:STE\Private\StateTreeEditorModule.cpp L242-255】——自定义回放视图/轨道按同一机制注册自己的 feature。
4. 宿主侧：构造执行上下文后关联 Trace（Mass/UAF 宿主均调 `SetOuterTraceId`）；`FStateTreeExecutionExtension::GetInstanceDescription()` 定制实例描述（Mass=Entity、Avalanche=场景描述）。
5. 非 Shipping 目标自动录制开关：`UStateTreeSettings::bAutoStartDebuggerTracesOnNonEditorTargets`。

**现行 API 锚点**：`SET_NODE_CUSTOM_TRACE_TEXT(...)`；`FStateTreeTaskBase::GetDebugInfo(const FStateTreeReadOnlyExecutionContext&) const`；`IRewindDebuggerExtension`；`IRewindDebugger::IRewindDebuggerTrackCreator`；`FStateTreeExecutionExtension::GetInstanceDescription()`。

**详见** debugging-trace.md（Trace 全链 / 断点 / 回放）

## 13. 自定义宿主（三路线取舍）

**何时用**：非 Actor 载体、批量实例池、非常规驱动（信号 / 动画遍历 / 播放链）需要跑树。

**路线**：三路线取舍（组件式 `UStateTreeComponent` / 每次调用重建式 GameplayInteractions·GameplayCameras·Avalanche / 遍历驱动式 UAFStateTree）与引擎范本、成本对照见 integrations.md §2.2/§7.2；接入步骤一律走其 §7.1 十步清单，本文档不复制。

**现行 API 锚点**：`FStateTreeExecutionContext::Start(FStartParameters)`；`FStateTreeExecutionContext::SetContextDataByName(FName, FStateTreeDataView)`；`FStateTreeExecutionContext::SetCollectExternalDataCallback(FOnCollectStateTreeExternalData)`；`FStateTreeExecutionContext::AreContextDataViewsValid()`；`FStateTreeMinimalExecutionContext::SendEvent(...)`。

**详见** integrations.md（10 步清单 + 九大官方宿主对照）

## 14. 弃用 API 速查（自定义相关）

| API | 弃用版本 | 替代品 |
|---|---|---|
| `UStateTreeTaskBlueprintBase::ReceiveEnterState/ReceiveTick`（带 `EStateTreeRunStatus` 返回值） | all | `ReceiveLatentEnterState`/`ReceiveLatentTick` + `FinishTask` |
| `UStateTreeNodeBlueprintBase::WeakInstanceStorage` / `CachedFrameStateTree` / `CachedFrameRootState` | 5.6 | `WeakExecutionContext` |
| `UStateTreeTaskBlueprintBase::WeakTaskRef` | 5.6 | WeakExecutionContext 内 TaskIndex |
| `FStateTreeNodeBase::Compile(FStateTreeDataView, TArray<FText>&)`（final） | 5.6 | `Compile(UE::StateTree::ICompileNodeContext&)` |
| `FStateTreeNodeBase::OnBindingChanged(..., const FStateTreePropertyPath&, ...)`（final） | 5.6 | `FPropertyBindingPath` 版本 |
| `FStateTreeEvaluatorBase::AppendDebugInfoString(FString&, const FStateTreeExecutionContext&)`（final） | 5.8 | `GetDebugInfo(const FStateTreeReadOnlyExecutionContext&)` |
| 条件比较 `EGenericAICheck` 构造器 / `GenericAICheckToComparisonOperator` | 5.8 | `UE::StateTree::EComparisonOperator` |
| `FStateTreePropertyRefExternalHandle` / `TStateTreePropertyRefExternalHandle<T>` | 5.8 | `MakeStrongExecutionContext()` + `GetPtrTupleFromStrongExecutionContext` |
| `PropertyRefHelpers::GetMutablePtrToProperty` 等的 ParentFrame 版重载 | 5.8 | ITemporaryStorage 参数的现行重载 |
| `FStateTreeExecutionContext::Start(const FInstancedPropertyBag*, int32)` | 5.8 | `Start(FStartParameters)` |
| `FStateTreeInstanceStorage::SetGlobalParameters(const FInstancedPropertyBag&)` | 5.8 | `SetGlobalParameters(FConstStructView)` |
| `STATETREE_POD_INSTANCEDATA(Type)` 宏 | 5.8 | `UE_STATETREE_CONSTRUCTED/ZEROED_TRIVIALLY_COPIED_NO_DESTRUCTOR_INSTANCEDATA` |
| `FStateTreeExecutionExtension::ScheduleNextTick(const FContextParameters&)`（final 单参） | 5.7 | 双参 `ScheduleNextTick(const FContextParameters&, const FNextTickArguments&)` |
| `UStateTreeComponentSchema::ContextActorDataDesc_DEPRECATED` | 5.4 | `GetContextActorDataDesc()` / `ContextDataDescs` |
| `UStateTreeEditorData::UpdateBindingsInstanceStructs()` | 5.8 | `UpdateBindings()`（弃用消息写 "UpdateEditorBindings" 系笔误，公开 API 无此名；已核 StateTreeEditorData.h L254-261） |
| `FStateTreeTransition::AddCondition<T>()` | 5.8 | `AddConditionWithOuter<T>(TNotNull<UStateTreeState*>)` |
| `UStateTreeEditorData::GetAccessibleStruct` | 5.6 | `GetAccessibleStructsInExecutionPath` |
| `UE::StateTree::Delegates::OnRequestCompile` | 5.8 | `UStateTreeEditingSubsystem` 触发编译 |

## 15. 开放问题

1. `FStateTreeConditionBase::bHasShouldCallStateChangeEvents` 由编译器器置位的具体判定条件本次调研未展开（属编译链，机制细节见 editor.md 及其开放问题）。
2. `FStateTreePropertyRef::GetMutablePtrTuple` 的 5 参编译死代码坑（CL 55116800）是否在后续补丁修复需升级复核；当前基线一律改用 `GetPtrTupleFromStrongExecutionContext`。
3. StateCentricView 的外部扩展注册机制（`SExtendableNode` 子系统收集）无公开注册表，第三方接入路径未证实（见 editor.md 未证实清单）。
4. 本文档只收「步骤 + 锚点」；所引 references/*.md 均已产出，机制细节以各拥有权文档为权威。
5. 「GlobalTask 参与完成判定与 TaskCompletion 绑定」的引入版本未证实：调研报告 04/12 均无版本佐证（仅证实 5.8 现行形态——`BroadcastTaskCompletionDispatchers` 对 GlobalTask 生效，04-nodes-builtin.md §7），原行内 **[UE 5.7+]** 标注已删除。
