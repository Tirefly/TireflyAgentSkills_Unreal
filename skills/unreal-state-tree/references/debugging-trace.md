# StateTree 调试与 Trace（Debugging / Trace / RewindDebugger）

> 版本基线：UE 5.8.0 (Release-5.8, CL 55116800) · 版本标记约定：**[UE 5.x+]**=该版本新增，**[仅 <5.x]**=已移除/旧行为，**[5.8 变更]**=本版变更；现行 API 判定标准=声明无 UE_DEPRECATED 标记。

## TL;DR

- 架构一句话：**Trace 当录制带、Rewind Debugger 当播放器**——运行时经 `StateTreeDebugChannel` 写 12 类 Trace 事件，`FStateTreeTraceAnalyzer`/`FStateTreeTraceProvider` 分析回放，`FStateTreeDebugger`（`FTickableGameObject`）增量读 Timeline 重建 `FInstanceEventCollection`。
- 分析器/Provider/UI 全部编译在 StateTreeModule（`WITH_STATETREE_TRACE_DEBUGGER` 域），**TraceInsights 对 StateTree 引用为 0**——不打开 Unreal Insights 也能调试。
- 断点为**每资产**粒度（状态进入/退出 + 任务 + 转换）；两级步进（帧级 / 活动状态变化级）；Scrub 任意时间点；优先复用 RewindDebugger 的 analysis session 做实时跟随。
- 对接 RewindDebugger 靠三个 ModularFeature 扩展点：录制 `IRewindDebuggerRuntimeExtension`（StateTreeDeveloper）、scrub 同步 `IRewindDebuggerExtension`（StateTreeEditorModule）、每实例轨道 `IRewindDebuggerTrackCreator`（TargetType=`FStateTreeInstanceData`）。
- 4 个编译开关：`WITH_STATETREE_TRACE` / `WITH_STATETREE_TRACE_DEBUGGER` / `WITH_STATETREE_DEBUG` / `UE_WITH_STATETREE_CRASHREPORTER`；配置能力矩阵见 §2，Shipping/Test 下调试宏几乎全为空。
- 轻量层 `WITH_STATETREE_DEBUG`（Debug/Development）：`UE::StateTree::Debug` 16 个节点调试委托 + RuntimeValidation（5 组 CVar 校验）+ CrashReporter 崩溃上下文注入。
- **[5.8 变更]** 录制钩子从 `IRewindDebuggerExtension` 迁到 `IRewindDebuggerRuntimeExtension`；UEFN/Shipping Editor 明确支持录制。5.7 已把 11 个 `Output*` Trace API 收编为"传执行上下文指针"签名（旧重载在 5.8 函数体已清空）。
- 编辑器 Debugger 标签页的视图实现细节见本文档 §8/§9（StateTreeDeveloper 共用控件与调试 UI 文件清单）；editor.md 仅含 tab 注册入口；执行阶段语义详见 **runtime-execution.md**。

## 目录

