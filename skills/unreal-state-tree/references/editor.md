# StateTree 编辑器：编辑数据、编译管线与编辑器架构

> 版本基线：UE 5.8.0 (Release-5.8, CL 55116800) · 版本标记约定：**[UE 5.x+]**=该版本新增，**[仅 <5.x]**=已移除/旧行为，**[5.8 变更]**=本版变更；现行 API 判定标准=声明无 UE_DEPRECATED 标记。

## TL;DR

- 编辑数据三层：`UStateTree`（资产）→ `UStateTreeEditorData`（Schema + 根参数 + 全局节点 + EditorBindings + SubTrees）→ `UStateTreeState` 状态树；每个节点/条件/任务由 `FStateTreeEditorNode` 包装（3 个 FInstancedStruct + 确定性 ID）。
- 编译是两段：`FStateTreeCompiler::CompilePublic`（PreCompile 清场 + CreateParameters）→ `CompileInternalImpl` 14 步序列（拷 Schema → 建状态/节点/转换/考量 → 五容器落盘 → `UStateTree::Link()` → ID 映射 → NotifyInternalPost）。
- **[UE 5.7+]** `UE::StateTree::Compiler::FCompilerManager`（静态门面 + pimpl）：`QueueForCompilation` 同步编 Public 步、Internal 步经 `FTSTicker` 每帧一批；接管 PIE flush、cook、BP/UDS 重实例化 relink；编译前按资产间依赖递归排序。
- dirty = `EDirtyStatus`（编辑数据变了什么）× `ECompileStatus`（编译/链接进度或失败）+ `bCompilationPending`（在队列中）+ 编辑器数据 CRC32 hash 兜底。
- 编程面：`UStateTreeEditorData`/`UStateTreeState` Builder API + `UStateTreeEditingSubsystem::CompileStateTree` + `UStateTreeCompileAllCommandlet` 批量编译。
- UI 是"一个 ViewModel 驱动多视图"：`FStateTreeViewModel` 按资产共享（`UStateTreeEditingSubsystem::FindOrAddViewModel`），9 个多播委托驱动 `SStateTreeView`/`SStateTreeOutliner`/Diff/Debugger；StateCentricView 为 Experimental（CVar 默认关）。
- 绑定 UI 无专用面板：`FStateTreeBindingExtension` 经 `FStateTreeEditorModule::SetDetailPropertyHandlers`（公开静态 API）挂到任意 DetailsView，四类绑定 + 复制粘贴。
- 蓝图边界：`UK2Node_MakeStateTreeReference` 动态参数引脚 + `UStateTreeFunctionLibrary` 4 函数；BP 可写节点（4 个 BlueprintBase 基类），**不能直接执行 StateTree**。
- Diff 有（结构/绑定/Details 三层）、Merge 无、Find 仅资产内；`FStandaloneStateTreeEditorHost` 是编辑器内 host 抽象（`IStateTreeEditorHost`），不是"编辑器外运行"。

## 目录

1. 阅读约定与模块边界
2. 编辑数据三层模型
3. 两段编译（FStateTreeCompiler）
4. FCompilerManager 编译队列 **[UE 5.7+]**
5. dirty 状态机
6. FStateTreeCompilerLog
7. 编辑器 Compile 链路与编程面
8. StateTree.Compiler CVar 全表
9. 弃用 API 单列
10. 编辑器 UI 架构（ViewModel）
11. 绑定 UI
12. 蓝图边界
13. Diff / Merge / Find
14. 编辑宿主与"编辑器外调试"正名
15. 编辑器扩展点清单
16. 注意事项与坑
17. 开放问题

## 1. 阅读约定与模块边界

- 路径缩写：**EM** = `E:\UnrealEngine\UE_5.8\Engine\Plugins\Runtime\StateTree\Source\StateTreeEditorModule`；**RM** = 同插件下 `Source\StateTreeModule`。证据标注 `【源码 EM\...】`= 本机 5.8 源码直接证实；`【推断】`= 合理推断。
- 分工边界：绑定**运行时**语义 → property-bindings.md；CustomVersion 序列化契约 → assets-types.md；编辑器扩展**操作步骤** → customization-guide.md（本文只讲机制）；编辑器外调试/Trace → debugging-trace.md；运行宿主组件 → gameplay-state-tree.md。

## 2. 编辑数据三层模型

| 层 | 类型 | 职责 |
|---|---|---|
| 资产 | `UStateTree : UDataAsset` | 运行时编译产物容器；`WITH_EDITORONLY_DATA EditorData: TObjectPtr<UObject>` 指向编辑数据（编译产物字段见 assets-types.md） |
| 编辑数据 | `UStateTreeEditorData`（Within="StateTree"，实现 `IStateTreeEditorPropertyBindingsOwner`） | 编辑态全部数据 + Builder API + 标脏/修复/遍历【源码 EM\Public\StateTreeEditorData.h L64-457】 |
| 状态节点 | `UStateTreeState : UObject, IStateTreeSchemaProvider` | 编辑期状态树节点；父子双向指针由 `UStateTreeEditorData::ReparentStates()` 修复【源码 EM\Public\StateTreeState.h L242-517】 |

`UStateTreeEditorData` 关键成员：

| 成员 | 说明 |
|---|---|
| `Schema: TObjectPtr<UStateTreeSchema>` | 数据 Schema（ContextDataDescs、允许的节点等） |
| `EditorSchema: TObjectPtr<UStateTreeEditorSchema>` | 编辑规则 Schema（校验/编译尾回调，§15 扩展点） |
| `Extensions: TArray<TObjectPtr<UStateTreeEditorDataExtension>>` | 资产级扩展位 |
| `RootParametersGuid` + `RootParameterPropertyBag` | 树级公共参数（**[5.8 变更]** 前 5.6 已 PropertyBag 化；旧 `RootParameters` 属性已弃用） |
| `Evaluators` / `GlobalTasks: TArray<FStateTreeEditorNode>` | 全局评估器 / 全局任务 |
| `GlobalTasksCompletion: EStateTreeTaskCompletionType` | 全局任务完成合成方式 |
| `EditorBindings: FStateTreeEditorPropertyBindings` | 编辑期绑定集合（§11） |
| `Colors: TSet<FStateTreeEditorColor>` | 主题色 |
| `SubTrees: TArray<TObjectPtr<UStateTreeState>>` | 状态树根（"Root" 主树 + 可复用 Subtree） |
| `Breakpoints`（Transient）/ `CompiledDispatchers`（DuplicateTransient） | 断点 / 编译后 dispatcher 缓存（跨编译确定性 ID，配合 delta cook） |

`UStateTreeState` 关键属性：`Name/Tag/ColorRef/Type(EStateTreeStateType)/SelectionBehavior/TasksCompletion/LinkedSubtree/LinkedAsset/CustomTickRate/Parameters(FStateTreeStateParameters)/RequiredEventToEnter/Weight(效用权重)/EnterConditions/Tasks/Considerations/SingleTask/Transitions/Children/ID/bEnabled`；编译完成经订阅 `UE::StateTree::Delegates::OnPostCompile` 回调 `UStateTreeState::OnTreeCompiled`【源码 StateTreeState.h L515-516】。

