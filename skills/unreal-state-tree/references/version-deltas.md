# Unreal StateTree 版本差异权威文档（version-deltas）

> 版本基线：UE 5.8.0 (Release-5.8, CL 55116800) · 版本标记约定：**[UE 5.x+]**=该版本新增，**[仅 <5.x]**=已移除/旧行为，**[5.8 变更]**=本版变更；现行 API 判定标准=声明无 UE_DEPRECATED 标记。

## TL;DR

- 本文件是 unreal-state-tree 技能唯一的版本差异权威文档；引擎升级时**优先更新本文件**，再全局修订其他 references 的行内版本标记。
- 三波结构性大改（依据全插件约 150 处 UE_DEPRECATED 扫描，00-overview.md §7）：**UE 5.6** 执行身份体系重构（FrameID/StateID、TaskIndex、TasksCompletionStatus）；**UE 5.7** 编译与状态选择重构（`UE::StateTree::Compiler::FCompilerManager`、`FSelectStateResult`、Trace API 收编）；**UE 5.8** 去 AIModule 化 + 异步取值换代（`UE::StateTree::EComparisonOperator`、StrongExecutionContext、POD 宏）。
- GameplayStateTreeModule（组件层）5.6~5.8 自身零新弃用（仅 5.1/5.4 旧标记），破坏性变化全部经 StateTreeModule 核心传导【07-gameplay-state-tree.md §7】。
- 升级到 >5.8：先按 §6「升级检查清单」逐锚点核对新版源码 → 更新本文件 → 全局 grep 各 references 行内标记修订（流程见 §1.1）。
- 引入版本未证实的条目一律照报告标注「未证实」，汇总在 §7 开放问题。

## 目录

1. 如何使用本文件
2. 更早背景（≤5.5）
3. UE 5.6 变化
4. UE 5.7 变化
5. UE 5.8 变化
6. 升级检查清单
7. 开放问题

---

## 1. 如何使用本文件