1. [架构总览与模块归属](#1-架构总览与模块归属)
2. [编译开关与配置能力矩阵](#2-编译开关与配置能力矩阵)
3. [运行时写入链路](#3-运行时写入链路)
4. [Trace 分析层 Analyzer 与 Provider](#4-trace-分析层-analyzer-与-provider)
5. [FStateTreeDebugger 调试会话](#5-fstatetreedebugger-调试会话)
6. [RewindDebugger 三扩展点](#6-rewinddebugger-三扩展点)
7. [轻量调试层 RuntimeValidation 与 CrashReporter](#7-轻量调试层-runtimevalidation-与-crashreporter)
8. [StateTreeDeveloper 模块职责](#8-statetreedeveloper-模块职责)
9. [编辑器调试入口](#9-编辑器调试入口)
10. [开发者扩展工作流](#10-开发者扩展工作流)
11. [注意事项与坑](#11-注意事项与坑)
12. [版本敏感点](#12-版本敏感点)
13. [弃用 API 列表](#13-弃用-api-列表)
14. [开放问题](#开放问题)

> **引用路径约定**：`【…】`内为证据路径+行号；StateTree 插件源码省略根 `E:\UnrealEngine\UE_5.8\Engine\Plugins\Runtime\StateTree\Source\`，引擎本体文件写全路径。证据分级沿用调研报告：【源码】=本机 5.8 源码直接证实；【推断】=由证据合理推断；【未证实】=无本地证据。本模块调研报告：`~/.agents/tmp/state-tree-research/10-debugging-trace.md`。

---

## 1. 架构总览与模块归属

### 1.1 数据流（按阶段）

```
[阶段 A · 运行时写入]  FStateTreeExecutionContext（任意线程）
    │  UE_STATETREE_DEBUG_* 宏 = 调试委托广播 + TRACE_STATETREE_* 宏
    ▼
StateTreeDebugChannel ── 12 类 UE_TRACE_EVENT ── FBufferedDataList GBufferedEvents 延迟缓冲
    ▼
[阶段 B · 分析]  FStateTreeTraceAnalyzer（路由 12 类事件）──► FStateTreeTraceProvider（每实例 TPointTimeline）
    ▼
[阶段 C · 会话]  FStateTreeDebugger::ReadTrace 增量枚举 ──► FInstanceEventCollection（Events/FrameSpans/ActiveStatesChanges）
    ▼
[阶段 D · 呈现]  资产编辑器 Debugger 标签页 ／ RewindDebugger 每实例轨道
```

### 1.2 模块归属

| 阶段 | 模块 | 编译开关 | 代表类型 |
|---|---|---|---|
| A 写入 | StateTreeModule（Runtime） | `WITH_STATETREE_TRACE` | `StateTreeDebugChannel`、`TRACE_STATETREE_*`、`UE::StateTreeTrace::Output*`、`FBufferedDataList` |
| B 分析 | StateTreeModule | `WITH_STATETREE_TRACE_DEBUGGER` | `FStateTreeTraceAnalyzer`、`FStateTreeTraceProvider`、`FStateTreeTraceModule` |
| C 会话 | StateTreeModule | `WITH_STATETREE_TRACE_DEBUGGER` | `FStateTreeDebugger`、`FScrubState`、`FStateTreeDebuggerBreakpoint` |
| D 编辑器 UI | StateTreeEditorModule（仅 Editor 目标编译） | 同上（模块级单列定义） | `SStateTreeDebuggerView`、轨道、命令集 |
| D' 共用控件+录制 | StateTreeDeveloper（DeveloperTool，不依赖 UnrealEd） | 录制扩展为 `WITH_STATETREE_TRACE` | `FRewindDebuggerRecordingExtension`、`SCompactTreeDebuggerView`、`SFrameEventsView` |
| E 校验/委托 | StateTreeModule | `WITH_STATETREE_DEBUG` | `UE::StateTree::Debug` 16 委托、`FRuntimeValidation` |
| F 崩溃上下文 | StateTreeModule | `UE_WITH_STATETREE_CRASHREPORTER` | `FCrashReporterHandler`、`UE_STATETREE_CRASH_REPORTER_SCOPE` |

### 1.3 边界事实

- **自含性**：TraceInsights（`Engine\Source\Developer\TraceInsights*`）对 StateTree 的引用为 0【源码，rg 扫描】；StateTree 的 Analyzer/Provider/TraceModule 全部在 StateTreeModule 内，编辑器调试 UI 也不经过 Unreal Insights。
- **RewindDebugger 接口在引擎本体**：`Engine\Source\Editor\RewindDebuggerInterface\`（`IRewindDebugger.h`/`IRewindDebuggerExtension.h`/`IRewindDebuggerTrackCreator.h` 等）与 `Engine\Source\Runtime\RewindDebuggerRuntimeInterface\`（`IRewindDebuggerRuntimeExtension.h`）；实现本体在 `Engine\Plugins\Animation\GameplayInsights\Source\RewindDebugger\`【源码，目录扫描】。
- **外部消费者共享同一组开关**：`UE_AVA_WITH_TRANSITION_DEBUG = (WITH_STATETREE_DEBUG && WITH_STATETREE_TRACE_DEBUGGER)`（AvalancheTransitionEditor）；MassAI/MassAIBehavior 与 UAFStateTree 直接使用 `WITH_STATETREE_DEBUG`【源码】——关闭开关会连带改变外部插件的调试能力。

## 2. 编译开关与配置能力矩阵

### 2.1 四个编译开关

| 宏 | 定义处 | 取值条件 |
|---|---|---|
| `WITH_STATETREE_TRACE` | `StateTreeModuleBase::SetupStateTreeDebuggingSupport`（`StateTreeModule.Build.cs` L36-52；`StateTreeDeveloper.Build.cs` L30） | `Config != Shipping \|\| Target.bBuildEditor`：非 Shipping 全部=1；Shipping+Editor（UEFN）=1；Shipping game=0【源码 `IsStateTreeTraceRecordingSupported` L13-17】 |
| `WITH_STATETREE_TRACE_DEBUGGER` | 同上；StateTreeEditorModule 在 `StateTreeEditorModule.Build.cs` L75-84 单独定义 | StateTreeModule/StateTreeDeveloper：`= TRACE && Desktop && (Target.Type == Editor \|\| Program)`；StateTreeEditorModule：`=(Config != Shipping \|\| bBuildEditor) && Desktop`【源码 `IsStateTreeDebuggerSupported` L22-29】 |
| `WITH_STATETREE_DEBUG` | `StateTreeTypes.h` L19-21 | `!(UE_BUILD_SHIPPING \|\| UE_BUILD_SHIPPING_WITH_EDITOR \|\| UE_BUILD_TEST) && 1`——Debug/Development 可用；**Test 配置也被剔除** |
| `UE_WITH_STATETREE_CRASHREPORTER` | `Private\CrashReporter\StateTreeCrashReporterHandler.h` L8-10 | `= WITH_ADDITIONAL_CRASH_CONTEXTS`（Core 在 Desktop 平台置 1，无配置条件） |

### 2.2 配置能力矩阵【推断，由 2.1 条件直接推出；UEFN 取值见开放问题】

| 配置 | TRACE | TRACE_DEBUGGER | WITH_STATETREE_DEBUG | 可用能力 |
|---|---|---|---|---|
| Shipping（game，桌面） | 0 | 0 | 0 | 仅 CrashReporter 上下文；其余调试宏全为空 |
| Test | 0 | 0 | 0 | 同上 |
| Debug/Development（game，桌面） | 1 | 0（Program 才有） | 1 | 录制（`StartTraces`/控制台命令/自动开始设置）+ 节点调试委托 + RuntimeValidation；无回放分析 |
| Debug/Development（game，主机） | 1 | 0 | 1 | 同桌面 game（Build.cs 注释称主机无 TraceAnalysis 支持）【源码 Build.cs L25】 |
| Editor（Debug/Development，桌面） | 1 | 1 | 1 | 全量：录制+分析+调试器 UI+断点+RewindDebugger 三扩展 |
| Program（桌面，非 Shipping） | 1 | 1 | 1* | 有分析/回放（仅 Editor/Program 目标带 `RewindDebuggerInterface`）；*`WITH_STATETREE_DEBUG` 取决于该 Program 的构建配置 |
| UEFN（Shipping+Editor） | 1 | 1 | 0（UE_BUILD_SHIPPING） | 录制+回放可用；运行时校验/调试委托被剔除【源码 Build.cs L15-16 注释】 |

### 2.3 依赖联动

- `WITH_STATETREE_TRACE=1` → Public 依赖 `TraceLog`【源码 StateTreeModule.Build.cs L108-116】。
- `WITH_STATETREE_TRACE_DEBUGGER=1` → Public `TraceServices`+`TraceAnalysis`、Private `RewindDebuggerInterface`【源码 L118-132】。
- StateTreeDeveloper 在 `TRACE=1` 时 Public 追加 `RewindDebuggerRuntimeInterface`+`TraceLog`【源码 StateTreeDeveloper.Build.cs L30】。

## 3. 运行时写入链路

### 3.1 通道与 12 类 Trace 事件

- 通道：`UE_TRACE_CHANNEL_EXTERN(StateTreeDebugChannel, STATETREEMODULE_API)`【源码 StateTreeTrace.h L28】，描述含 "deferred buffering support"。
- 12 个 `UE_TRACE_EVENT` 定义于 `Private\Debugger\StateTreeTrace.cpp` L24-126，命名空间 `StateTreeDebugger`：

| 事件 | 载荷字段 |
|---|---|
| `WorldTimestampEvent` | `WorldTime`（录制世界时间锚点） |
| `AssetDebugIdEvent` | `Cycle, TreeName, TreePath, CompiledDataHash, AssetDebugId` |
| `InstanceEvent` | `Cycle, InstanceId, InstanceSerial, InstanceName, EventType, AssetDebugId` |
| `InstanceFrameEvent` | —（执行帧事件，字段见源码） |
| `PhaseEvent` | `Phase, StateIndex, EventType` |
| `LogEvent` | `Verbosity, Message` |
| `StateEvent` | `StateIndex, EventType` |
| `TaskEvent` | `NodeIndex, DataView(uint8[]), EventType, Status` |
| `EvaluatorEvent` | —（节点事件，字段见源码） |
| `TransitionEvent` | `SourceType, TransitionIndex, TargetStateIndex, Priority, EventType` |
| `ConditionEvent` | —（节点事件，字段见源码） |
| `ActiveStatesEvent` | `ActiveStates(uint16[]), AssetDebugIds(uint16[])` |

### 3.2 现行发射 API（命名空间 `UE::StateTreeTrace`，StateTreeTrace.h L101-114）

现行签名一律携带 `TNotNull<const FStateTreeReadOnlyExecutionContext*>`，实例标识取自 `Context->GetInstanceDebugId()`（`FStateTreeInstanceDebugId{Id, SerialNumber}`）；旧的 `FStateTreeInstanceDebugId` 参数重载已弃用（见 §13）。

- `UE::StateTreeTrace::RegisterGlobalDelegates()` / `UnregisterGlobalDelegates()`
- `OutputAssetDebugIdEvent(const UStateTree*, FStateTreeIndex16)`
- `OutputPhaseScopeEvent(Context, EStateTreeUpdatePhase, EStateTreeTraceEventType, FStateTreeStateHandle)`
- `OutputInstanceLifetimeEvent(Context, EventType)`
- `OutputInstanceAssetEvent(Context, const UStateTree*)`
- `OutputInstanceFrameEvent(Context, const FStateTreeExecutionFrame*)`
- `OutputLogEventTrace(Context, ELogVerbosity::Type, Fmt, ...)`
- `OutputStateEventTrace(Context, FStateTreeStateHandle, EventType)`
- `OutputTaskEventTrace(Context, TaskIdx, FStateTreeDataView, EventType, EStateTreeRunStatus)`
- `OutputEvaluatorEventTrace(Context, EvaluatorIdx, DataView, EventType)`
- `OutputConditionEventTrace(Context, ConditionIdx, DataView, EventType)`
- `OutputTransitionEventTrace(Context, FStateTreeTransitionSource, EventType)`
- `OutputActiveStatesEventTrace(Context, TConstArrayView<FStateTreeExecutionFrame>)`

调用侧宏（`WITH_STATETREE_TRACE=0` 时全为空宏，StateTreeTrace.h L193-204；多数先查 `UE_TRACE_CHANNELEXPR_IS_ENABLED(StateTreeDebugChannel)`）：`TRACE_STATETREE_INSTANCE_EVENT` / `INSTANCE_FRAME_EVENT` / `PHASE_EVENT` / `LOG_EVENT` / `STATE_EVENT` / `TASK_EVENT` / `EVALUATOR_EVENT` / `CONDITION_EVENT` / `TRANSITION_EVENT` / `ACTIVE_STATES_EVENT`。执行上下文侧配套 `FStateTreeReadOnlyExecutionContext::SetNodeCustomDebugTraceData(FNodeCustomDebugData&&) const` / `StealNodeCustomDebugTraceData() const` / `SetOuterTraceId(uint64)` / `GetOuterTraceId()`【源码 StateTreeExecutionContext.h L166-216】。

### 3.3 FBufferedDataList 延迟缓冲（StateTreeTrace.cpp L128-504）

全局缓冲 `GBufferedEvents` 保证"任意线程随时开始录制"也能产出配对完整、时间轴一致的 Trace：

- **世界时间采样**：`FWorldDelegates::OnWorldTickStart`（游戏线程）→ `FObjectTrace::GetWorldElapsedTime(TickedWorld)` 写入 `RecordingWorldTime`；首个需要发事件的 worker 线程用 `compare_exchange` 保证每帧只发一条 `WorldTimestampEvent`（`TraceWorldTimeIfNeeded_AnyThread`）。回放侧的"录制世界时间"轴由此而来。
- **Phase 栈**：`UpdatePhaseScope_AnyThread` 维护每实例 Phase 栈；Push 只在其他事件已被 trace 过时才落盘，Pop 仅当对应 Push 已 trace 时才发——迟到开启录制时事件仍配对完整（`TraceStackedPhases_AnyThread`）。
- **资产 DebugId**：`FindOrAddDebugIdForAsset_AnyThread` 为每个 `UStateTree` 分配 `FStateTreeIndex16` DebugId（从 1 起）并发 `AssetDebugIdEvent`（含 `LastCompiledEditorDataHash`，回放侧用于版本校验）。
- **实例首触**：`TraceBufferedEvents` 首次见到实例时发 `TRACE_OBJECT(Owner)` + `TRACE_INSTANCE(Owner, InstanceId.ToUint64(), OuterId, FStateTreeInstanceData::StaticStruct(), TreeName)`（Object Trace 集成——RewindDebugger 靠它发现"实例对象"），再发 `InstanceEvent(Push)` 与当前活动状态快照。
- **收尾**：`OnTracingStateChanged(StoppingTrace)` 对每个已 trace 实例发收尾 WorldTimestamp + 空 `ActiveStates`（关闭活动状态窗口）；`Cleared` → `Reset_GameThread` 清空缓冲与 AssetDebugIdMap。

### 3.4 节点自定义调试数据

- `UE::StateTreeTrace::FNodeCustomDebugData`（`EMergePolicy` = Unset/Append/Override；`IsSet`/`ShouldOverrideDataView`/`ShouldAppendToDataView`/`GetTraceDebuggerString`）——任务/评估器/条件向 Trace 事件追加或替换自定义调试文本【源码 StateTreeTrace.h L36-99】。
- 序列化 `SerializeDebugDataToArchive`（StateTreeTrace.cpp L584-634）：实例数据经 `UScriptStruct::ExportText` 或 `UExporter::ExportToOutputDevice` 导出为文本（PortFlags 含 `PPF_PropertyWindow|PPF_IncludeTransient|PPP_ForDiff`）+ TypePath + DebugText 三段式；任务事件额外带 `EStateTreeRunStatus`。

### 3.5 录制控制

- `IStateTreeModule::StartTraces(int32& OutTraceId)` / `StopTraces()` / `IsTracing()`：连接 localhost Trace Store 并开关 `StateTreeDebugChannel`+`FrameChannel`【源码 StateTreeModule.cpp L95-330】。
- 控制台命令：`statetree.startdebuggertraces` / `statetree.stopdebuggertraces`。
- `UStateTreeSettings::bAutoStartDebuggerTracesOnNonEditorTargets`（默认 **false**，仅非 Editor target 生效）——非编辑器目标默认不自动录制【源码 StateTreeSettings.h L22-25】。
- **注意**：`StartTraces` 新建连接时会先枚举并禁用全部已开通道、只开 StateTree 两个通道；仅"复用已有连接"路径才记录并恢复原通道集合【源码 StateTreeModule.cpp L222-246, L309-318】——对同时做性能 trace 的会话是干扰。

## 4. Trace 分析层 Analyzer 与 Provider

### 4.1 模块注册与 Analyzer 路由

- `FStateTreeTraceModule : TraceServices::IModule`（ModuleName=`"TraceModule_StateTree"`）：`FStateTreeModule::StartupModule`（`WITH_STATETREE_TRACE_DEBUGGER` 域）把它以 ModularFeature 注册到 `TraceServices::ModuleFeatureName`；任何 analysis session 开始时 `OnAnalysisBegin` 挂上 Provider+Analyzer【源码 StateTreeModule.cpp L120-126; StateTreeTraceModule.cpp L19-24】。
- `FStateTreeTraceAnalyzer : UE::Trace::IAnalyzer` 路由全部 12 类事件【源码 StateTreeTraceAnalyzer.cpp L19-35】：
  - `AssetDebugIdEvent` → `FindObject<UStateTree>`（带 `FGCScopeGuard`）并比对 `LastCompiledEditorDataHash`；不一致仅告警 "Traces are not using the same StateTree asset version as the current asset."，**该资产后续事件全部丢弃**【源码 L51-81】。
  - `InstanceEvent(Push)` → Provider 建实例描述符与 Timeline；`Pop` → `Lifetime.SetUpperBound(InWorldRecordingTime)`【源码 StateTreeTraceProvider.cpp L153-161】。
  - Task/Evaluator/Condition 的 `DataView` 用 `FMemoryReaderView` 反序列化回 TypePath/InstanceDataAsText/DebugText。
  - `FStateTreeTraceActiveStatesEvent` 按 `AssetDebugIds` 分组还原"多资产（Linked 资产）活动状态"【源码 Analyzer.cpp L221-273】。

### 4.2 Provider 与读侧接口

- 写侧 `FStateTreeTraceProvider : IStateTreeTraceProvider + IEditableProvider`：每实例 `TPointTimeline<FStateTreeTraceEventVariantType>`；`ProviderName="StateTreeDebuggerProvider"`；Push 建 `FInstanceDescriptor`（Lifetime 下界=WorldRecordingTime），Pop 收口上界。锁模型为 `thread_local FProviderLock::FThreadLocalState`（读锁/编辑锁分离，`BeginRead/EndRead/BeginEdit/EndEdit`）【源码 StateTreeTraceProvider.h L12-54】。
- 读侧 `IStateTreeTraceProvider : TraceServices::IProvider`：`GetInstanceDescriptor` / `GetInstances` / `ReadTimelines`（按实例 Id 或按 `UStateTree` 枚举）；`FEventsTimeline = TraceServices::ITimeline<FStateTreeTraceEventVariantType>`【源码 IStateTreeTraceProvider.h L15-53】。

### 4.3 回放事件结构与枚举

- 回放事件：`FStateTreeTraceBaseEvent{RecordingWorldTime, EventType}` + 11 个派生（Phase/Log/Property/Transition/Node/State/Task/Evaluator/Condition/ActiveStates/InstanceFrame）+ 变体别名 `FStateTreeTraceEventVariantType`（`TVariant`，11 类型）；每类均有 `ToFullString/GetValueString/GetTypeString(const UStateTree&)`【源码 StateTreeTraceTypes.h L59-351】。
- `EStateTreeTraceEventType` 21 值：`OnEntering/OnEntered/OnExiting/OnExited/Push/Pop/OnStateSelected/OnStateCompleted/OnTicking/OnTaskCompleted/OnTicked/Passed/Failed/ForcedSuccess/ForcedFailure/InternalForcedFailure/OnRequesting/OnEvaluating/OnTransition/OnTreeStarted/OnTreeStopped`（StateTreeTraceTypes.h L32-57）。
- `EStateTreeUpdatePhase` 21 值（StateTreeExecutionTypes.h L25-45）——各 Phase 的执行语义详见 **runtime-execution.md**。
- `EStateTreeTraceStatus`（TracesStarted/StoppingTrace/TracesStopped/Cleared）与 `EStateTreeTraceAnalysisStatus`（Started/Stopped/Cleared）为 UENUM。

## 5. FStateTreeDebugger 调试会话

### 5.1 会话与增量读取

- 类定义：`FStateTreeDebugger : FTickableGameObject, UE::StateTreeDebugger::ITraceReader`（StateTreeDebugger.h L82-544；实现 1198 行）。
- **会话来源（按优先级）**【源码 StateTreeDebugger.cpp L333-373】：
  1. 复用 RewindDebugger 的 analysis session：`IRewindDebugger::Instance()->GetAnalysisSessionAsShared()` 存在则直接消费（`bIsExternalSessionAnalysis=true`，Stop 时只释放引用不停止会话）——"RewindDebugger 录制、StateTree 调试器消费"的接缝。
  2. 自有会话：`FStateTreeModule::GetStoreClient()`（`UE::Trace::FStoreClient::Create(TEXT("localhost"))`）枚举 `GetLiveTraces()`，对最新 trace 调 `TraceAnalysisService->StartAnalysis`。
- **自动连接**：构造时订阅 `OnTracingStateChanged`；`TracesStarted` 且无活动会话 → `RequestAnalysisOfLatestTrace()`（失败按 RetryPollingDuration 逐帧重试）；`RequestAnalysisOfEditorSession()` 供 UI"开始录制"使用【源码 cpp L82-89, L317-330】。
- **增量读取**：`UE::StateTreeDebugger::ReadTrace(Session, ScrubTime, ITraceReader*, FTraceFilter, double& LastTraceReadTime)` 用 `FrameProvider(TraceFrameType_Game)` 定位目标帧，**只处理已完成的帧**（进行中的帧回退上一帧），枚举 Timeline 上 `[LastTraceReadTime, Frame.EndTime)` 的事件灌入 `FInstanceEventCollection`；`FFrameSpan` 记录"帧→首事件索引"；跨多次录制（PIE 重启）用 `ContiguousTracesData` 做帧索引偏移拼接【源码 cpp L973-1055, L1114-1149】。
- `ITraceReader{GetOrCreateEventCollection(FStateTreeInstanceDebugId); OnTraceEventProcessed(...)}`：`FStateTreeDebugger` 与每实例 RewindDebugger 轨道各自实现、各持事件集合——读取侧与 UI 侧解耦。
- **实时跟随**：`Tick()` 中会话活动且未暂停 → `SyncToCurrentSessionDuration()` 追到最新完成帧；断点命中后 `bSessionAnalysisPaused=true` 停止处理新事件直到 `ResumeSessionAnalysis()`【源码 cpp L117-157, L195-205】。

### 5.2 断点 / 步进 / Scrub

| 能力 | 粒度/语义 | 机制 |
|---|---|---|
| 断点类型 | `EStateTreeBreakpointType{Unset, OnEnter, OnExit, OnTransition}`；状态进入匹配 `OnEntered`、退出匹配 `OnExited`、转换仅 `OnTransition`；任务/转换按节点索引 | `FStateTreeDebuggerBreakpoint(TVariant<FStateTreeStateHandle \| FStateTreeTaskIndex \| FStateTreeTransitionIndex>, BreakpointType)`；`EvaluateBreakpoints` 逐事件匹配【源码 StateTreeDebuggerTypes.h L18-24, L330-369】 |
| 断点作用域 | **每资产**（不区分实例；注释 "per asset and not specific to an instance"）；已选实例时仅该实例参与评估；Linked 资产断点经 `InstanceRootAsset`/`CurrentFrameStateTreeAsset` 逐帧比对支持 | StateTreeDebugger.h L472；StateTreeDebugger.cpp L868-897 |
| 命中行为 | 命中 → `SetScrubTime(命中时间)` + 自动选中实例 + `OnBreakpointHit` + `PauseSessionAnalysis()`；Resume 清除 HitBreakpoint | StateTreeDebugger.cpp L836-866, L312-321 |
| 生效前提 | `CanProcessBreakpoints()` 要求 `OnBreakpointHit` 已绑定（编辑器 UI 绑定）；game 进程无断点概念（`WITH_STATETREE_TRACE_DEBUGGER=0` 根本不编译） | StateTreeDebugger.h |
| 步进·帧级 | 上/下一"有事件的帧" | `StepBack/ForwardToPreviousStateWithEvents` → `FScrubState::GotoPrevious/NextFrame` |
| 步进·状态变化级 | 上/下一"活动状态列表发生变化的帧" | `StepBack/ForwardToPreviousStateChange` → `GotoPrevious/NextActiveStates`（查 `ActiveStatesChanges`） |
| Scrub | 任意时间点，吸附到包含它的帧 span 起点 | `FScrubState::SetScrubTime`（BeforeLowerBound/InBounds/AfterHigherBound 三态；FrameSpanIndex/ActiveStatesIndex/TraceFrameIndex 联动）【源码 StateTreeDebuggerTypes.cpp L38-108】 |
| 轨道级步进 | RewindDebugger 步进按钮在 StateTree 轨道上以"事件帧边界"为步长 | `FRewindDebuggerTrack::GetStepFrameTimeInternal(EStepMode, FScrubTimeInformation)`【源码 StateTreeRewindDebuggerTrack.cpp L260-295】 |

**帧内限制**：`ActiveStatesChanges` 每帧仅保留最后一条活动状态快照（源码注释 "until we implement scrubbing within a frame"）——帧内多次状态变化在时间线上看不到中间态【源码 StateTreeDebugger.cpp L1036-1045】。

### 5.3 实例选择与通知委托

- 实例 API：`SelectInstance` / `ClearSelection` / `GetSelectedInstanceId` / `GetDescriptor(InstanceId)` / `GetInstanceName` / `GetInstanceDescription` / `IsActiveInstance(Time, InstanceId)` / `GetEventCollection(InstanceId)` / `ResetEventCollections`。
- 实例委托成员：`OnNewSession`、`OnNewInstance(FStateTreeInstanceDebugId)`、`OnScrubStateChanged(const FScrubState&)`、`OnBreakpointHit(FStateTreeInstanceDebugId, FStateTreeDebuggerBreakpoint)`、`OnActiveStatesChanged(const FStateTreeTraceActiveStates&)`【源码 StateTreeDebugger.h L336-346】。
- 时间轴维护：`ActiveStatesChanges` → `RefreshActiveStates()` → `OnActiveStatesChanged` 广播【源码 cpp L599-617】。

## 6. RewindDebugger 三扩展点

| 扩展点 | StateTree 侧实现（模块） | 职责 | 注册目标 |
|---|---|---|---|
| `IRewindDebuggerRuntimeExtension`（`Engine\Source\Runtime\RewindDebuggerRuntimeInterface\IRewindDebuggerRuntimeExtension.h`） | `UE::StateTreeDebugger::FRewindDebuggerRecordingExtension`（StateTreeDeveloper，`WITH_STATETREE_TRACE` 域） | **录制开关**：`RecordingStarted` → 广播 `Delegates::OnTracingStateChanged(TracesStarted)` 再打开 `StateTreeDebugChannel`；`RecordingStopped`/`Clear`【源码 StateTreeRewindDebuggerRecordingExtension.cpp L15-40】 | `IRewindDebuggerRuntimeExtension::ModularFeatureName` |
| `IRewindDebuggerExtension`（`Engine\Source\Editor\RewindDebuggerInterface\IRewindDebuggerExtension.h`） | `UE::StateTreeDebugger::FRewindDebuggerPlaybackExtension`（StateTreeEditorModule） | **回放同步**：`Update` 检测 RewindDebugger scrub 变化 → 广播 `UE::StateTree::Delegates::OnTracingTimelineScrubbed(CurrentScrubTime)` → `FStateTreeDebugger::SetScrubTime`；`IsPIESimulating()` 时不广播（避免打断实时运行）；另广播 `OnTraceAnalysisStateChanged`【源码 StateTreeRewindDebuggerExtensions.cpp L18-49】 | `IRewindDebuggerExtension::ModularFeatureName` |
| `IRewindDebuggerTrackCreator`（`IRewindDebuggerTrackCreator.h`） | `UE::StateTreeDebugger::FRewindDebuggerTrackCreator` | **每实例轨道**：TargetType=`FStateTreeInstanceData` 结构名；TrackType=`"StateTreeInstances"`；`HasDebugInfoInternal` 查 Provider；`IsCreatingPrimaryChildTrackInternal()=true`【源码 StateTreeRewindDebuggerTrack.cpp L59-62】 | `IRewindDebuggerTrackCreator::ModularFeatureName` |

- 轨道本体：`UE::StateTreeDebugger::FRewindDebuggerTrack : RewindDebugger::FRewindDebuggerTrack, ITraceReader`——经 `ReadTrace` 增量重建事件与活动状态；双击轨道打开对应 `UStateTree` 资产编辑器【源码 StateTreeRewindDebuggerTrack.h L23-76, cpp L150-231】。
- **[5.8 变更]** 录制钩子搬家：`IRewindDebuggerExtension::RecordingStarted/RecordingStopped(IRewindDebugger*)` 已弃用（final 空实现），改由 `IRewindDebuggerRuntimeExtension` 承载；其 `RecordingStarted` 触发时机为 trace 连接建立（`FTraceAuxiliary::OnConnection`，任意线程），并可经 `RegisterMessageHandlers/RegisterMessageTypes` 接入远程调试消息系统【源码 IRewindDebuggerExtension.h L44-52; IRewindDebuggerRuntimeExtension.h L38-82】。
- `IRewindDebuggerRuntimeExtension` 引入版本【未证实/推断】为 5.8（头文件带 `UE_ENABLE_INCLUDE_ORDER_DEPRECATED_IN_5_8` 守卫 + 5.8 弃用注释指向它；本地无 5.7 源码比对）——见开放问题，不打行内版本标记。
- 零代码要求：实例必须以 `FStateTreeInstanceData` 承载数据并经 `FStateTreeExecutionContext` 正常 Start/Tick，实例发现依赖写入侧 `TRACE_INSTANCE` 注册；编辑器入口 Window → Virtual Production → Rewind Debugger。

## 7. 轻量调试层 RuntimeValidation 与 CrashReporter

### 7.1 RuntimeValidation（`WITH_STATETREE_DEBUG`）

5 组校验全部由 CVar 控制，报错形态统一为 `ensureAlwaysMsgf` + **首次触发后自动关闭自身 CVar**（防刷屏；复现需手动改回 1）【源码 StateTreeRuntimeValidation.cpp L13-248】：

| CVar | 默认 | 校验内容 |
|---|---|---|
| `StateTree.RuntimeValidation.Context` | true | 每次创建 `FStateTreeExecutionContext` 的 Owner/StateTree 是否与该实例数据此前记录一致（`FRuntimeValidationInstanceData::SetContext`） |
| `StateTree.RuntimeValidation.DoesNewerVersionExists` | true | 默认/节点实例数据类型是否带 `RF_NewerVersionExists` 等标记（BP 重编译后旧类型仍被引用） |
| `StateTree.RuntimeValidation.EnterExitState` | false | 节点 EnterState/ExitState 配对（按 NodeID+FrameID 记账；树退出仍有未配对项报 "Missing ExitState"） |
| `StateTree.RuntimeValidation.InstanceData` | false | 默认实例数据与共享实例数据 `AreAllInstancesValid()` |
| `StateTree.RuntimeValidation.InstanceDataGC` | false（StateTreeModule.cpp L44-51） | 每次 GC 后检查节点实例是否被正确 GC（经 `FStateTreeModule::OnPreRuntimeValidationInstanceData/OnPostRuntimeValidationInstanceData`，PreGC/PostPurge 委托触发） |

挂载点：`FRuntimeValidation` 随实例数据存放（`FStateTreeInstanceData::GetRuntimeValidation()`）；节点进出由 `UE::StateTree::Debug::NodeEnter/NodeExit`（StateTreeDebug.cpp L50-78）驱动。

### 7.2 16 个节点调试委托（`UE::StateTree::Debug`，StateTreeDebug.h L111-253）

全部为 `DECLARE_TS_*` 线程安全多播（实际成员名带 `_AnyThread` 后缀，如 `UE::StateTree::Debug::OnTestCondition_AnyThread`），注释强调"在 StateTree 逻辑内部执行、StateTree 可在任意线程"——订阅方必须线程安全：

| 节点族 | 委托 | 参数载体 |
|---|---|---|
| 条件 ×3 | `OnConditionEnterState` / `OnTestCondition` / `OnConditionExitState` | `FNodeDelegate`（Context+`FNodeReference`+NodeGuid） |
| 评估器 ×3 | `OnEvaluatorEnterTree` / `OnTickEvaluator` / `OnEvaluatorExitTree` | 同上 |
| 任务 ×3 | `OnTaskEnterState` / `OnTickTask` / `OnTaskExitState` | 同上 |
| 阶段 ×2 | `OnBeginUpdatePhase` / `OnEndUpdatePhase` | `FPhaseDelegate` |
| 状态/转换 ×2 | `OnStateEvent` / `OnTransitionEvent` | `FStateDelegate` / `FTransitionDelegate` |
| 事件收发 ×2 | `OnEventSent` / `OnEventConsumed` | `FEventSentDelegateArgs` |
| 效用评分 ×1 | `OnStateUtilityEvaluated` | — |

配套宏族 `UE_STATETREE_DEBUG_*`（执行上下文内组合"委托广播 + `TRACE_STATETREE_*`"）；宿主可用 `UE_STATETREE_DEBUG_LOG_EVENT(Context, Verbosity, Format, ...)` 输出自定义日志（会进 Trace 的 `LogEvent`）。

### 7.3 CrashReporter 崩溃上下文注入

- 开关：`UE_WITH_STATETREE_CRASHREPORTER := WITH_ADDITIONAL_CRASH_CONTEXTS`（Desktop 平台=1）【源码 StateTreeCrashReporterHandler.h L8-10; Core.Build.cs L268-272】。
- 机制：`FStateTreeModule::StartupModule` → `UE::StateTree::FCrashReporterHandler::Register()` 订阅 `FGenericCrashContext::OnAdditionalCrashContextDelegate`；崩溃时把每个活跃作用域写成键 `"StateTree<N>"`，值为四行：Owner 全名、`UStateTree` 全名、Context FName（Start/Stop/Tick）、ThreadID【源码 cpp L73-114, L132-142】。
- 挂载：RAII 宏 `UE_STATETREE_CRASH_REPORTER_SCOPE(InOwner, InStateTree, InContext)`（即 `UE::StateTree::FCrashReporterScope`），用在 `FStateTreeExecutionContext::Start/Stop/Tick` 共 5 处【源码 StateTreeExecutionContext.cpp L1465/1679/1816/1837/1857】。
- 运行时开关：CVar `StateTree.CrashHandlerEnabled`（默认 true）；刻意避免崩溃路径内存分配（复用 StringBuilder、TInlineAllocator）。

## 8. StateTreeDeveloper 模块职责

定位：Runtime 与 Editor 共用的最小调试层（DeveloperTool 模块，不依赖 UnrealEd），承载 RewindDebugger 录制接入与基础调试控件。

| 文件 | 职责 |
|---|---|
| `Private\StateTreeDeveloperModule.cpp` | 模块入口：`FStateTreeStyle::Register()` + `WITH_STATETREE_TRACE` 下注册 `FRewindDebuggerRecordingExtension`【源码 L12-29】 |
| `Private\StateTreeRewindDebuggerRecordingExtension.h/.cpp` | 录制扩展（见 §6） |
| `Internal\Widgets\SCompactTreeView.h` + `Private\Widgets\SCompactTreeView.cpp` | 紧凑状态树基础控件（非调试场景也可用） |
| `Internal\Debugger\SCompactTreeDebuggerView.h` + `Private\Debugger\SCompactTreeDebuggerView.cpp` | `UE::StateTree::Editor::SCompactTreeDebuggerView : SCompactTreeView`：按 `FStateTreeTraceActiveStates`（含 Linked 资产分组）高亮当前活动状态【源码 h L46-78】 |
| `Internal\Debugger\SStateTreeFrameEventsView.h` + `Private\Debugger\SStateTreeFrameEventsView.cpp` | `UE::StateTreeDebugger::SFrameEventsView`：给定帧的 Trace 事件树（含属性展开）；`RequestRefresh(FScrubState)` / `SelectByPredicate`【源码 h L25-52】 |
| `Private\Debugger\SStateTreeDebuggerViewRow.h/.cpp` | `FFrameEventTreeElement` + `SFrameEventViewRow`（事件树行：图标/文本/Tooltip） |
| `Public\StateTreeStyle.h` + `Private\StateTreeStyle.cpp` | 调试 UI 样式集 |

这些控件均为导出 API，可被自定义工具复用（数据源 `FStateTreeDebugger`/`FInstanceEventCollection`/`FScrubState` 均为 `STATETREEMODULE_API` 导出）。

## 9. 编辑器调试入口

> 本节只列入口与数据链路；**Debugger 标签页的视图实现细节见本文档 §8（StateTreeDeveloper 共用控件）与 §9 末条（调试 UI 文件清单）；editor.md 仅含 tab 注册入口**。

- 宿主：资产编辑器 "Debugger" 标签页由 `FStateTreeEditorModeToolkit::UpdateDebuggerView()`（`WITH_STATETREE_TRACE_DEBUGGER` 域）装载 `SStateTreeDebuggerView`【源码 StateTreeEditorModeToolkit.cpp L183-187, L460-462, L660】。
- **新旧形态**：`UStateTreeEditorSettings::bEnableLegacyDebuggerWindow` 默认 **false**——false 时标签页显示"连接 RewindDebugger / 选择实例"引导（**调试主入口是 RewindDebugger**），true 时显示完整遗留调试器【源码 StateTreeEditorSettings.h L46-56】；遗留窗另有 `bShouldDebuggerAutoRecordOnPIE`（默认 true）、`bShouldDebuggerResetDataOnNewPIESession`（默认 false）。
- 断点编辑链路：Details 面板/行上下文菜单（`UE::StateTreeEditor::DebuggerExtensions`：`CreateStateWidget`/`AppendStateMenuItems`/`CreateEditorNodeWidget`/`CreateTransitionWidget` 等）→ `FStateTreeViewModel::ToggleStateBreakpoints/ToggleTaskBreakpoint/ToggleTransitionBreakpoint` → `UStateTreeEditorData::Breakpoints`（`UPROPERTY(Transient)`，随资产不落盘）→ `RefreshDebuggerBreakpoints()` 映射为 `FStateTreeDebugger::Set*Breakpoint`【源码 StateTreeViewModel.h L203-222; StateTreeEditorData.h L359-366】。
- 命令集 `FStateTreeDebuggerCommands` 9 个 `FUICommandInfo`：`StartRecording`/`StopRecording`/`PreviousFrameWithStateChange`/`PreviousFrameWithEvents`/`NextFrameWithEvents`/`NextFrameWithStateChange`/`ResumeDebuggerAnalysis`/`ResetTracks`/`OpenRewindDebugger`【源码 StateTreeDebuggerCommands.h L20-28】。
- 节点描述提供者：`IStateTreeModule::GetDebugInfoProvider()` 模块默认实现只给节点名；编辑器以 `FStateTreeEditorDebugInfoProvider` 覆盖（经 EditorData+BindingLookup 生成富文本；CVar `StateTree.Debugger.EnableEditorDebugInfoProvider` 默认 true）【源码 StateTreeEditorModule.cpp L91-167, L251-254】。
- 调试 UI 文件（`StateTreeEditorModule\Private\Debugger\`）：`SStateTreeDebuggerView`（标签页宿主）、`SStateTreeDebuggerInstanceTree`（实例列表树）、`SStateTreeDebuggerTimelines`（时间滑条+轨道列表，持有 `RewindDebugger::FRewindDebuggerTrack`）、`SStateTreeDebuggerEventTimelineView`（点/窗口事件时间线渲染，自述为 RewindDebugger `SEventTimelineView` 的改版）、`StateTreeDebuggerTrack`（`FStateTreeDebuggerInstanceTrack`/`FStateTreeDebuggerOwnerTrack` 内嵌轨道，继承 `RewindDebugger::FRewindDebuggerTrack`）、`StateTreeDebuggerCommands`、`StateTreeDebuggerUIExtensions`、`StateTreeRewindDebuggerExtensions`、`StateTreeRewindDebuggerTrack`。

## 10. 开发者扩展工作流

### 10.1 让自定义宿主的 StateTree 实例出现在 RewindDebugger（零代码路径）

1. 宿主持有 `FStateTreeInstanceData` 并经 `FStateTreeExecutionContext` 正常 Start/Tick（实例发现依赖写入侧 `TRACE_INSTANCE` 注册与轨道 Creator 的 TargetTypeName）。
2. 编辑器打开 Rewind Debugger 并开始录制：`FRewindDebuggerRecordingExtension::RecordingStarted` 打开 `StateTreeDebugChannel`。
3. 回放/拖动时间线：`FRewindDebuggerPlaybackExtension` 同步 scrub → 每实例轨道经 `ReadTrace` 增量重建事件与活动状态，详情面板显示紧凑树+帧事件。
4. （可选）轨道上步进按钮自动以"事件帧边界"为步长；双击轨道打开对应 `UStateTree` 资产编辑器。

### 10.2 自定义节点 Trace 数据

1. 在任务/评估器/条件执行回调中构造 `UE::StateTreeTrace::FNodeCustomDebugData{TraceDebuggerString, EMergePolicy::Append 或 Override}`。
2. 调用 `Context.SetNodeCustomDebugTraceData(MoveTemp(Data))`（重复未消费设置会 `ensureMsgf` 报"嵌套调用"）。
3. 本次节点评估的下一个 `TRACE_STATETREE_TASK/EVALUATOR/CONDITION_EVENT` 发射时经 `StealNodeCustomDebugTraceData()` 消费；Override 时不导出实例数据、DebugText 单独成段【源码 StateTreeTrace.cpp L584-634】。

### 10.3 自定义 Trace 事件与调试视图

- **全新事件类型**：在自己模块内定义 `UE_TRACE_EVENT` + `UE_TRACE_LOG`，并自建 `TraceServices::IModule`（`FStateTreeTraceAnalyzer` 无扩展注册 API）：实现 IModule → `StartupModule` 时 `IModularFeatures::RegisterModularFeature(TraceServices::ModuleFeatureName, ...)` → `OnAnalysisBegin` 里 AddProvider/AddAnalyzer。
- **复用 StateTreeDeveloper 控件**：`SCompactTreeDebuggerView`（传入 `ActiveStates` Attribute）、`SFrameEventsView`（`RequestRefresh(FScrubState)`）、`SFrameEventViewRow`/`FFrameEventTreeElement`。
- **给 RewindDebugger 加自定义轨道**：继承 `RewindDebugger::IRewindDebuggerTrackCreator`（实现 `GetTargetTypeNameInternal/GetNameInternal/GetTrackTypesInternal/HasDebugInfoInternal/CreateTrackInternal`），编辑器模块 StartupModule 注册到其 ModularFeatureName；轨道继承 `RewindDebugger::FRewindDebuggerTrack`（可再实现 `ITraceReader` 直读 StateTree Trace）。
- **scrub 对齐类扩展**：实现 `IRewindDebuggerExtension`（Update/AnalysisSessionOpened/AnalysisSessionClosed/Clear/OnTrackListChanged）注册到其 ModularFeatureName。
- **运行时录制钩子**（游戏/独立进程）：实现 `IRewindDebuggerRuntimeExtension`（RecordingStarted/RecordingStopped/Clear，可加 `RegisterMessageHandlers/RegisterMessageTypes`）。
- **替换节点描述**：实现 `IStateTreeDebugInfoProvider` 并 `IStateTreeModule::Get().SetDebugInfoProvider(...)`（参考编辑器 `FStateTreeEditorDebugInfoProvider`）。

### 10.4 订阅运行时调试回调（`WITH_STATETREE_DEBUG` 目标）

1. Debug/Development 构建中订阅 `UE::StateTree::Debug::OnTestCondition_AnyThread.AddLambda(...)` 等（回调在 StateTree 执行线程触发，需线程安全）。
2. 配合 `TRACE_STATETREE_*` / `UE_STATETREE_DEBUG_*` 宏在宿主代码输出自定义调试信息。

## 11. 注意事项与坑

1. **Trace 与资产版本强绑定**：录制后重新编译资产（或分析进程内无该资产）→ 告警 "Traces are not using the same StateTree asset version"，该资产事件被丢弃【源码 StateTreeTraceAnalyzer.cpp L51-81】。
2. **`StartTraces` 会关掉其他所有 Trace 通道**：新建连接先禁用全部已开通道、只开 StateTree 两通道；对同时做性能 trace 的会话是干扰（见 §3.5）。
3. **断点是资产粒度**：不能按实例设断点；Linked 资产断点依赖逐帧比对（见 §5.2）。
4. **断点只在编辑器侧生效**：game 进程 `WITH_STATETREE_TRACE_DEBUGGER=0`，断点代码不编译。
5. **帧内不可 scrub**：每帧仅保留最后一条活动状态快照（见 §5.2 帧内限制）。
6. **任务实例数据文本有编辑器视角过滤**：`ExportText` 用 `PPF_PropertyWindow`（仅编辑器可见属性）+`PPF_IncludeTransient`；非编辑器可见属性不进 Trace；序列化有 `TRACE_CPUPROFILER_EVENT_SCOPE` 成本【源码 StateTreeTrace.cpp L586-621】。
7. **Shipping/Test 一刀切**：调试宏全为空——不要在 Shipping 代码路径保留对调试 API 的引用；`WITH_STATETREE_DEBUG` 连 Test 配置都不含。
8. **主机（Console）没有回放分析**：`IsStateTreeDebuggerSupported` 限定 Desktop，主机只能录制。
9. **RewindDebugger 会话优先**：调试器 Tick 优先复用其 analysis session；若同时用 Unreal Insights 开会话，注意会话生命周期归属（外部会话 Stop 时只释放引用）。
10. **PIE 模拟中 scrub 不广播**：`FRewindDebuggerPlaybackExtension::Update` 在 `IsPIESimulating()` 时跳过同步。
11. **资产编辑器默认已"迁移"**：`bEnableLegacyDebuggerWindow` 默认 false，遗留调试窗需在 Settings→Debugger 手动开启。
12. **跨进程录制**：非编辑器目标默认不自动录制（§3.5）；录制写 localhost Trace Store，分析端需同机（或 Store 转发）【源码 StateTreeModule.cpp L128-139, L200-274】。
13. **RuntimeValidation 报错自灭**：每个校验 CVar 首次 ensure 后自动置 false，复现第二次报错需手动改回 1。
14. **外部插件联动**：Avalanche 的 `UE_AVA_WITH_TRANSITION_DEBUG` 等直接依赖这组宏，关闭开关会连带改变其调试能力。

## 12. 版本敏感点

- **5.6**：`UE::StateTreeTrace::FindOrAddDebugIdForAsset` 弃用（DebugId 分配收归内部缓冲）；`StateTreeRuntimeValidation.h` 带 `UE_ENABLE_INCLUDE_ORDER_DEPRECATED_IN_5_6` include 顺序兼容——Debugger 目录在 5.6 前后有布局调整【源码 StateTreeTrace.h L116-117; StateTreeRuntimeValidation.h L7-9】。
- **5.7（Trace API 收编波）**：11 个 `Output*` 函数从 `FStateTreeInstanceDebugId` 参数版改为执行上下文指针版（5.8 中旧函数体已清空）；`FScrubState` 不再支持多事件集合；`FStateTreeDebugger` 多处签名更换（裸指针 Descriptor→`TSharedPtr` 等）；`IStateTreeTraceProvider::GetInstances` 数组版弃用；`IRewindDebuggerTrackCreator` 的 `uint64` ObjectId → `FObjectId`。详见 §13。
- **[5.8 变更]**：录制钩子迁到 `IRewindDebuggerRuntimeExtension`（【推断】本版新增，未证实）；UEFN/Shipping Editor 明确支持录制（`IsStateTreeTraceRecordingSupported` 注释 "Allow debugger traces on all non-shipping targets and shipping editors (UEFN)"）【源码 StateTreeModule.Build.cs L15-16】。
- 5.6/5.7 执行侧弃用（`EGenericAICheck`→`EComparisonOperator`、`FSelectStateResult` 贯穿等）详见 **runtime-execution.md** 与总览报告 §7；带 `FSelectStateResult` 的新内部调用形态是 Trace 事件发射点重构的伴生结果。

## 13. 弃用 API 列表

本模块范围内全部 UE_DEPRECATED 条目（对应调研报告 §3.6；1 行聚合 11 个 `Output*` 旧重载）：

| API | 弃用版本 | 替代品 |
|---|---|---|
| `UE::StateTreeTrace::FindOrAddDebugIdForAsset(const UStateTree*)` | 5.6（"will no longer be exposed publicly"） | 内部 `GBufferedEvents.FindOrAddDebugIdForAsset_AnyThread`【源码 StateTreeTrace.h L116-117】 |
| `OutputPhaseScopeEvent`/`OutputInstanceLifetimeEvent`/`OutputInstanceAssetEvent`/`OutputInstanceFrameEvent`/`OutputLogEventTrace`/`OutputStateEventTrace`/`OutputTaskEventTrace`/`OutputEvaluatorEventTrace`/`OutputConditionEventTrace`/`OutputTransitionEventTrace`/`OutputActiveStatesEventTrace` 的 `FStateTreeInstanceDebugId` 参数重载（11 个；5.8 函数体已清空） | 5.7（"Use the overload taking a pointer to the execution context instead."） | §3.2 的 Context 指针重载【源码 StateTreeTrace.h L118-139】 |
| `FScrubState(const TArray<FInstanceEventCollection>&)` 构造、`GetEventCollectionIndex`/`SetEventCollectionIndex` | 5.7（"FScrubState will no longer support multiple collections."） | 单集合构造 + `SetEventCollection`【源码 StateTreeDebuggerTypes.h L194-208】 |
| `FStateTreeDebugger::GetInstanceDescriptor`/`GetSelectedInstanceDescriptor`（返回裸指针） | 5.7 | `GetDescriptor`/`GetSelectedDescriptor`（返回 `TSharedPtr`）【源码 StateTreeDebugger.h L190-199】 |
| `FStateTreeDebugger::GetRecordingDuration` | 5.7 | `GetLastProcessedRecordedWorldTime`【源码 StateTreeDebugger.h L245-249】 |
| `FStateTreeDebugger::GetSessionInstances(TArray<FInstanceDescriptor>&)` | 5.7 | `GetSessionInstanceDescriptors`（`TSharedRef` 版）【源码 StateTreeDebugger.h L332-334】 |
| 委托类型 `FOnStateTreeDebuggerDebuggedInstanceSet` 及成员 `FStateTreeDebugger::OnSelectedInstanceCleared` | 5.7（"no longer used and will be removed"） | 无【源码 StateTreeDebugger.h L79-80, L339-342】 |
| `IStateTreeTraceProvider::GetInstances(TArray<UE::StateTreeDebugger::FInstanceDescriptor>&)` | 5.7（final 空实现） | `TSharedRef` 版本【源码 IStateTreeTraceProvider.h L33-36】 |
| `RewindDebugger::IRewindDebuggerTrackCreator` 的 `uint64` 重载（`HasDebugInfo`/`CreateTrack`/`HasDebugInfoInternal`/`CreateTrackInternal`） | 5.7 | `FObjectId` 版本【源码 IRewindDebuggerTrackCreator.h L67-90, L134-149】 |
| `IRewindDebuggerExtension::RecordingStarted`/`RecordingStopped(IRewindDebugger*)` | 5.8（final 空实现；"Use AnalysisSessionOpened instead or implement an extension inheriting from IRewindDebuggerRuntimeExtension"） | `IRewindDebuggerRuntimeExtension::RecordingStarted`/`RecordingStopped`【源码 IRewindDebuggerExtension.h L44-52】 |

## 开放问题

以下为调研报告（`10-debugging-trace.md` §8）中的未证实/存疑项，使用本文档结论时注意边界：

1. 【未证实】`IRewindDebuggerRuntimeExtension` 的引入版本：头文件 5.8 弃用守卫 + 5.8 弃用注释指向 5.8 新增，但本地无 5.7 源码比对（本文按【推断】处理，不打行内版本标记）。
2. 【未证实】`WITH_ADDITIONAL_CRASH_CONTEXTS` 在主机平台的精确取值：Core.Build.cs 仅对 Desktop 显式置 1，`GenericPlatformCrashContext.h` 默认 1；个别平台头是否覆盖为 0 未逐平台核实——主机上 StateTree 崩溃上下文是否可用存疑。
3. 【未证实】`StateTree.RuntimeValidation.InstanceDataGC` 的实际校验执行者：`FStateTreeModule::OnPre/PostRuntimeValidationInstanceData` 的订阅方代码未定位（疑在 StateTreeInstanceData.cpp）。
4. 【未证实】UEFN 目标的开关取值：`WITH_STATETREE_TRACE(_DEBUGGER)=1` 由 Build.cs 条件与注释推出（Shipping+Editor+Desktop），无 UEFN target 定义本地证据。
5. 【未证实】"consoles don't have TraceAnalysis support"（Build.cs L25 注释）未逐平台验证，仅引述注释。
6. 【未证实】`SStateTreeDebuggerView.cpp` 的 PIE 录制/暂停/恢复细节（`HandleTracesStateChanged` 等）只读了头文件与宿主挂载点，未逐行核实自动录制的确切触发链（属 editor.md 范畴，待该文档复核）。
7. 【未证实】≤5.6 的历史调试器形态（旧 `FStateTreeDebugger` API、多集合 ScrubState 的原始设计）依赖弃用注释回溯，本地无旧版源码验证。