`FStateTreeEditorNode`（节点/条件/任务的统一包装）【源码 EM\Public\StateTreeEditorNode.h L26-165】：

| 成员 | 说明 |
|---|---|
| `Node: FInstancedStruct` | 节点模板本体（`FStateTreeNodeBase` 派生：Condition/Task/Evaluator/Consideration/PropertyFunction） |
| `Instance: FInstancedStruct` + `InstanceObject: TObjectPtr<UObject>` | 节点实例数据（非 UObject 与 UObject 二选一，`GetInstance()` 统一为 `FStateTreeDataView`） |
| `ExecutionRuntimeData`(+`Object`) | 执行期运行数据模板 |
| `ID` + 确定性派生 ID | `GetNodeID() = FGuid::Combine(ID, "Node Struct")`、`GetInstanceDataID() = ID`；转换/状态另有 `GetEventID()`【源码 StateTreeState.h L123-126, 389-392】 |
| `ExpressionIndent: uint8` + `ExpressionOperand`(And/Or) | 条件树扁平化存储 |
| `InitializeAs<T>(Outer, ...)` / `ReallocInstanceData` / `FixObjectInstances(SeenObjects, Outer)` | 初始化 / 实例重分配 / 粘贴时共享 UObject 去重 |

编辑绑定模型：`FStateTreeEditorPropertyBindings : FPropertyBindingBindingCollection` 持 `TArray<FStateTreePropertyPathBinding>`，提供 `AddFunctionBinding`（PropertyFunction）/`AddOutputBinding`（输出写回）/`AddTaskCompletionBinding`（任务完成→dispatcher）与依赖收集 `GatherDependencies/IsDependentOn`；`FStateTreeBindingLookup : IStateTreeBindingLookup` 把 owner 适配成非编辑器代码可用的查询接口【源码 EM\Public\StateTreeEditorPropertyBindings.h L167-182】。绑定运行时消费 → property-bindings.md。

## 3. 两段编译（FStateTreeCompiler）

入口 API（`FStateTreeCompiler`，构造需传 `FStateTreeCompilerLog&`）【源码 EM\Public\StateTreeCompiler.h L48-70】：

| API | 语义 |
|---|---|
| `CompilePublic(TNotNull<UStateTree*>)` | 只编 Public 步 |
| `CompileInternal(TNotNull<UStateTree*>)` | 先 `CompilePublic` 再 `CompileInternalImpl` |
| `Compile(TNotNull<UStateTree*>)` / `Compile(UStateTree&)` | 等价 `CompileInternal` |
| `static CheckCompiledStateTreeOuters(TNotNull<const UStateTree*>, FStateTreeCompilerLog&)` | 编译产物 outer 校验 |
| `static AppendToStateTreeClassSchema(FAppendToClassSchemaContext&)` | cook class schema 贡献（§3.4） |

编译器实例**一次性**：重复执行报 "Internal error. The compiler has already been executed. Create a new compiler instance."【源码 StateTreeCompiler.cpp L466-473】。

### 3.1 Public 步（CompilePublic，L506-524）

1. `PreCompile`（L466-504）：`UStateTree::ResetCompiled()`（清产物 + 旧产物 Rename 到 transient 包）；校验 `EditorData`/`Schema` 存在；`FStateTreePropertyBindingCompiler::Init(StateTree->PropertyBindings, Log)`；`UStateTreeEditorData::GetAllStructValues(IDToStructValue)`；编辑绑定按 TargetStructID 建多重映射。
2. `CreateParameters`（L752-810）：复制 `EditorData->GetRootParametersPropertyBag()` → `UStateTree::Parameters`（`Schema->GetGlobalParameterDataType()` 决定 `ParameterDataType` 与 `FStateTreeDataHandle` 的数据源标注 GlobalParameterData vs ExternalGlobalParameterData）；根参数注册为绑定源；`ValidateNoLevelActorReferences`（禁止直接引用关卡 Actor）；可选编译参数上的委托 dispatcher 绑定（CVar `StateTree.Compiler.EnableParameterDelegateDispatcherBinding` 默认 false）。
3. 成功 → `CompileStatus=Internal`、`Dirty=Internal`。

### 3.2 Internal 步（CompileInternalImpl，L526-678；失败各步统一 `FailCompilation(ECompileStatus::Internal)`）

| # | 步骤 | 要点 |
|---|---|---|
| 1 | `DuplicateObject(EditorData->Schema, StateTree)` | 运行时资产持有独立 Schema 副本（L534） |
| 2 | `Schema->GetContextDataDescs()` | 逐个注册 Context 绑定源；`IsValidIndex16(NumContextData)` 校验 |
| 3 | `GatherBindingSources()`（L736-750） | 收集任务完成 dispatcher 的 struct ID 集合 |
| 4 | `CreateStates → CreateStateRecursive`（L812-988） | 建 `FCompactStateTreeState`；主树先编（跳过 Subtree 类型根）再编 Subtree 根；根状态开新 `FCompactStateTreeFrame`；Linked/LinkedAsset 状态带子状态给 Warning |
| 5 | `CreateEvaluators`(L1015) / `CreateGlobalTasks`(L1052) | 全局节点进 `Nodes`/`InstanceStructs`；`GlobalTaskEndBit` 完成掩码由 `MakeCompletionTasksMask` 计算 |
| 6 | `CreateStateTasksAndParameters`（L1120-1422） | 深度优先建 `FCompactStateTreeParameters`；RequiredEvent 数据位；深度上限（`FStateTreeActiveStates::MaxStates`）；任务实例与完成掩码位分配；注册绑定源/建绑定 |
| 7 | `CreateStateEnterConditions`(L1422) / `CreateStateTransitions`(L1478) | 转换目标 `ResolveTransitionStateAndFallback`（L2326）；条件按 `ExpressionOperand/ExpressionIndent` 展平创建 |
| 8 | `CreateStateConsiderations`(L1841) | 效用考量节点（`CreateConsideration` L2523） |
| 9 | 五容器落盘（L615-619） | 见 §3.3 |
| 10 | `CreateTaskCompletionDispatchers`(L2279) → `EditorData->CompiledDispatchers` → `BindingsCompiler.Finalize()` | 跨编译确定性 ID（delta cook）（L626-629） |
| 11 | `UStateTree::Link()` | 运行时侧引用解析；失败 → FailCompilation(Link) |
| 12 | 写三套调试映射 | `IDToNodeMappings/IDToStateMappings/IDToTransitionMappings`（L641-660） |
| 13 | `NotifyInternalPost()`（L3225-3289） | 按"模块 → EditorSchema → Extensions"广播 `FStateTreeEditorModule::OnPostInternalCompile()` → `UStateTreeEditorSchema::HandlePostInternalCompile` → 每个 `UStateTreeEditorDataExtension::HandlePostInternalCompile`；任一失败即编译失败 |
| 14 | 可选收尾 | CVar `StateTree.Compiler.bEnableCheckOutersOnCompilationSucceeded`（默认 false）→ `CheckCompiledStateTreeOuters`；CVar `...LogResultOnCompilationCompleted` → `DebugInternalLayoutAsString()` 输出 |