**证据路径约定**：下文源码证据省略公共前缀 `E:\UnrealEngine\UE_5.8\`；模块缩写 RM=`Engine\Plugins\Runtime\StateTree\Source\StateTreeModule`、EM=`...\Source\StateTreeEditorModule`、DV=`...\Source\StateTreeDeveloper`、GS=`Engine\Plugins\Runtime\GameplayStateTree\Source\GameplayStateTreeModule`。报告证据写法 `NN-xxx.md §n`（位于 `C:\Users\TireflyPC\.agents\tmp\state-tree-research\`）。

### 1.1 升级引擎时的更新流程（>5.8 时执行）

1. 用新版引擎源码逐项核对 §6「升级检查清单」的锚点（API 名/文件名/宏名/CVar 清单）：确认弃用条目是否被物理移除、现行签名是否再变、编译开关与 CVar 条件是否变化。
2. 先更新本文件：在 §5 之后新增「UE 5.x 变化」节；把确认移除的条目在原节标注「已移除（5.x）」；§6 清单同步修订基线行号与文件位置。
3. 再全局修订其他 references：grep 全部 references 的行内标记 `**[UE 5.`、`**[仅 <5.`、`**[5.8 变更]**`、`**[5.7 变更]**`（半角「N 变更」式一并核对），按本文件新结论逐处改写；两者不一致时以新版源码核实后同时修两侧。

### 1.2 行内标记与本文件的对应关系

| 各 references 中的行内标记 | 本文件中的落点 |
|---|---|
| `**[UE 5.x+]**`（该版本新增/现行形态） | §3~§5 对应版本节条目的「迁移动作/现行形态」 |
| `**[仅 <5.x]**`（已移除/旧行为） | §3~§5 对应版本节条目的「变化点（弃用）」 |
| `**[5.8 变更]**` | §5 全部条目 |

各条目标题尾的标记 = 该条目内容在 references 中应使用的行内标记（弃用条目标 `**[仅 <5.x]**`，纯新增条目标 `**[UE 5.x+]**`）。

---

## 2. 更早背景（≤5.5，仅列仍影响现状的项）

- **5.1**：`UStateTreeComponent::StateTree_DEPRECATED` 弃用 → 组件改走 `FStateTreeReference` 模型。GS `Public\Components\StateTreeComponent.h L166-169`（PostLoad 迁移 `Private\Components\StateTreeComponent.cpp L61-75`）【07 §7】。
- **5.2（文档证据）**：官方 API 文档 5.2~5.8 页面 `UStateTreeComponent` 均挂 GameplayStateTreeModule——「5.8 才迁入」的说法不成立，技能文档不得写死该变迁【00-overview.md §4.3；07 §7】。
- **5.4**：`UStateTreeComponentSchema::ContextActorDataDesc_DEPRECATED` → `ContextDataDescs`（Context 声明从单 Actor Desc 扩为多 Desc 数组，自定义 Context 对象成为一等公民）。GS `Public\Components\StateTreeComponentSchema.h L92-95`【07 §7】。
- **5.4+（引擎风格）**：全插件导出宏改为 `#define UE_API XXX_API` + MinimalAPI 细粒度导出【00 §7】。
- **历史遗留（UE_DEPRECATED(all)，仍在做旧资产序列化兼容）**：`FStateTreeCustomVersion`（20 个枚举项，LatestVersion=19；GUID 仍被 `UStateTree::Serialize` 使用）、`FStateTreeEditorPropertyPath`、旧选择行为名等。RM `Public\StateTree.h L23-81`【02-asset-types.md §7；08-editor-compiler.md §8.1】。
- **版本未证实的更早变化**：Blueprint 任务 `ReceiveEnterState/ReceiveTick` → `ReceiveLatentEnterState/ReceiveLatentTick` + `FinishTask` 范式（UE_DEPRECATED(all) 无版本号）等，见 §7 O1。

---

## 3. UE 5.6 变化（执行身份体系重构）

主题：帧/状态/任务的身份标识从「StateTree 指针 + StateHandle + 弱引用句柄」统一为 **FrameID/StateID/NodeIndex**；异步上下文与任务完成状态整套换代。

### 3.1 WeakTaskRef 全链弃用 → TaskIndex（WeakExecutionContext）　**[仅 <5.6]**
- **变化点**：`FStateTreeWeakTaskRef`/`FStateTreeStrongTaskRef` 全链弃用（RM `Public\StateTreeNodeRef.h` 整文件；`UStateTreeTaskBlueprintBase::WeakTaskRef`，`Public\Blueprint\StateTreeTaskBlueprintBase.h L106-110`），弃用消息 "We now use TaskIndex in WeakExecutionContext"；`FStateTreeExecutionState::CurrentExecutionContext` 弃用（`StateTreeExecutionTypes.h L1273-1274`）；`UStateTreeNodeBlueprintBase` 缓存三件套 `WeakInstanceStorage/CachedFrameStateTree/CachedFrameRootState` 弃用（`Public\Blueprint\StateTreeNodeBlueprintBase.h L108-119`，本文件亲核）。
- **影响**：以弱句柄跨帧引用任务/实例存储的异步代码全部失效。
- **迁移动作**：改用 `FStateTreeWeakExecutionContext`（携带 FrameID/StateID/NodeIndex 精确定位，任务以 TaskIndex/NodeIndex 寻址）。
- **证据**：RM `Public\StateTreeAsyncExecutionContext.h L327-353`【01 §7；04 §7；06 §7】。

### 3.2 任务完成状态：FFinishedTask → FStateTreeTasksCompletionStatus　**[仅 <5.6]**
- **变化点**：`UE::StateTree::FFinishedTask` 查询链（`FinishedTasks/CompletedFrameIndex/CompletedStateHandle`）弃用 → `FinishTask` + `FStateTreeTasksCompletionStatus`（RM `Public\StateTreeTasksStatus.h L44-298`；`FTasksCompletionStatus` 位集视图 + 容器，`StateTreeExecutionTypes.h L749-781/L1260-1271`）。
- **影响**：轮询"哪些任务完成"的旧接口消失。
- **迁移动作**：任务内调 `FinishTask`；宿主经 `FStateTreeTasksCompletionStatus` 位集查询。
- **证据**：【01 §7/§8.3；06 §7】注意：`TaskIndex` 非独立公开类型，仅存于已弃用的 `FFinishedTask` 与 TriggerTransitions 内部 `FTransitionHandler`【01 §8.3】。

### 3.3 帧/状态身份统一 FrameID/StateID　**[仅 <5.6]**
- **变化点**：`FStateTreeExecutionFrame::SourceFrameID/SourceStateID`（`UE::StateTree::FActiveFrameID/FActiveStateID`）取代「StateTree 指针 + StateHandle」标识（`StateTreeExecutionTypes.h L288-303` 弃用旧字段）；`FActiveFrameID/FActiveStateID` 定义于 RM `Public\StateTreeStatePath.h L17-70`；`FStateTreeExecutionFrame::ActiveNodeIndex` 取代 ExecState 级索引；`FStateTreeActiveStates::Push(StateHandle)` 单参版弃用（`ExecutionTypes.h L324-328`）；`FStateTreeTemporaryInstanceData::StateTree/RootState` → FrameID（`Public\StateTreeInstanceData.h L113-121`）、`TStateTreeInstanceDataStructRef::WeakStateTree/RootState` → FrameID（L828-833）；`FStateTreeTransitionDelayedState::StateTree` → StateID（`ExecutionTypes.h L725-727`）、`FindAndRemoveExpiredDelayedTransitions` 弃用（L1144）；Minimal 上下文构造改 `TNotNull`。
- **影响**：一切按 StateHandle/StateTree 指针寻址帧与状态的宿主代码失效。
- **迁移动作**：帧/状态寻址统一改 FrameID/StateID（`FStateTreeStatePath` 体系）。
- **证据**：【01 §7；03 §7；06 §7】。

### 3.4 SetLinkedStateTreeOverrides 改传拷贝　**[仅 <5.6]**
- **变化点**：`FStateTreeExecutionContext::SetLinkedStateTreeOverrides(const FStateTreeReferenceOverrides*)` 指针版弃用（"Use SetLinkedStateTreeOverrides that creates a copy."）。
- **影响**：宿主注入 Linked 覆盖的调用形态变化。
- **迁移动作**：改传值/拷贝重载（组件已用新版，GS `Private\Components\StateTreeComponent.cpp L90`）。
- **证据**：RM `Public\StateTreeExecutionContext.h L348-353`【07 §7】。

### 3.5 节点基类旧虚函数 final 弃用（Compile / OnBindingChanged）　**[仅 <5.6]**
- **变化点**：`FStateTreeNodeBase::Compile(FStateTreeDataView, TArray<FText>&)` → `Compile(ICompileNodeContext&)`（`StateTreeNodeBase.h L141-142`）；`OnBindingChanged(FStateTreePropertyPath)` → `OnBindingChanged(FPropertyBindingPath)`（L186-187）；两者旧重载均为 final。
- **影响**：自定义节点覆写旧签名直接编译失败。
- **迁移动作**：改覆写 `Compile(ICompileNodeContext&)` 与 `FPropertyBindingPath` 版 `OnBindingChanged`。
- **证据**：【04-nodes-builtin.md §7】。

### 3.6 执行面小项　**[仅 <5.6]**
- **变化点**：`AddDelegateListener/RemoveDelegateListener` → `BindDelegate/UnbindDelegate`（`StateTreeExecutionContext.h L530/L541`）；`FStateTreeTransitionResult(const FRecordedStateTreeTransitionResult&)` 构造弃用 → `MakeTransitionResult`（`StateTreeExecutionTypes.h L1317-1318`）。
- **影响**：委托监听与录制转换结果构造的旧入口失效。
- **迁移动作**：改 `BindDelegate/UnbindDelegate` 与 `MakeTransitionResult`。
- **证据**：【04 §7；06 §7】。

### 3.7 Trace：FindOrAddDebugIdForAsset 弃用　**[仅 <5.6]**
- **变化点**：`UE::StateTreeTrace::FindOrAddDebugIdForAsset` UE_DEPRECATED(5.6)，DebugId 分配收归内部缓冲结构。
- **影响**：外部不得再自管资产 DebugId。
- **迁移动作**：删除显式分配调用，交给 Trace 内部（5.7 进一步收编见 4.3）。
- **证据**：RM `Public\StateTreeTrace.h L116-117`【10-debugging-trace.md §7】。

### 3.8 PropertyBinding 底座拆分　**[仅 <5.6]**
- **变化点**：`EPropertyBindingAccessType` → `EPropertyBindingPropertyAccessType`（改名时引入新访问类型；SharedStruct/StructInstanceContainer 的确切引入版本未证实——可能 5.8 才加，见 property-bindings.md 开放问题 6；PropertyBindingUtils 模块 `PropertyBindingTypes.h L16-40`）；索引类型拆出 `FPropertyBindingIndex16`（与 `FStateTreeIndex16` 并存，序列化兼容 `SerializeFromMismatchedTag` + 编辑器转换函数表）；`PropertyRefHelpers::IsPropertyAccessibleForPropertyRef` 旧 indirection 重载弃用。
- **影响**：绑定访问类型枚举与索引类型改名扩容。
- **迁移动作**：枚举/索引类型按新名迁移；跨插件序列化依赖转换函数表。
- **证据**：【05-property-bindings.md §7.3】。

### 3.9 编辑器侧批量改名　**[仅 <5.6]**
- **变化点**：根参数 PropertyBag 化——`UStateTreeEditorData` 的 `RootParameters(FStateTreeStateParameters)` → `RootParameterPropertyBag(FInstancedPropertyBag)` + `RootParametersGuid`，PostLoad 依 `FUE5SpecialProjectStreamObjectVersion::StateTreeGlobalParameterChanges` 迁移（EM `Public\StateTreeEditorData.h L405` + `Private\StateTreeEditorData.cpp L187-193`）；`GetAccessibleStruct` → `GetAccessibleStructsInExecutionPath`（L215）；`FStateTreeViewModelInsert` → `EStateTreeViewModelInsert`（`Public\StateTreeViewModel.h L59`）；绑定编译器旧 Compile 签名 → `FPropertyBindingPath` 版、`GetDispatcherIDFromPath` 换 Path 类型（`FStateTreePropertyBindingCompiler.h L117-120`）。
- **影响**：编辑器工具/扩展的编译数据访问面整体改名。
- **迁移动作**：按新名逐一替换；根参数读 `GetRootParametersPropertyBag`。
- **证据**：【08-editor-compiler.md §7.3；09-editor-ui.md §7】。

### 3.10 Mass 集成侧　**[仅 <5.6]**
- **变化点**：`FMassStateTreeExecutionContext` 旧构造弃用（不再要求 EntityManager + SignalSubsystem 参数；MassAI::MassAIBehavior `MassStateTreeExecutionContext.h L41-50`）；`UE_ENABLE_INCLUDE_ORDER_DEPRECATED_IN_5_6` include 迁移块贯穿 `MassStateTree*.h`（直接 include `MassEntityTypes.h`/`MassLODTypes.h` 的旧写法需调整）；`MassStateTreeFragments.h` 降级为 deprecated-include。
- **影响**：Mass 宿主与自定义 Mass-StateTree 桥接代码编译面变化。
- **迁移动作**：用新构造；按新头文件粒度调整 include。
- **证据**：【11-integrations.md §7】。

---

## 4. UE 5.7 变化（编译管理与状态选择重构）

### 4.1 FCompilerManager 新增（编译触发中枢）　**[UE 5.7+]**
- **变化点**：新增 `UE::StateTree::Compiler::FCompilerManager`（EM，pimpl `FCompilerManagerImpl`，订阅 OnPreCookStateTreeAsset/OnObjectsReinstanced/OnUserDefinedStructReinstanced/PreBeginPIE/EndPIE，`Private\StateTreeCompilerManager.cpp L307-320`）；`UStateTree` 三个编辑器委托字段/函数整体弃用（"Use the compiler manager."）：`OnPreBeginPIE(bool)`（RM `Public\StateTree.h L360-364`）、`OnObjectsReinstancedHandle`（L386-387）、`OnUserDefinedStructReinstancedHandle`（L388-389）、`OnPreBeginPIEHandle`（L390-391）。
- **影响**：编辑器编译触发的订阅点从 UStateTree 委托搬到 CompilerManager。
- **迁移动作**：编译相关订阅改接 `FCompilerManager`；删除对 UStateTree 旧委托的使用。
- **证据**：【08 §7.1；02 §7】引入的准确小版本未证实（O9）。

### 4.2 FSelectStateResult 贯穿状态选择　**[UE 5.7+]**
- **变化点**：`FSelectStateResult`（SelectedStates/SelectedFrames/TemporaryFrames/SelectionEvents/TargetState，实现 `ITemporaryStorage`）贯穿 SelectState/EnterState/ExitState/UpdateInstanceData/CaptureNewStateEvents/MakeRecordedTransitionResult（新签名带 `TSharedPtr<FSelectStateResult>`）；`FStateTreeFrameStateSelectionEvents`/`FStateSelectionResult` 弃用；选择结果以 StateID（而非 StateHandle）标识；`FStateTreeTransitionResult::NextActiveFrames` UPROPERTY 弃用 → `RequestTransitionResult.Selection.SelectedState`（`StateTreeExecutionTypes.h L1355-1358`）；转换参数化 `FTransitionArguments`（Priority/TransitionEvent/Fallback/SelectionRules）；`TestAllConditions/EvaluateUtility` → 带 Validation 版本（如 `EvaluateUtilityWithValidation`）；上下文侧旧 FinishTask 重载（FFinishedTask）及辅助转 Deprecated 空实现（`Private\StateTreeExecutionContext.cpp L2308-2372`）；`EStateTreeStateSelectionRules` 重构（注释 "Previous (UE 5.6) rules"，`StateTreeTypes.h L112-113`）；全局节点 Start/Stop 拆 `StartGlobalsForFrameInternal<bOnActiveInstances,bMoveFromTemporary>` 模板族（内部机制）。
- **影响**：宿主与测试对状态选择结果的读取方式整体更换。
- **迁移动作**：改用带 `FSelectStateResult` 的新签名；结果按 StateID 读取。
- **证据**：RM `Public\StateTreeExecutionContext.h L839-880/L1215-1240`、`Private\StateTreeExecutionContext.cpp L4348-4537`【01 §7；04 §7；06 §7】。

### 4.3 Trace Output* 函数收编　**[仅 <5.7]**
- **变化点**：`UE::StateTreeTrace` 11 个 `Output*` 函数的 `FStateTreeInstanceDebugId` 参数版全部弃用（5.8 中函数体已清空）→ 统一 `TNotNull<const FStateTreeReadOnlyExecutionContext*>` 版本；调用方不能再自管实例 ID。
- **影响**：自定义 Trace 消费端编译面变化。
- **迁移动作**：改传执行上下文指针，删除自建 `FStateTreeInstanceDebugId` 的用法。
- **证据**：RM `Public\StateTreeTrace.h L118-139` + `Private\StateTreeTrace.cpp L906-964`【10 §7】。

### 4.4 调试回放面签名更换　**[仅 <5.7]**
- **变化点**：`FScrubState` 不再支持多事件集合（多集合构造/索引器弃用，`StateTreeDebuggerTypes.h L194-208`）；`FStateTreeDebugger` 多处换签名——`GetDescriptor` 裸指针 → `TSharedPtr`、`GetRecordingDuration` → `GetLastProcessedRecordedWorldTime`、`GetSessionInstances` → `GetSessionInstanceDescriptors`、`FOnStateTreeDebuggerDebuggedInstanceSet`/`OnSelectedInstanceCleared` 弃用（RM `Public\Debugger\StateTreeDebugger.h L79-80/L190-199/L245-249/L332-342`）；`IStateTreeTraceProvider::GetInstances` 旧数组版弃用（final 空实现，`IStateTreeTraceProvider.h L33-36`）；`IRewindDebuggerTrackCreator` 的 uint64 ObjectId → `FObjectId`（`IRewindDebuggerTrackCreator.h L67-90`，引擎本体 RewindDebuggerInterface）。
- **影响**：RewindDebugger/Trace 定制轨道与 Provider 全部需适配。
- **迁移动作**：按新签名逐一迁移；多集合 Scrub 逻辑改单集合。
- **证据**：【10 §7】。

### 4.5 ScheduleNextTick 换 FNextTickArguments 签名　**[UE 5.7+]**
- **变化点**：`FStateTreeExecutionExtension::ScheduleNextTick(const FContextParameters&)` 单参版弃用且 final → `(const FContextParameters&, const FNextTickArguments&)`（含 `UE::StateTree::ETickReason`；RM `Public\StateTreeExecutionExtension.h L53-68`）；`ETickReason`（Forced/StateCustomTickRate/TaskTicking/TransitionTicking/TransitionRequest/Event/CompletedState/DelayedTransition/Delegate，`StateTreeExecutionTypes.h L783-808`）与组件级 `ScheduleTickFrame` 语义成熟。
- **影响**：自定义 ExecutionExtension 升 5.7 必改（final 旧签名无法编译）。
- **迁移动作**：覆写新双参签名；组件的 `FStateTreeComponentExecutionExtension` 已是范本（GS `Public\Components\StateTreeComponent.h L30`）。
- **证据**：【06 §7；07 §7；11 §7】。

### 4.6 FStateTreeLinker 构造带 StateTree 指针　**[UE 5.7+]**
- **变化点**：`FStateTreeLinker` 旧 Schema 构造弃用 → 构造带 `const UStateTree*`（RM `Public\StateTreeLinker.h L26-31`）；Link 上下文从 Schema 升级为整树。
- **影响**：Link 阶段自定义解析可访问整树。
- **迁移动作**：构造处传入 StateTree 指针。
- **证据**：【02-asset-types.md §7】。

### 4.7 输出绑定体系　**[UE 5.7+]**
- **变化点**：`FStateTreePropertyPathBinding` 新增 `bIsOutputBinding` + 带 `bInIsOutputBinding` 的构造（旧构造弃用，`Public\StateTreePropertyBindings.h L135-158`）；节点新增 `OutputBindingsBatch`（`StateTreeNodeBase.h L220`）——输出绑定独立 batch 且保证不含 PropertyFunction（异步安全前提）；`ResolveCopyType` 静态函数弃用 → 虚 `ResolveBindingCopyInfo`（PropertyBindingUtils `PropertyBindingBindingCollection.h L345-349`）。
- **影响**：输出直写成为一等公民；复制类型解析改虚函数。
- **迁移动作**：节点输出绑定走 `OutputBindingsBatch`；复制解析覆写 `ResolveBindingCopyInfo`。
- **证据**：【05 §7.2】。

### 4.8 临时实例数据 Frame→FrameID　**[仅 <5.7]**
- **变化点**：`GetMutableTemporaryStruct/Object(const FStateTreeExecutionFrame&, …)` Frame 版弃用 → FrameID 版（RM `Public\StateTreeInstanceData.h L314-324`）。
- **影响**：临时结构访问与 3.3 身份体系统一。
- **迁移动作**：改 FrameID 重载。
- **证据**：【03-instance-data.md §7】。

### 4.9 编辑器与 Mass 小项　**[UE 5.7+]**
- **变化点**：`FStateTreeNodeClassCache` API 换 `FTopLevelAssetPath`（EM `Public\StateTreeNodeClassCache.h L28-31`）；`FStateTreeEditorModule::OnUserDefinedStructReinstancedHandle` 弃用（"is not used"，`Public\StateTreeEditorModule.h L163`）；Mass 侧 `FMassExecutionExtension` 实装 `OnLinkedStateTreeOverridesSet` 钩子（hash 追踪 overrides，MassStateTreeExecutionContext.cpp L175-183）。
- **影响**：节点类缓存与编辑器模块订阅点小改；Mass 宿主示例可参照。
- **迁移动作**：按新类型/新钩子适配。
- **证据**：【09 §7；08 §7.1；11-integrations.md §7】。

---

## 5. UE 5.8 变化（本基线版本）

### 5.1 去 AIModule 化：EGenericAICheck → EComparisonOperator　**[5.8 变更]**
- **变化点**：新增 `UE::StateTree::EComparisonOperator`（RM `Public\StateTreeTypes.h L59-68`）；三个数值比较条件（Int/Float/Distance）的 `Operator` UPROPERTY 换类型但保留字段名并标 `UE_DEPRECATED_FORGAME(5.8)`；三个 `EGenericAICheck` 构造器弃用；转换函数 `GenericAICheckToComparisonOperator` 弃用；`IsTrue` 值经 meta InvalidEnumValues 移出合法枚举（EM 侧 `Public\StateTreeCommonConditions.h L47-108/L231-245`、`StateTreeConditionHelpers.h L40-41`）。迁移仅覆盖数值型比较条件——Bool/Enum/Name/Object/Tag 条件从未用过 `EGenericAICheck`。
- **影响**：使用比较条件的资产需重存；C++ 比较条件代码需换枚举。
- **迁移动作**：改用 `UE::StateTree::EComparisonOperator`；删除对 `EGenericAICheck` 构造器与转换函数的引用。
- **证据**：【02 §7；04 §7】配套：`StateTreeCommonConditions.h`/`StateTreeConditionHelpers.h` 以 `#if UE_ENABLE_INCLUDE_ORDER_DEPRECATED_IN_5_8` 包裹 `AITypes.h` include（含 `EGenericAICheck` 前向声明，L5-7/L15/L13）；RM Build.cs 对 AIModule 的 Public 依赖带 @TODO（待 AITypes.h 弃用后移为 Private）【04 §7；00 §1.1】。

### 5.2 Evaluator 调试接口：AppendDebugInfoString → GetDebugInfo　**[5.8 变更]**
- **变化点**：`FStateTreeEvaluatorBase::AppendDebugInfoString(FString&, FStateTreeExecutionContext&)` final 弃用 → `GetDebugInfo(const FStateTreeReadOnlyExecutionContext&)` 返回 FString（`Public\StateTreeEvaluatorBase.h L44-47`）；Task 侧无旧版、直接是新接口 `GetDebugInfo`（`Public\StateTreeTaskBase.h L104`）。
- **影响**：自定义 Evaluator 的调试文本接口换签名（final 旧版编译失败）。
- **迁移动作**：覆写 `GetDebugInfo` 返回调试字符串。
- **证据**：【04 §7】。

### 5.3 POD 实例数据宏换代　**[5.8 变更]**
- **变化点**：`STATETREE_POD_INSTANCEDATA` UE_DEPRECATED_MACRO(5.8) → `UE_STATETREE_CONSTRUCTED_TRIVIALLY_COPIED_NO_DESTRUCTOR_INSTANCEDATA` / `UE_STATETREE_ZEROED_TRIVIALLY_COPIED_NO_DESTRUCTOR_INSTANCEDATA`（默认实现等同 ZEROED 新宏；RM `Public\StateTreeTypes.h L1349-1388`）；内置条件已全部迁移（`StateTreeCommonConditions.h L29/L76/L123/L166/L213/L259/L298`），引擎内旧宏仅剩定义、无使用点；测试佐证 `StateTreeTestTypes.h:1164/:1228`。
- **影响**：旧宏继续可用但已弃用；语义按"是否需要构造/是否零初始化"二选一。
- **迁移动作**：自定义 POD 实例数据结构改用两个新宏（按构造语义选择）。
- **证据**：【02 §7；03 §7；04 §7；12-tests.md §7-1】。

### 5.4 PropertyRefExternalHandle → StrongExecutionContext 异步取值　**[5.8 变更]**
- **变化点**：`FStateTreePropertyRefExternalHandle`/`TStateTreePropertyRefExternalHandle` 整体弃用（RM `Public\StateTreePropertyRef.h L294-366`）→ Weak/Strong 上下文模式：节点回调内 `Context.MakeWeakExecutionContext()` 捕获精确路径（FrameID/StateID/NodeIndex + 临时存储弱引用），异步回调 `MakeStrongExecutionContext()`（写）/`MakeStrongReadOnlyExecutionContext()`（只读）后经 `GetPtrTupleFromStrongExecutionContext` 直写，或 `CopyInputBindings()/CopyOutputBindings()` 重放绑定（`Public\StateTreeAsyncExecutionContext.h L27-242`）。
- **影响**：旧 ExternalHandle 只能按 RootState 线性反查活跃帧；新模式可命中 TemporaryFrames/临时状态、带 MRSW RAII 访问探测（`TStateTreeStrongExecutionContext<false/true>`）。
- **迁移动作**：①删除 ExternalHandle 成员（`RefAccessIndex` 序列化兼容）；②WeakContext 捕获时机提前到仍持有效帧的回调内；③异步回调改 MakeStrong*；④输出直写用元组接口或 `CopyOutputBindings()`；⑤弃用的 ParentFrame 版 helper 一并迁移。引擎内唯一范本 `FStateTreeRunEnvQueryTask`（GS 层 EQS 任务）。
- **证据**：【05-property-bindings.md §7.1（含迁移详解）】。

### 5.5 实例数据访问 helper 收参　**[5.8 变更]**
- **变化点**：`UE::StateTree::InstanceData::GetDataView/GetDataViewOrTemporary` 弃用带 ParentFrame 的内联重载（RM `Public\StateTreeInstanceData.h L39-66`）——与 5.7 起"帧由 FrameID 标识、父帧不再显式传参"方向一致【推断】。
- **影响**：旧重载编译警告。
- **迁移动作**：删除 ParentFrame 实参。
- **证据**：【03-instance-data.md §7】。

### 5.6 Start 形态收拢 FStartParameters + 全局参数 FConstStructView 化　**[5.8 变更]**
- **变化点**：`FStateTreeExecutionContext::Start(const FInstancedPropertyBag*, int32 RandomSeed)` 弃用 → `Start(FStartParameters)`（RM `Public\StateTreeExecutionContext.h L454-464/L492-493`）；`FStartParameters::GlobalParameters` 字段弃用 → `InitialGlobalParameters`（L467）；`FStateTreeInstanceStorage::SetGlobalParameters(const FInstancedPropertyBag&)` 弃用 → FConstStructView 版（`Public\StateTreeInstanceData.h L336-339`）；`FStateTreeReference::GetGlobalParameters()`（FConstStructView）与 `GetParameters()`（FInstancedPropertyBag）并存且均现行（`Public\StateTreeReference.h L47/L61`）。
- **影响**：全局参数从 PropertyBag 泛化为任意结构体（存储层 `GlobalParameters` 本就是 FInstancedStruct）；组件 `StartTree` 已用 `Start(FStartParameters{InitialGlobalParameters, ExecutionExtension})`（GS `Private\Components\StateTreeComponent.cpp L195-199`）。
- **迁移动作**：Start 统一走 `FStartParameters`；跨版本编译兼容照抄 GameplayCameras 的版本宏分支 `#if UE_VERSION_NEWER_THAN_OR_EQUAL(5,8,0)`（StateTreeCameraDirector.cpp L98-102）。
- **证据**：【01 §7；03 §7；05 §7；07 §7；11-integrations.md §7；12-tests.md §7-2】。

### 5.7 参数/链接直接访问弃用　**[5.8 变更]**
- **变化点**：`FCompactStateTreeParameters::Parameters` 直接访问弃用 → `GetValue/GetMutableValue`（PropertyBag 或 InstancedParameters 二选一；RM `Public\StateTreeTypes.h L1080`）；`FStateTreeStateLink` 参数直接访问弃用 → `GetValue/GetMutableValue`、"Use LinkType instead"。
- **影响**：直接读公共成员的代码改方法调用。
- **迁移动作**：替换为对应取值方法。
- **证据**：【02 §7；03 §7；00 §7】。

### 5.8 执行面收拢三件　**[5.8 变更]**
- **变化点**：①`FStateTreeExecutionContext::FindFrame` 弃用 → 命名空间 `FindExecutionFrame`（`StateTreeExecutionContext.h L807`）；②弃用字段 `TriggerTransitionsFromFrameIndex` → 子树完成折叠改用 `FTriggerTransitionsInternalArgs::CompletedSubtreeParentFrameIndex`（L1247-1250）；③头文件对 `StateTreeAsyncExecutionContext.h` 的无条件 include 降级为 `UE_ENABLE_INCLUDE_ORDER_DEPRECATED_IN_5_6` 条件包含（L15-17）。
- **影响**：帧查找入口改名；异步头不再被执行上下文头自动带入。
- **迁移动作**：改 `FindExecutionFrame`；依赖传递 include 的代码显式 include `StateTreeAsyncExecutionContext.h`。
- **证据**：【01-core-execution.md §7】。

### 5.9 编辑器编译触发收口　**[5.8 变更]**
- **变化点**：`UE::StateTree::Delegates::OnRequestCompile` UE_DEPRECATED(5.8) → `UStateTreeEditingSubsystem`（RM `Public\StateTreeDelegates.h L70-76`）；`UStateTreeEditorMode` 的 `EditorDataHash/bLastCompileSucceeded` 弃用 → 改查 `UStateTree::IsEditorDataDirty()/CompileStatus`（EM `Public\StateTreeEditorMode.h L96-99`）。
- **影响**：编辑器扩展不得再自持编译状态或走旧委托。
- **迁移动作**：编译触发改 `UStateTreeEditingSubsystem`；脏/成功态查询改 UStateTree 属性。
- **证据**：【06 §7；08 §7；09 §7】。

### 5.10 Builder Outer 收紧：AddCondition → AddConditionWithOuter　**[5.8 变更]**
- **变化点**：`FStateTreeTransition::AddCondition` 弃用 → `AddConditionWithOuter(TNotNull<UStateTreeState*>)`（保证条件实例数据 Outer 正确；EM `Public\StateTreeState.h L95-121`）。
- **影响**：程序化建树的旧入口弃用。
- **迁移动作**：改 `AddConditionWithOuter` 并显式传状态 Outer。
- **证据**：【08 §7；09 §7】。

### 5.11 转换编辑模型：RequiredEvent 与 ReactivateTargetState　**[5.8 变更]**
- **变化点**：`FStateTreeTransition::EventTag_DEPRECATED`（UE_DEPRECATED(all)）→ `RequiredEvent`（`FStateTreeEventDesc`：Tag + PayloadStruct + `bConsumeEventOnSelect`，"事件在选择时消费"语义进入编辑数据模型；EM `Public\StateTreeState.h L27-42/L139-197`）；转换新增 `ReactivateTargetState`（`EStateTreeTransitionChangeTypeRules`，编辑开关 `UStateTreeEditorSchema::GetTransitionEditingRules` 的 AllowReactivation 规则，`Public\StateTreeEditorSchema.h L17-29`）。
- **影响**：转换事件负载可结构化；重激活成为可配置编辑规则。
- **迁移动作**：建树改填 `RequiredEvent`；需要重激活时经编辑规则开启。
- **证据**：【08 §7；09 §7】。

### 5.12 UpdateBindingsInstanceStructs 弃用（替代名笔误，已亲核修正）　**[5.8 变更]**
- **变化点**：`UStateTreeEditorData::UpdateBindingsInstanceStructs()` UE_DEPRECATED(5.8, "Use UpdateEditorBindings instead")——**弃用消息中的 `UpdateEditorBindings` 并不存在**，现行 API 为 `UStateTreeEditorData::UpdateBindings()`（EM `Public\StateTreeEditorData.h L254-261`，本文件撰写时亲核；修正 09/00 的转述误差）。
- **影响**：照抄弃用消息会引用不存在的 API。
- **迁移动作**：改调 `UpdateBindings()`。
- **证据**：源码亲核 +【08-editor-compiler.md §7.2/§8.4-2】。

### 5.13 录制钩子迁移 IRewindDebuggerRuntimeExtension + UEFN 录制　**[5.8 变更]**
- **变化点**：`IRewindDebuggerExtension::RecordingStarted/RecordingStopped` 变 final 空实现并 UE_DEPRECATED(5.8)（`IRewindDebuggerExtension.h L44-52`，引擎 RewindDebuggerInterface 模块）→ 新接口 `IRewindDebuggerRuntimeExtension`（`Engine\Source\Runtime\RewindDebuggerRuntimeInterface\Public\IRewindDebuggerRuntimeExtension.h L38-82`）：RecordingStarted 改为 trace 连接建立（`FTraceAuxiliary::OnConnection`，任意线程）触发，并新增 `RegisterMessageHandlers/RegisterMessageTypes` 远程调试注册；DV 的 StateTree 录制扩展已按新接口实现。同时 `WITH_STATETREE_TRACE` 明确支持非 Shipping 与 Shipping Editor（UEFN）目标（RM `StateTreeModule.Build.cs L15-16`，`IsStateTreeTraceRecordingSupported` 注释）。
- **影响**：RewindDebugger 录制扩展必须换基接口；UEFN/Shipping-Editor 可录制。
- **迁移动作**：录制扩展改实现 `IRewindDebuggerRuntimeExtension`。
- **证据**：【10-debugging-trace.md §7】接口是否 5.8 新增未证实（O4）。

### 5.14 新增能力（无弃用标记，引入版本未证实）
- **变化点**：`FStartParameters::SelectStateOverrideArgs`（启动状态覆盖）配套 `UStateTree::GetStateHandleFromGameplayTag(Tag, EStateGameplayTagQueryMethod)`（RM `Public\StateTree.h L228`）；`FStateTreeExecutionExtension::OnBeginApplyTransition` 钩子（`Public\StateTreeExecutionExtension.h L76-80`）。
- **影响**：启动覆盖与转换应用前回调成为可用扩展点。
- **迁移动作**：可按需采用；引用时标注「未证实」。
- **证据**：【01 §7/§8.2-1；11-integrations.md §7/§8-2】引入版本见 O5/O6。

### 5.15 外部插件参照（版本敏感二开指引）　**[5.8 变更]**
- **变化点**：Avalanche `UAvaTransitionTree` 配置面整体迁往 `IAvaTransitionBehavior`（7 个成员 5.8 弃用，AvaTransitionTree.h L24-67）；9 个接入点插件中 8 个 `.uplugin` 仍标 `IsExperimentalVersion: true`（Mass 全家含 MassAI/MassCrowd/MassGameplay）。
- **影响**：二开 Avalanche 走 Behavior 接口；Mass 生态的实验标记是决策事实。
- **迁移动作**：Avalanche 定制改 `IAvaTransitionBehavior`；引用 Mass 集成时注明实验状态。
- **证据**：【11-integrations.md §7】。

---

## 6. 升级检查清单（升级到 >5.8 时逐项核对）

对照新版源码逐项核实下表锚点；全部核实后再更新本文档各节与行内标记。路径相对 `E:\UnrealEngine\UE_5.8\`（行号为 5.8.0 基线）。

| # | 核对锚点（API/文件/宏） | 5.8 基线位置 | 核对内容 |
|---|---|---|---|
| 1 | `STATETREE_POD_INSTANCEDATA` / `UE_STATETREE_CONSTRUCTED_|ZEROED_TRIVIALLY_COPIED_NO_DESTRUCTOR_INSTANCEDATA` | RM\Public\StateTreeTypes.h L1349-1388 | 旧宏是否物理移除；新宏名是否再变 |
| 2 | `FStateTreePropertyRefExternalHandle` / `GetPtrFromStrongExecutionContext` / `GetPtrTupleFromStrongExecutionContext` | RM\Public\StateTreePropertyRef.h L152-186/L294-366 | ExternalHandle 是否删除；Strong 取值签名 |
| 3 | `FStateTreeWeakExecutionContext` / `MakeWeakExecutionContext` / `MakeStrongExecutionContext` / `CopyInputBindings`/`CopyOutputBindings` | RM\Public\StateTreeAsyncExecutionContext.h | Weak/Strong API 面是否扩改 |
| 4 | `UE::StateTree::EComparisonOperator` / `EGenericAICheck` | RM\Public\StateTreeTypes.h L59-68；StateTreeCommonConditions.h | 旧枚举是否移除；AIModule Public 依赖是否兑现 @TODO 私有化（RM Build.cs） |
| 5 | `UE_ENABLE_INCLUDE_ORDER_DEPRECATED_IN_5_6` / `_IN_5_8` 守卫 | StateTreeTypes.h L5-7、StateTreeCommonConditions.h L5-7、StateTreeExecutionContext.h L15-17、MassAIBehavior\MassStateTree*.h | 守卫版本推进；被包裹 include 是否删除 |
| 6 | `FStartParameters`（`InitialGlobalParameters`/`SelectStateOverrideArgs`） | RM\Public\StateTreeExecutionContext.h L454-464 | Start 重载是否再收拢；OverrideArgs 是否转正（O6） |
| 7 | `FSelectStateResult` 贯穿签名 | StateTreeExecutionContext.h L839-880/L1215-1240 | EnterState/ExitState/UpdateInstanceData/CaptureNewStateEvents/MakeRecordedTransitionResult/SelectState |
| 8 | `FStateTreeTasksCompletionStatus` / `UE::StateTree::FFinishedTask` | RM\Public\StateTreeTasksStatus.h L44-298；StateTreeExecutionTypes.h L749-781 | FFinishedTask 是否物理移除 |
| 9 | `FActiveFrameID`/`FActiveStateID`/`SourceFrameID`/`SourceStateID` | StateTreeExecutionTypes.h L288-303；StateTreeStatePath.h L17-70 | 身份体系是否再变 |
| 10 | 事件队列上限 `MaxActiveEvents = 64` | RM\Public\StateTreeEvents.h L181（本文件亲核） | 常量与溢出行为 |
| 11 | Tick 重规划轮数 `MaxIterations = 5` | RM\Private\StateTreeExecutionContext.cpp（TickTriggerTransitionsInternal） | 上限取值与语义（引入版本未证实，O8 附近） |
| 12 | `WITH_STATETREE_TRACE` / `WITH_STATETREE_TRACE_DEBUGGER` / `WITH_STATETREE_DEBUG` / `UE_WITH_STATETREE_CRASHREPORTER` | RM\StateTreeModule.Build.cs L15-16（`StateTreeModuleBase::SetupStateTreeDebuggingSupport` 统一配置） | 开关条件（UEFN/Shipping Editor） |
| 13 | Trace `Output*` 11 函数签名 | RM\Public\StateTreeTrace.h L118-139 | `TNotNull<const FStateTreeReadOnlyExecutionContext*>` 形态；弃用残体是否清除 |
| 14 | `FScrubState` / `FStateTreeDebugger` / `IStateTreeTraceProvider::GetInstances` | StateTreeDebuggerTypes.h L194-208；StateTreeDebugger.h | 多集合是否回归；签名是否再变 |
| 15 | `IRewindDebuggerRuntimeExtension` / `IRewindDebuggerTrackCreator`（`FObjectId`） | Engine\Source\Runtime\RewindDebuggerRuntimeInterface\Public\IRewindDebuggerRuntimeExtension.h L38-82；RewindDebuggerInterface\Public\IRewindDebuggerTrackCreator.h L67-90 | 录制钩子接口面（O4） |
| 16 | `UE::StateTree::Compiler::FCompilerManager` | EM\Private\StateTreeCompilerManager.cpp L307-320 | 编译触发中枢与 pimpl 订阅集是否不变 |
| 17 | `UStateTreeEditingSubsystem` / `UE::StateTree::Delegates::OnRequestCompile` | RM\Public\StateTreeDelegates.h L70-76 | 旧委托是否移除 |
| 18 | `FStateTreeTransition::AddConditionWithOuter` / `RequiredEvent` / `ReactivateTargetState` | EM\Public\StateTreeState.h L27-42/L95-197 | Builder API 面 |
| 19 | `UStateTree::IsEditorDataDirty` / `CompileStatus` | RM\Public\StateTree.h | 编辑态脏/编译状态查询 |
| 20 | `UStateTreeEditorData::UpdateBindings()` | EM\Public\StateTreeEditorData.h L254-261（亲核） | 现行绑定刷新 API 名（弃用消息 "UpdateEditorBindings" 为笔误） |
| 21 | `GetAccessibleStructsInExecutionPath` / `RootParameterPropertyBag` | EM\Public\StateTreeEditorData.h L215/L405 | 编辑态绑定访问与根参数 |
| 22 | `ScheduleNextTick(…, FNextTickArguments)` / `OnBeginApplyTransition` | RM\Public\StateTreeExecutionExtension.h L53-80 | Extension 钩子面（O5） |
| 23 | `FStateTreeLinker` 构造 | RM\Public\StateTreeLinker.h L26-31 | 构造参数（StateTree 指针） |
| 24 | `FStateTreeCustomVersion` / `FStateTreeInstanceStorageCustomVersion` GUID | RM\Public\StateTree.h L23-81；StateTreeInstanceData.h L125 | 旧资产兼容通道是否保留（O10） |
| 25 | `FStateTreeReference::GetGlobalParameters()` / `GetParameters()` | RM\Public\StateTreeReference.h L47/L61 | FConstStructView 形态是否统一 |
| 26 | `UStateTreeComponent` 模块归属 / Schema / Start 形态 | GS\Public\Components\StateTreeComponent.h | 归属与宿主 API（归属时间线见 §2，勿写死变迁） |
| 27 | 编辑器 CVar `StateTree.Compiler.*`（16 个唯一名称 = 15 CVar + 1 命令 FlushCompilationQueue，其中 4 个参与 cook `ClassSchemaVersion=6`） | 声明文件：EM\Private\StateTreeEditorData.cpp L36、StateTreeEditorModule.cpp L63、StateTreeEditingSubsystem.cpp L25；定义区锚点 StateTreeCompiler.cpp L63-110 + StateTreeCompilerManager.cpp L26-75 | 开关集与 cook schema 版本 |
| 28 | 组件 CVar `StateTree.Component.ScheduledTickEnabled` / `StateTree.Component.DefaultScheduledTickAllowed` | GS（进程级开关） | 全局 tick 行为开关 |
| 29 | `StateTree.Editor.Experimental.EnableStateCentricView` | EM（StateCentricViewSettings.cpp L9-14） | 实验视图状态（引入版本 O12） |
| 30 | `StateTree.TargetStateRequiresTheSameEventForStateSelectionAsTheRequestedTransition`（默认 false） | RM\Private\StateTreeExecutionContext.cpp | 事件匹配语义默认值（历史行为归属未证实，O8） |

---

## 7. 开放问题（引入版本未证实条目汇总）

以下条目在 5.8.0 单版本源码内无法确证引入版本，引用时保留「未证实」标注；拿到旧版源码或 GitHub 历史后回填本文件。

- **O1**：Blueprint 任务 FinishTask 范式（`ReceiveEnterState/ReceiveTick` → `ReceiveLatentEnterState/ReceiveLatentTick` + `FinishTask`，配套 `bHasEnterState_DEPRECATED/bHasTick_DEPRECATED`）的确切引入版本：UE_DEPRECATED(all) 无版本号【04-nodes-builtin.md §7/§8.2-1；证据 RM\Public\Blueprint\StateTreeTaskBlueprintBase.h L70-76/L160-163】。
- **O2**：Considerations（效用评分）/PropertyFunctions 两族节点的引入版本（推断 5.5 前后随效用系统加入，未逐项核实）【00 §7；04 §8.2-2】。
- **O3**：MassStateTree 并入 MassAIBehavior 的确切版本（`MassStateTree*.h` 头文件名为历史残留）；PropertyBindingUtils 插件由旧名更名的版本【00 §8-1；05 §8.2-3】。
- **O4**：`IRewindDebuggerRuntimeExtension` 是否 5.8 新增（头文件 5.8 弃用守卫 + 弃用说明指向它，本地无 5.7 源码比对）【10 §7/§8-1】。
- **O5**：`FStateTreeExecutionExtension::OnBeginApplyTransition` 是否 5.8 新增（无 5.7 对照）【11-integrations.md §7/§8-2】。
- **O6**：`FStartParameters::SelectStateOverrideArgs` 与 `UStateTree::GetStateHandleFromGameplayTag`（`EStateGameplayTagQueryMethod`）引入版本（5.8 无标记无注释，推测 5.8 新能力，需 GitHub 历史）【01-core-execution.md §8.2-1】。
- **O7**：`EStateTreeRecordTransitions` + `UStateTree::GetRecordedTransitions()` + `ForceTransition(FRecordedStateTreeTransitionResult)` 的精确引入版本（5.7/5.8 Trace/回放配套 API，5.6 之前无此形态）【12-tests.md §7-3；StateTreeTestTypes.h:45-51】。
- **O8**：`EStateTreeUpdatePhase::StartGlobalTasksForSelection/StopGlobalTasksForSelection` 两值与 `CurrentPhase` 重入护栏的引入版本（推测 5.7 选择期全局节点机制同期）；CVar `StateTree.TargetStateRequiresTheSameEventForStateSelectionAsTheRequestedTransition` 对应的历史行为归属版本【01 §7/§8.2-2/4】。
- **O9**：`FCompilerManager` 引入的准确小版本（5.7.0 或 5.7 内 hotfix；判定基于 5.8 弃用注释 + 官方 API 文档页面存在性）【08-editor-compiler.md §7.1/§8.4-1】。
- **O10**：`FStateTreeCustomVersion` 20 个枚举项（LatestVersion=19）与 UE 版本的精确映射（仅 AddedExternalTransitions/OverridableParameters 有迁移代码锚定）；弃用注释所指 "stream custom version" 替代物在 5.8 源码内未见注册【02-asset-types.md §8.2-1/3；08 §8.1】。
- **O11**：`FStateTreePropertyRefExternalHandle` 体系的引入版本（仅证实 5.8 弃用）【05-property-bindings.md §8.2-4】。
- **O12**：StateCentricView 的引入版本（5.8 中存在且 Experimental；CVar `StateTree.Editor.Experimental.EnableStateCentricView`）【09-editor-ui.md §7/§8-1】。
- **O13**：`EStateTreeStateSelectionRules`/`EStateTreeTransitionPriority`/`EStateTreeSelectionFallback`/`FCompactEventDesc` 等非弃用类型的精确引入版本（仅能确认 5.8 现行形态）【02-asset-types.md §8.2-5】。