节点实例化细节：`CreateNode/CreateNodeWithSharedInstanceData/CreateNodeInstanceData`（L2100-2278）把编辑节点模板拷入 `Nodes`，实例数据按 `FStateTreeDataHandle` 归入三容器之一；UObject 型实例在 `InstantiateStructSubobjects`（L3191-3223）中 Duplicate 并把 outer 从 EditorData 改挂到 StateTree（防止引用编辑专属数据）；`CompileAndValidateNode`（L2553）调用节点 `Compile(FCompileNodeContext)` 自校验并检查 Level Actor 引用。

### 3.3 五容器落盘

| 编辑器侧集合 | 运行时产物容器 |
|---|---|
| `Nodes` | `UStateTree::Nodes` |
| `InstanceStructs` | `UStateTree::DefaultInstanceData` |
| `SharedInstanceStructs` | `UStateTree::SharedInstanceData` |
| `EvaluationScopeStructs` | `UStateTree::DefaultEvaluationScopeInstanceData` |
| `ExecutionRuntimeStructs` | `UStateTree::DefaultExecutionRuntimeData` |

SharedInstance vs EvaluationScope 归属由 3 个 CVar 决定（`...EnableCondition/PropertyFunction/UtilityConsiderationWithEvaluationScopeInstanceData`，默认全部走 EvaluationScope；SharedInstance 为旧路径）【源码 StateTreeCompiler.cpp L76-96】。

### 3.4 Cook 集成

`FStateTreeCompiler::AppendToStateTreeClassSchema`（L436-451）把 `ClassSchemaVersion = 6`（仅编译器行为变化才 bump）与 4 个影响编译产物的 CVar 值写入 class schema——cook 机器上下文不同则触发重 cook。调用链：`UStateTree::AppendToClassSchema` → Private 委托 `OnAppendToClassSchema` → `FStateTreeEditorModule::HandleAppendToStateTreeClassSchema`【源码 RM\Public\StateTree.h L410 + EM\Private\StateTreeEditorModule.cpp L418-421】。序列化版本契约 → assets-types.md。

### 3.5 编译前校验安全网：UStateTreeEditingSubsystem::ValidateStateTree

每次编译前执行（`CompilePublicSynchronously`/`CompileInternalSynchronously` 均调用）【源码 EM\Private\StateTreeEditingSubsystem.cpp L121-384】：

1. `FixEditorData`：EditorData 缺失/类型不符则新建或 `DuplicateObject` 转换为注册的 EditorData 子类（旧对象改名 `TRASH_<name>` 移入 transient 包）。
2. `FixEditorSchema`：同理保证 `EditorSchema` 类型匹配。
3. Pre 校验广播：`OnPreValidateStateTree` → `EditorSchema->PreValidate` → `Extension->PreValidate`。
4. 数据修复：`ReparentStates` → `FixDuplicateIDs` → `RemoveInvalidBindings` → `UpdateBindings`（重解析绑定路径含 redirect）→ `ValidateLinkedStates` → `UpdateLinkedStateParameters` → `UpdateTransactionalFlags` → 清空 Extension。
5. 校验广播：`OnValidateStateTree` → `EditorSchema->Validate`（基类按数据 Schema 清不允许的节点）→ `Extension->Validate` → 再清空 Extension。

全程 `Modify(bMarkDirty=false)` 不产生事务——它是"编辑器操作后的兜底修复"，不是用户可见校验报告。

## 4. FCompilerManager 编译队列 **[UE 5.7+]**

`UE::StateTree::Compiler::FCompilerManager`（全静态门面，头文件 EM\Public\StateTreeCompilerManager.h）+ pimpl `FCompilerManagerImpl`（同 cpp 内，全局单例；`FStateTreeEditorModule::StartupModule/ShutdownModule` 启停）【源码 EM\Private\StateTreeCompilerManager.cpp L221-304】。5.7 证据链：`UStateTree` 三个编辑器委托字段整体 `UE_DEPRECATED(5.7)` 且消息明说 "Use the compiler manager."【源码 RM\Public\StateTree.h L360-391】。

公开 API：

| API | 语义 |
|---|---|
| `static Startup()/Shutdown()` | 模块启停时接线/断开外部事件 |
| `static QueueForCompilation(TNotNull<UStateTree*>)` | 先 `CompilePublicSynchronously`（ValidateStateTree + CompilePublic），Internal 步入队；约束 game thread 或 async loading thread；`Schema->AllowQueuedCompilation()` 为 false（如 Mass 类任意线程宿主）或 PIE 期间禁排队时退化为 `CompileInternalSynchronously` |
| `static FlushCompilationQueue()` | game thread only；循环弹出全部队列同步编完（不分帧） |
| `static CompileSynchronously(TNotNull<UStateTree*>, [FStateTreeCompilerLog&])` | ValidateStateTree → 依赖排序 → 全量同步编译；返回 `CompileStatus==Executable` |
| `static TOptional<bool> CompileIfNeededSynchronously(TNotNull<UStateTree*>)` | 仅 `bCompilationPending || NeedsRecompile()`（hash 兜底）才编译；空 Optional=无需编译 |
| `static MarkAsModified(TNotNull<UStateTree*>)` | 加入跟踪集合（真正 dirty 位由 `UStateTree::MarkAsModified` 经 Private 委托 `OnStateTreeMarkedAsModified` 联动） |
| `static CacheEditorBindingExternalDependencies(TNotNull<UStateTreeEditorData*>)` | 缓存编辑绑定的外部 struct 依赖，供 BP/UDS 重实例化反向查找受影响树 |

队列消费：`AddToQueue_AnyThread`（去重，置 `bCompilationPending=true`）→ `FTSTicker` 一次性 ticker → 每 tick 弹出资产直到 `StateTree.Compiler.NumberOfQueuedCompilationPerBatch`（默认 1），未完下帧继续【源码 L506-536】。依赖排序：`CompileWithQueueImpl_AnyThread`（L551-594）——资产经 LinkedAsset/并行子树任务互相依赖，`GatherStateTreeDependencies_AnyThread` 递归先编 dirty 依赖，循环依赖打 Warning。

自动触发接线（`FCompilerManagerImpl` 构造订阅）：

| 外部事件 | 处理 |
|---|---|
| `FEditorDelegates::PreBeginPIE` | 收集 dirty 资产（缓存列表或 TObjectIterator，CVar `...EnableCompileAllIfChangedOnBeginPIE_UseCachedList`）→ 逐个 `QueueForCompilation` → `FlushCompilationQueue()`（PIE 开始前必须全部 Executable） |
| `FEditorDelegates::EndPIE` | 恢复排队许可 |
| `FCoreUObjectDelegates::OnObjectsReinstanced`（BP 重编译） | 修复编辑绑定路径；按依赖缓存精确 relink 受影响树（CVar `...UseDependenciesToTriggerCompilation` 默认 true），否则全遍历判定；Link 失败 `MarkAsModified(false)` 以便重试 |
| `UE::StructUtils::Delegates::OnUserDefinedStructReinstanced` | 同上（UDS 只需 relink 绑定内存位置） |
| Private `OnPreCookStateTreeAsset`（`UStateTree::BeginCacheForCookedPlatformData` 触发） | dirty 按 CompileStatus 分支同步编译或只重 Link；最终非 Executable → Error log |

资产加载时机：`UStateTree::PostLoad` → `CompileStatus=Link` + `ResetCompiled()` → `OnStateTreeAssetLoaded` → CVar `StateTree.Compiler.EnableQueuedCompilationOnAssetLoad`（**默认 false**=加载即同步编译）决定排队或同步【源码 RM\Private\StateTree.cpp L490-570 + EM\Private\StateTreeEditorModule.cpp L52-67】。

## 5. dirty 状态机

两个独立枚举 + 一个标志位【源码 RM\Public\StateTree.h L571-606】：

| 状态 | 语义 |
|---|---|
| `EDirtyStatus { Public, Internal, Link, None }`（WITH_EDITORONLY_DATA） | 编辑数据变了什么：Public=公开产出依赖变了（根参数/Schema 类，影响引用本资产的其他资产）；Internal=内部节点/属性变了；Link=有绑定的内部依赖变了；注释明确"编译后（无论成败）dirty 回到 none" |
| `ECompileStatus { Public, Internal, Link, Executable }` | 编译/链接进度或失败（运行时可查 `UStateTree::CompileStatus`）；失败但数据未变时 dirty 归零，由 CompileStatus 表达失败 |
| `bCompilationPending` | 资产已在编译队列等待 |

关键迁移：标脏 `UStateTree::MarkAsModified(bPubliclyModified)`（RM\Private\StateTree.cpp L374-390，Public 或 Internal）→ `OnStateTreeMarkedAsModified` → CompilerManager 跟踪；编辑器包装 `UStateTreeEditingSubsystem::MarkAsPubliclyModified/MarkAsModified`。清脏：`FailCompilation`（Dirty=None + `LastCompiledEditorDataHash=0` + CompileStatus=失败阶段）；Public 步成功 → Dirty=Internal；Internal 步成功 → Dirty=Link；`UStateTree::Link()` 成功 → Executable + Dirty=None。查询：`UStateTree::IsEditorDataDirty()`；`UStateTreeEditingSubsystem::NeedsRecompile`（Dirty 不匹配时用 `FStateTreeObjectCRC32(EditorData)` hash 兜底，CVar `...UseHashToDetermineIfAssetNeedsCompile` 默认 true）【源码 EM\Private\StateTreeEditingSubsystem.cpp L23-58】。

标脏源（4 类）：① `FStateTreeViewModel` 全部编辑操作（16+ 处调用）【源码 EM\Private\StateTreeViewModel.cpp】；② `UStateTreeEditorData::PostEditChangeChainProperty`（Schema/EditorSchema/根参数变 → Public，其余 → Internal；Evaluator/GlobalTask 复制换新 ID + CopyBindings）【源码 StateTreeEditorData.cpp L229-328】；③ Builder API 添加节点 `OnNodeAdded`；④ `UStateTree::Link()` 失败 → `MarkAsModified(false)` 重试。

## 6. FStateTreeCompilerLog

编译消息日志（状态栈 + 消息列表）【源码 EM\Public\StateTreeCompilerLog.h】：

| API | 用途 |
|---|---|
| `PushState(const UStateTreeState*)` / `PopState` / RAII `FStateTreeCompilerLogStateScope` | 消息归属状态上下文栈 |
| `Report(EMessageSeverity::Type, const FStateTreeBindableStructDesc&, const FString&)` / `Reportf(...)` | 报消息（可带节点上下文） |
| `ToTokenizedMessages()` / `AppendToLog(IMessageLogListing*)` | 输出到 MessageLog |
| `DumpToLog(const FLogCategoryBase&)` / `DumpToLog(const UStateTree*, const FLogCategoryBase&)` | 输出到输出日志 |
| `FStateTreeCompilerLogMessage{Severity, State, Item, Message}` | 消息结构 |

编译结果 UI：`FStateTreeEditorMode` 创建 MessageLog（tab 名经 `IStateTreeEditorHost::GetCompilerLogName/GetCompilerTabName`），编译失败时条目可点击跳转对应状态（`FStateTreeViewModel::BringNodeToFocus`）。

## 7. 编辑器 Compile 链路与编程面

**编辑器按钮链路**：工具栏 Compile 按钮（图标反映 `UStateTree::IsEditorDataDirty/IsReadyToRun`，PIE 中 `CanCompile()=false`）→ `UStateTreeEditorMode::UpdateAsset` → `UStateTreeEditingSubsystem::ValidateStateTree` → `CompileStateTree`（转发 `FCompilerManager::CompileSynchronously`）→ `FStateTreeCompiler::CheckCompiledStateTreeOuters`（按钮路径无条件跑，CVar 开则跳过防重复）【源码 EM\Private\StateTreeEditorMode.cpp L440-451】→ MessageLog 展示 → 保存由 `UStateTreeEditorSettings::SaveOnCompile`（Never/SuccessOnly/Always）控制，`FStateTreeEditor::SaveAsset_Execute` 保存前先编译。

**编程面（三条路径）**：

| 路径 | 关键 API | 场景 |
|---|---|---|
| Builder API | `UStateTreeEditorData::AddSubTree/AddRootState/AddEvaluator<T>/AddGlobalTask<T>/AddPropertyBinding(...)`；`UStateTreeState::AddChildState/AddTask<T>/AddEnterCondition<T>/AddConsideration<T>/AddTransition(...)`【源码 EM\Public\StateTreeEditorData.h L266-368、StateTreeState.h】 | 程序化构建/修改资产（步骤 → customization-guide.md） |
| 编辑子系统 | `UStateTreeEditingSubsystem::CompileStateTree(TNotNull<UStateTree*>, FStateTreeCompilerLog&)`（公开推荐编译入口）、`ValidateStateTree`、`NeedsRecompile`、`MarkAsModified/MarkAsPubliclyModified`、`CalculateStateTreeHash` | 工具/自动化中的单资产编译与标脏 |
| Commandlet | `UStateTreeCompileAllCommandlet`：AssetRegistry 搜全部 UStateTree → 逐个编译 + SourceControl checkout（开关 `-nosourcecontrol`）+ 保存【源码 EM\Private\Commandlets\StateTreeCompileAllCommandlet.cpp】 | CI / 提交前批量重编译：`UnrealEditor-Cmd.exe <proj> -run=StateTreeCompileAllCommandlet` |

## 8. StateTree.Compiler CVar 全表

源码全量扫描（EM + RM + GameplayStateTreeModule）证实 **16 个**唯一名称（15 CVar + 1 命令 FlushCompilationQueue）【源码声明位置见表】；其中 4 个实例数据布局开关参与 cook class schema（§3.4）。

| CVar / 命令 | 默认 | 作用 | 声明 |
|---|---|---|---|
| `StateTree.Compiler.EnableBindingSelectionNodeToInstanceData` | true | 允许进入条件/考量/状态参数绑定到任务实例数据（任务实例数据在转换完成后才可用） | StateTreeEditorData.cpp L35-41 |
| `StateTree.Compiler.EnableParameterDelegateDispatcherBinding` | false | 允许根参数上的委托 dispatcher 绑定（实验） | StateTreeCompiler.cpp L71 |
| `StateTree.Compiler.EnablePropertyFunctionWithEvaluationScopeInstanceData` | true | PropertyFunction 实例数据走 EvaluationScope（false=旧 SharedInstance 路径） | StateTreeCompiler.cpp L78 |
| `StateTree.Compiler.EnableConditionWithEvaluationScopeInstanceData` | true | 条件同上 | StateTreeCompiler.cpp L86 |
| `StateTree.Compiler.EnableUtilityConsiderationWithEvaluationScopeInstanceData` | true | 考量同上 | StateTreeCompiler.cpp L93 |
| `StateTree.Compiler.bEnableCheckOutersOnCompilationSucceeded` | false | 编译成功后跑 `CheckCompiledStateTreeOuters` | StateTreeCompiler.cpp L100 |
| `StateTree.Compiler.LogResultOnCompilationCompleted` | false | 编译完成后输出内部布局 | StateTreeCompiler.cpp L107 |
| `StateTree.Compiler.LogDependenciesOnCompilation` | false | 编译时输出依赖图 | StateTreeCompilerManager.cpp L27 |
| `StateTree.Compiler.UseDependenciesToTriggerCompilation` | true | BP/UDS 重实例化按依赖缓存精确 relink（false=全遍历） | StateTreeCompilerManager.cpp L34 |
| `StateTree.Compiler.EnableForceCompileSynchronouslyInPIESession` | true | PIE 期间禁队列、全部同步编译 | StateTreeCompilerManager.cpp L41 |
| `StateTree.Compiler.EnableCompileAllIfChangedOnBeginPIE` | true | PIE 开始前编译全部 dirty 资产 | StateTreeCompilerManager.cpp L49 |
| `StateTree.Compiler.EnableCompileAllIfChangedOnBeginPIE_UseCachedList` | true | 上述收集用缓存列表（false=TObjectIterator 全遍历） | StateTreeCompilerManager.cpp L56 |
| `StateTree.Compiler.NumberOfQueuedCompilationPerBatch` | 1 | 队列每帧批处理资产数 | StateTreeCompilerManager.cpp L63 |
| `StateTree.Compiler.FlushCompilationQueue` | （命令） | 立即同步编完队列 | StateTreeCompilerManager.cpp L69 |
| `StateTree.Compiler.EnableQueuedCompilationOnAssetLoad` | false | 资产 PostLoad 后排队编译（false=加载即同步编译） | StateTreeEditorModule.cpp L62-63 |
| `StateTree.Compiler.UseHashToDetermineIfAssetNeedsCompile` | true | `NeedsRecompile` 用 CRC32 hash 兜底比对 | StateTreeEditingSubsystem.cpp L24-25 |

编辑器 UI 侧开关（非 Compiler 前缀）：`StateTree.Editor.Experimental.EnableStateCentricView`（默认 false，§10）。

## 9. 弃用 API 单列

本模块范围 + 直接相关运行时侧（现行替代均已核实存在；自定义版本契约细节 → assets-types.md）：

| 弃用 API | 弃用版本 | 替代品 |
|---|---|---|
| `UStateTreeDelegates::OnRequestCompile` | 5.8 | `UStateTreeEditingSubsystem`（编译触发收拢） |
| `UStateTreeEditorMode::EditorDataHash` / `bLastCompileSucceeded` 字段 | 5.8 | `UStateTree::IsEditorDataDirty` / `UStateTree::CompileStatus` |
| `FStateTreeTransition::AddCondition<T>()` | 5.8 | `AddConditionWithOuter<T>(TNotNull<UStateTreeState*>)` |
| `FStateTreeTransition::EventTag_DEPRECATED` | all | `RequiredEvent.Tag` |
| `UStateTreeEditorData::UpdateBindingsInstanceStructs()` | 5.8 | `UStateTreeEditorData::UpdateBindings()`（弃用消息写 "Use UpdateEditorBindings instead" 但公开 API 无此名，系消息笔误；已核源码 EM\Public\StateTreeEditorData.h L254-261，弃用函数体即转调 `UpdateBindings()`） |
| `UStateTreeEditorData::RootParameters` 属性 | 5.6 | `GetRootParametersPropertyBag()`（PostLoad 依 stream version 迁移） |
| `UStateTreeEditorData::GetAccessibleStruct(...)` | 5.6 | `GetAccessibleStructsInExecutionPath` |
| `FStateTreeViewModelInsert`（无 E 前缀枚举） | 5.6 | `EStateTreeViewModelInsert` |
| `FStateTreePropertyBindingCompiler::GetDispatcherIDFromPath(const FStateTreePropertyPath&)` | 5.6 | `FPropertyBindingPath` 参数版本 |
| `FStateTreeNodeClassData` FName 版构造 / `GetStructName()` | 5.7 | `FTopLevelAssetPath` 构造 / `GetStructPath()` |
| `FStateTreeEditorModule` 内 `OnUserDefinedStructReinstancedHandle` | 5.7 | 无（重实例化改由 `FCompilerManager` 处理） |
| `UStateTree::OnPreBeginPIE` + `OnObjectsReinstancedHandle` / `OnUserDefinedStructReinstancedHandle` / `OnPreBeginPIEHandle` 字段 | 5.7 | `UE::StateTree::Compiler::FCompilerManager` |
| `FStateTreeCustomVersion`（资产自定义版本结构体） | all | stream custom version（契约 → assets-types.md） |

## 10. 编辑器 UI 架构（ViewModel）

**一图**【源码 EM\Public\StateTreeViewModel.h L69-326、Private\StateTreeEditor.h L24-108】：

```
UStateTree (资产)
 └─ UStateTreeEditorData（编辑数据）
      │ 被 UStateTreeEditingSubsystem::FindOrAddViewModel 按资产包装为共享实例
      ▼
FStateTreeViewModel（9 个多播委托 + 全部编辑操作）
  ├─ FStateTreeTransitionViewModel（转换增删改回调宿主，内嵌）
  ▼ 视图层（只消费 ViewModel）
  SStateTreeView（States 主 tab，双显示模式）／SStateTreeOutliner（Outliner minor tab，功能重复，两处 @todo share code）
  SStateTreeDebuggerView（Debugger minor tab）／Diff 视图（每边各建一套 SStateTreeView+VM）
FStateTreeEditor (FAssetEditorToolkit)：tab 布局、菜单/工具栏、两个 IDetailsView、编译 MessageLog
FStateTreeEditorModeToolkit：经 IStateTreeEditorHost::GetTabHost 装配 minor tab
```

`FStateTreeViewModel` 的 9 个委托：`FOnAssetChanged`（undo/redo 级整树刷新）、`FOnStatesChanged(AffectedStates, FPropertyChangedEvent)`、`FOnStateAdded(Parent, NewState)`、`FOnStatesRemoved(AffectedParents)`、`FOnStatesMoved`、`FOnStateNodesChanged(State)`、`FOnSelectionChanged`、`FOnBringNodeToFocus(State, NodeID)`、`FOnBringBindingPathToFocus(State, BindingPath)`；外部强制刷新用 `NotifyAssetChangedExternally()/NotifyStatesChangedExternally()`。编辑操作全集：状态（`AddState/AddChildState/RenameState/RemoveSelectedStates/CopySelectedStates/PasteStatesFromClipboard/DuplicateSelectedStates/MoveSelectedStates{Before,After,Into}/SetSelectedStatesEnabled`）、节点（`DeleteNode/CopyNode/PasteNode/MoveNode/DuplicateNode/PasteNodesToSelectedStates`）、转换（`AddTransition/RemoveTransition`）、聚焦（`BringNodeToFocus/BringBindingPathToFocus`）、断点（`WITH_STATETREE_TRACE_DEBUGGER`：`ToggleStateBreakpoints/ToggleTaskBreakpoint/ToggleTransitionBreakpoint` 等）。

minor tab 固定五个（`UE::StateTreeEditor::FWorkspaceTabHost`）：Bindings（`UE::PropertyBinding::SBindingView`，点击跳转）、Outliner、Find（`SFindInAsset`）、Statistics（`UStateTree::CalculateEstimatedMemoryUsage()` 内存估算 + 节点数）、Debugger（仅 `WITH_STATETREE_TRACE_DEBUGGER`）【源码 Private\StateTreeEditorModeToolkit.cpp L110-188】。布局扩展：`FStateTreeEditorModule::OnRegisterLayoutExtensions()` 广播 `FLayoutExtender`（独立编辑器默认布局 `Standalone_StateTree_Layout_v5`）。

**StateCentricView（Experimental）**：开启 CVar `StateTree.Editor.Experimental.EnableStateCentricView` 后 `SStateTreeView` 切换为"以当前查看状态为中心"的节点图（`FStateTreeViewModel::GetViewState()` = 最后选中状态或第一根状态）。三层：Layout `SExtendableNode`（中央节点 + 10 方向扩展位 + `EExtendableNodeLOD`）；View `SStateCentricViewMainStateNode`/`STransitionNode`/`SParentState*Node`/`SStateCentricToolbar`；ViewModel `UStateCentricViewEditorDataExtension`（每资产 LOD 记忆）+ `UStateCentricViewSettings`（PerSchema 布局样式）。全部 `UCLASS(Experimental)`，头注释 "May be removed at any time"，产品代码不应依赖【源码 Private\StateCentricView\StateCentricViewSettings.cpp L9-14】。

**编辑器设置**：`UStateTreeEditorSettings`（config=EditorPerProjectUserSettings：`SaveOnCompile`、`DebuggerTrackNameVerbosity`、`bEnableLegacyDebuggerWindow`）；`UStateTreeEditorUserSettings`（StatesView 显示节点类型位掩码、行高）。

## 11. 绑定 UI

绑定 UI 不是专用面板，而是把 `FStateTreeBindingExtension : FPropertyBindingExtension` 挂到 DetailsView 上【源码 EM\Private\Customizations\StateTreeBindingExtension.cpp，1411 行】：

```cpp
FStateTreeEditorModule::SetDetailPropertyHandlers(IDetailsView& DetailsView);
  // → DetailsView.SetExtensionHandler(MakeShared<FStateTreeBindingExtension>());
  // → DetailsView.SetChildrenCustomizationHandler(MakeShared<FStateTreeBindingsChildrenCustomization>());
```

`SetDetailPropertyHandlers` 是**公开静态 API**：任何模块给任意 DetailsView 调用即可获得 StateTree 绑定能力（引擎内复用实例：Avalanche `SAvaTransitionSelectionDetails`）；需每个 DetailsView 单独调用。StateTree 编辑器自身的两个 DetailsView 与 Mode 的 DetailsView 均已挂载【源码 EM\Private\StateTreeEditorModule.cpp L352-356】。

四类绑定：

| 绑定 | 判定 | 约束 |
|---|---|---|
| 普通绑定 | 默认 | 目标属性 ← 源（Context / 参数 / 其它节点输出） |
| Output 绑定 | 目标属性 Usage=Output（`IsOutputBinding()`） | 方向反转（target 写回 source）；仅允许源为 Parameter/StateParameter |
| PropertyFunction 绑定 | 源为 PropertyFunction 节点 | 用其单一输出属性补全路径（`GetStructSingleOutputProperty`） |
| TaskCompletion 绑定 | 目标为 `FStateTreeDelegateListener`/`FStateTreeTransitionDelegateListener` 属性 | 注入 "Task Completion Dispatcher" 子菜单（按状态分组的任务 × `UE::StateTree::ETaskCompletionCondition` Completes/Succeeds/Fails），先 `SetNextTaskCompletionBinding` 再 `AddBinding` |

兼容性判定（`DeterminePropertiesCompatibilityInternal`，L545-649）：按属性元数据 `EStateTreePropertyUsage`（Input/Context/Parameter/Output，`UE::StateTree::GetUsageFromMetaData`）；`FStateTreeAnyEnum`（元数据 `AllowAnyBinding`）、`FStateTreeStructRef`（`BaseStruct`）、`FStateTreePropertyRef` 家族（`RefType/CanRefToArray/IsRefToArray`）；DelegateListener 仅接受 DelegateDispatcher；`CanBindToArrayElements()`=true（支持数组元素绑定）。`Input/Context` 仅允许目标路径顶层段绑定；节点实例结构属性除 PropertyRef/DelegateListener 外不可作绑定目标。

绑定源枚举：`UStateTreeEditorData::GetAccessibleStructsInExecutionPath` 按"执行路径可达"给出 Schema ContextDataDescs、RootParameters、祖先状态的 StateParameters/Task/GlobalTask 输出、PropertyFunction 模板节点（§9 弃用表中旧 `GetAccessibleStruct` 的替代）。

复制粘贴：属性行右键 Copy/Paste Binding，经 `UE::StateTreeEditor::FClipboardEditorData` 文本序列化（`ExportTextAsClipboardEditorData/ImportTextAsClipboardEditorData`）跨属性/跨资产迁移；粘贴时校验源结构可达性与属性兼容性，失败走 `AddErrorNotification`（约 5 秒通知，不静默）；有绑定的行禁用默认 Copy/Paste。子项接管：属性绑定到 PropertyFunction 时子属性树由 `FStateTreePropertyFunctionNodeProvider` 接管展示。全局通知：`UE::StateTree::PropertyBinding::OnStateTreePropertyBindingChanged(SourcePath, TargetPath)`。

数据落点与编译：写入 `UStateTreeEditorData::EditorBindings`，编译期由 `FStateTreePropertyBindingCompiler` 产出运行时批次（§3.2 步 10）→ 运行时消费 → property-bindings.md。

## 12. 蓝图边界

K2 节点（EM\Private\K2Node_*，共 3 个 + 1 个空 `UE::StateTree::Editor::UEdGraphSchema_StateTree : UEdGraphSchema_K2`）：

| 节点 | 作用 |
|---|---|
| `UK2Node_MakeStateTreeReference` | 选 `UStateTree` 后按其 Parameters PropertyBag 动态重建参数引脚（`PinDefaultValueChanged`/`HandleStateTreeCompiled`）；`ExpandNode` 展开为 `UStateTreeFunctionLibrary::MakeStateTreeReference` + 每参数一个 `K2_SetParametersProperty` 调用 |
| `UK2Node_StateTreeBlueprintPropertyRef` | "Get Property Reference"；自定义 `FKCHandler_StateTreeBlueprintPropertyRefGet` 编译，取 `FStateTreeBlueprintPropertyRef` 引用值 |
| `UK2Node_StateTreeNodeGetPropertyDescription` | 纯节点，展开为 `UStateTreeNodeBlueprintBase::GetPropertyDescriptionByPropertyName`（BP 自定义节点描述文本） |

`UStateTreeFunctionLibrary`（RM）BlueprintCallable 面 4 函数：

| 函数 | 用途 |
|---|---|
| `SetStateTree(FStateTreeReference&, UStateTree*)` | 运行时换资产 |
| `MakeStateTreeReference`（NativeMakeFunc，BlueprintInternalUseOnly） | 由 K2 节点供给 UI |
| `K2_SetParametersProperty` / `K2_GetParametersProperty`（CustomThunk，BlueprintInternalUseOnly） | 参数按名读写 |

BP 节点基类 4 个：`UStateTreeConditionBlueprintBase` / `UStateTreeTaskBlueprintBase` / `UStateTreeEvaluatorBlueprintBase` / `UStateTreeConsiderationBlueprintBase`（共同基类 `UStateTreeNodeBlueprintBase`）；BP 节点图表变量按 Context/Input/Output 三组 `FAdditionalCategory` 分组（模块 Startup 注册）。**边界**：BP 能引用资产、换资产、设参数、编写节点，但**不能直接执行 StateTree**——执行宿主是 `UStateTreeComponent`/自定义宿主（→ gameplay-state-tree.md）或运行时 C++（`FStateTreeExecutionContext`，→ runtime-execution.md）。

## 13. Diff / Merge / Find

| 能力 | 状态 | 细节 |
|---|---|---|
| Diff | **有**（三层：状态树结构 diff + 绑定 diff + Details diff） | `SStateTreeDiff`/`AsyncStateTreeDiff`/`StateTreeDiffControl`/`StateTreeDiffHelper`；`UAssetDefinition_StateTree::PerformAssetDiff` 入口，每边各建一套 `SStateTreeView`+VM；5.8 起 Considerations 在五分类（EnterConditions/Tasks/Transitions/Considerations/Parameters）中完整支持【源码 Private\SStateTreeDiff.h L139-143】 |
| Merge | **无** | 整个 StateTreeEditorModule 无 merge 代码；SCC 冲突只能看 Diff 手动改 |
| Find | 仅资产内 | `SFindInAsset`（Find minor tab）；不进全局 Find Results（`HandleOpenGlobalFindResults` 被注释禁用【源码 Private\FindTools\SStateTreeFind.h L91-92】） |

## 14. 编辑宿主与"编辑器外调试"正名

**`FStandaloneStateTreeEditorHost` 正名**：它不是"脱离编辑器运行 StateTree"，而是**独立资产编辑器内部**的 `IStateTreeEditorHost` 实现。该接口是把 StateTree 编辑模式嵌入第三方资产编辑器的契约【源码 EM\Public\IStateTreeEditorHost.h】：

| 接口成员 | 语义 |
|---|---|
| `GetStateTree()` / `OnStateTreeChanged()` | 当前编辑的资产与变更通知 |
| `GetAssetDetailsView()` / `GetDetailsView()` | 两个 DetailsView（绑定 UI 挂载点） |
| `GetTabHost()` | `UE::StateTreeEditor::FWorkspaceTabHost`（五 minor tab 宿主） |
| `GetCompilerLogName()` / `GetCompilerTabName()` / `ShouldShowCompileButton()` | 编译日志与按钮定制 |
| `CanToolkitSpawnWorkspaceTab()` | true 时 ModeToolkit 走 `RequestModeUITabs` 注册 minor tab |

复用路径：host 包进 `UStateTreeEditorContext` 放入自己的 `ContextObjectStore` → 激活 `UStateTreeEditorMode::EM_StateTree` → ModeToolkit 从 ContextStore 找到 host 装配五 tab。引擎内复用实例：`FAnimNextStateTreeEditorHost`（UAFStateTree，实验性动画框架）。操作步骤 → customization-guide.md。

**编辑器外调试正名**：没有"在编辑器外启动 StateTree UI 调试器"的独立工具。正确姿势：①编辑器内调试 PIE/世界实例 → Rewind Debugger（StateTreeEditorModule 注册 `IRewindDebuggerExtension` 播放扩展与 TrackCreator ModularFeature）或编辑器 Debugger tab；②独立进程 → 运行时 Trace 流（`WITH_STATETREE_TRACE`，非 Shipping）录制，回编辑器经 `FStateTreeDebugger : ITraceReader` / TraceAnalyzer 消费；③无 UI 批量编译 → `UStateTreeCompileAllCommandlet`。Trace 链路 → debugging-trace.md。

## 15. 编辑器扩展点清单

机制级索引；**操作步骤一律 → customization-guide.md**：

| 扩展点 | 机制 |
|---|---|
| 编辑规则 Schema | `UStateTreeEditorSchema`：`PreValidate`/`Validate`/`HandlePostInternalCompile(const FPostInternalContext&)`/`GetTransitionEditingRules()`（`EStateTreeTransitionEditingRules::AllowReactivation` 为 5.8 新增编辑规则）/`GetParametersSchemaClass()`/`AllowExtensions()`；经 `FStateTreeEditorModule::RegisterEditorSchemaClass(Schema, EditorSchema)` 注册 |
| 资产级扩展 | `UStateTreeEditorDataExtension`（Within=StateTreeEditorData）：`PreValidate`/`Validate`/`HandlePostInternalCompile`（可改 StateTree 不可改 EditorData，防死循环）/`CustomizeDetails`；经 `GetOrCreateExtension<T>()` 挂载 |
| 自定义 EditorData 子类 | `FStateTreeEditorModule::RegisterEditorDataClass(Schema, EditorData)`；`ValidateStateTree` 的 FixEditorData 自动转换存量资产 |
| 自定义节点编辑器可见 | 零注册：`FStateTreeNodeClassCache` 以五个节点基类 ScriptStruct 为根扫描反射类型；显示由 `GetDescription/GetIconName/GetMenuCategory` 决定 |
| Schema 裁剪 UI | `UStateTreeSchema` 虚函数：`IsStructAllowed/IsClassAllowed`（节点选择器与 New 菜单）、`IsStateTypeAllowed`、`IsStateSelectionAllowed`、`AllowEnterConditions/AllowUtilityConsiderations/AllowEvaluators/AllowMultipleTasks/AllowGlobalParameters/AllowTasksCompletion`（详情分区显隐）、`GetContextDataDescs`（绑定 UI Context 分节）等 |
| Details 定制 | 标准 PropertyEditor 注册；引擎自带注册表：`StateTreeTransition→FStateTreeTransitionDetails`、`StateTreeEventDesc→FStateTreeEventDescDetails`、`StateTreeStateLink→FStateTreeStateLinkDetails`、`StateTreeEditorNode→FStateTreeEditorNodeDetails`、`StateTreeStateParameters→FStateTreeStateParametersDetails`、`StateTreeAnyEnum→FStateTreeAnyEnumDetails`、`StateTreeReference→FStateTreeReferenceDetails`、`StateTreeReferenceOverrides→FStateTreeReferenceOverridesDetails`、`StateTreeEditorColorRef/StateTreeEditorColor→FStateTreeEditorColor*Details`、`StateTreeBlueprintPropertyRef→FStateTreeBlueprintPropertyRefDetails`、`StateTreeEnumValueScorePairs→FStateTreeEnumValueScorePairsDetails`；类定制 `StateTreeState→FStateTreeStateDetails`、`StateTreeEditorData→FStateTreeEditorDataDetails`【源码 EM\Private\StateTreeEditorModule.cpp L264-278】 |
| 绑定 UI 复用 | `FStateTreeEditorModule::SetDetailPropertyHandlers(IDetailsView&)`（§11） |
| 编译尾扩展运行时资产 | `HandlePostInternalCompile` 中 `Context.AddExtension(TSubclassOf<UStateTreeExtension>)`；失败即编译失败 |
| 布局/菜单/工具栏 | `OnRegisterLayoutExtensions`（FLayoutExtender）；`FStateTreeEditorModule` 实现 `IHasMenuExtensibility/IHasToolBarExtensibility` |
| StateCentricView 节点扩展 | `SExtendableNode` 的 `FAddExtensionDelegate`（Experimental；当前引擎内注册方全在 View 层内部，无公开命名注册表【推断】） |
| 编译管线参与 | 模块级委托 `OnPreValidateStateTree()/OnValidateStateTree()/OnPostInternalCompile()/OnAssetRegistryTags()`（§3.5、§3.2） |

## 16. 注意事项与坑

1. **FStateTreeCompiler 一次性**：实例只能 `Compile*` 一次，复用报 internal error。
2. **失败语义**：编译失败把 dirty 清为 None（"再编一次结果相同"），靠 `CompileStatus` 表达失败；但 `UStateTree::Link` 失败会重新 `MarkAsModified(false)` 以便 PIE 重试——排查"为何没自动重编"先看 CompileStatus 与 `LastCompiledEditorDataHash==0`。
3. **排队可被禁用**：`Schema->AllowQueuedCompilation()`=false（如 Mass 类任意线程宿主）或 PIE 期间 → `QueueForCompilation` 退化为同步编译；PIE 开始时强制 `FlushCompilationQueue`。
4. **资产加载默认同步编译**：`EnableQueuedCompilationOnAssetLoad` 默认 false——大量 StateTree 资产的关卡加载会同步编译；量大时打开排队或预热。
5. **绑定变更通知不完整（官方 TODO，jira UE-337309）**：程序化改节点/状态后务必手动 `UStateTreeEditorData::UpdateBindings()` / `UStateTreeEditingSubsystem::ValidateStateTree()`。
6. **编译产物 outer**：UObject 型节点实例数据必须 Duplicate 到 StateTree（不得挂 EditorData 下），`CheckCompiledStateTreeOuters` 专抓此错。
7. **弃用消息笔误**：`UpdateBindingsInstanceStructs` 的替代品名 "UpdateEditorBindings" 在公开 API 中不存在——照抄会编译失败，用 `UpdateBindings()`（§9）。
8. **Public/Internal 语义**：Public ≠ "对外数据"，而是"影响引用本资产的产出"（根参数 + Schema 类）；改任务属性属 Internal。
9. **编辑期/运行期分离**：编辑器改 `UStateTreeEditorData`/`UStateTreeState`/`FStateTreeEditorNode`；直接改运行时 `UStateTree` 字段不会反映到编辑器视图且会被编译覆盖。
10. **双视图代码重复**：`SStateTreeView` 与 `SStateTreeOutliner` 功能重复且代码重复（两处 @todo share code）——扩展应对准 ViewModel 而非视图。
11. **StateCentricView 全家 Experimental**：默认关、API 可能随时变，产品代码不可依赖。
12. **绑定 UI 依赖属性元数据**：自定义节点若不给输入/输出属性打正确 `EStateTreePropertyUsage`，绑定 UI 要么不显示要么绑不上。

## 17. 开放问题

1. `UE::StateTree::Compiler::FCompilerManager` 引入的准确小版本/CL 未证实（5.7 判定基于 5.8 弃用注释 + 官方 API 文档页面，未对照 5.6 源码）。
2. StateCentricView 的引入版本未证实（本机 5.8 存在且 Experimental；未比对 5.7）。
3. `SExtendableNode` 外部子系统扩展注册（`Construct_GatherExtensionsFromExternalSubsystems`）是否暴露公开 API 未逐行核实。
4. UE-337309（绑定变更通知不完整）的实际影响范围与修复计划仅有源码注释佐证。
5. 引擎级三路 Merge 工具是否有第三方为 StateTree 提供支持，仅确认 StateTree 插件 + VirtualProduction 目录内"无"，未全引擎扫描 Merge 注册点。
6. BP/UDS 重实例化的已知盲区（`HandleObjectsReinstanced` @TODO：property 用途互换与节点特殊 flag 变化不可检测，Epic 自认）具体后果未复现。
