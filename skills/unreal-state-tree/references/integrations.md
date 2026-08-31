# Unreal StateTree 外部集成参考（integrations）

> 版本基线：UE 5.8.0 (Release-5.8, CL 55116800) · 版本标记约定：**[UE 5.x+]**=该版本新增，**[仅 <5.x]**=已移除/旧行为，**[5.8 变更]**=本版变更；现行 API 判定标准=声明无 UE_DEPRECATED 标记。

> 证据约定：【源码】= 本机 UE 5.8 源码证实；文件引用相对其集成模块根（绝对路径见 §1.1），`Lxx`=行号；【推断】/【未证实】= 存疑，见 §10。

## TL;DR

- 5.8 的 StateTree 外部集成面全部在插件层，共 9 个接入点；8/9 个 .uplugin 标 `IsExperimentalVersion: true`（仅 Avalanche（FriendlyName "Motion Design"，同一插件）无标记；Mass 全家官方 Release 仍 experimental）。
- 宿主三形态：**组件式**（UStateTreeComponent+ScheduledTick，细节→gameplay-state-tree.md）、**每次调用重建式**（GameplayInteractions/Avalanche/GameplayCameras）、**遍历驱动式**（UAF）。
- Mass 独树一帜：Trait 挂 SharedFragment+InstanceFragment，ActivationProcessor 驱动 Start，信号驱动 Tick（非 Running→Tick(0) 重试→NewStateTreeTaskRequired），动态 Processor 按依赖哈希生成，客户端不跑。
- 上下文注入两路：`SetContextDataByName`（命名）/ `SetCollectExternalDataCallback`（类型描述），所有宿主以 `AreContextDataViewsValid()` 收口。
- ExecutionExtension 四钩子：GetInstanceDescription / ScheduleNextTick / OnLinkedStateTreeOverridesSet / OnBeginApplyTransition；Mass/Avalanche 用前者，组件宿主用 ScheduleNextTick。
- 自定义宿主 10 步清单见 §7（customization-guide.md 只链接本文档、不复制）；三路线取舍：组件式/重建式/遍历式。
- 关键坑：UAF 宿主不调 Stop（UE-240683）；`GetParameters()`/`GetGlobalParameters()` 并存无弃用，5.8 起 Start 推荐 FConstStructView 形态。

## 目录

1. 集成点总览（9 接入点档案 / 实验状态 / 幽灵集成）
2. 宿主三形态与四要素对照
3. MassAIBehavior 集成详解
4. 其余四宿主档案（GameplayInteractions / UAFStateTree / GameplayCameras / Avalanche）
5. 宿主公共 API 与上下文注入两路
6. ExecutionExtension 四钩子
7. 自定义宿主接入：10 步清单与路线取舍
8. 弃用与版本敏感 API
9. 关键坑速查
10. 开放问题

> 分工边界：UStateTreeComponent 组件细节 → `gameplay-state-tree.md`（本文档仅作对照锚）；事件委托/事件队列语义 → `events-async.md`；`customization-guide.md` 只链接 §7 清单、不复制——若发现重复，以本文档为权威。

## 1. 集成点总览

### 1.1 九个接入点档案

| # | 集成点 | 插件/模块根（绝对路径） | 宿主形态 | .uplugin 实验状态【源码】 | 一句话 |
|---|---|---|---|---|---|
| 1 | MassAIBehavior | `E:\UnrealEngine\UE_5.8\Engine\Plugins\AI\MassAI\Source\MassAIBehavior`（MassAI 插件） | 独立宿主体系（Trait+Processor+Subsystem） | `MassAI.uplugin`：`IsExperimentalVersion: true`，EnabledByDefault=false | Mass 行为层：头文件仍名 `MassStateTree*`（历史更名证据），用 StateTree 驱动 MassEntity 行为 |
| 2 | GameplayInteractions | `E:\UnrealEngine\UE_5.8\Engine\Plugins\Runtime\GameplayInteractions\Source\GameplayInteractionsModule` | 独立宿主（FGameplayInteractionContext）+ SmartObject 行为定义 | `GameplayInteractions.uplugin`：`IsExperimentalVersion: true` | Smart Object 交互：交互上下文包裹 StateTree 执行 |
| 3 | UAFStateTree | `E:\UnrealEngine\UE_5.8\Engine\Plugins\Experimental\UAF\UAFStateTree\Source\UAFStateTree`（+ UAFStateTreeEditor / UAFStateTreeUncookedOnly） | 遍历驱动宿主（Trait + AnimNode 双路径） | `UAFStateTree.uplugin`：`IsExperimentalVersion: true`，VersionName "0.1"，Category=Animation | UAF/AnimNext 动画状态树（动画域，实验） |
| 4 | GameplayCameras | `E:\UnrealEngine\UE_5.8\Engine\Plugins\Cameras\GameplayCameras\Source\GameplayCameras`（Directors 子目录） | 独立宿主（FStateTreeCameraDirectorEvaluator） | `GameplayCameras.uplugin`：`IsExperimentalVersion: true`，EnabledByDefault=true | 相机导演：StateTree 决定每帧激活哪些 Camera Rig |
| 5 | Avalanche | `E:\UnrealEngine\UE_5.8\Engine\Plugins\VirtualProduction\Avalanche\Source\AvalancheTransition`（主插件多模块：AvalancheTransition/AvalancheSequence/AvalancheCamera/AvalancheTransitionEditor） | 独立宿主（FAvaTransitionBehaviorInstance + FAvaTransitionExecutor） | `Avalanche.uplugin`（FriendlyName="Motion Design"）：**无 IsExperimentalVersion 标记**；EnabledByDefault=false | 虚拟制作转场：UAvaTransitionTree : UStateTree 资产子类驱动场景转场；引用面最重（69 文件） |
| 6 | MetaHumanCrowd | `E:\UnrealEngine\UE_5.8\Engine\Plugins\MetaHuman\MetaHumanCrowd\Source\MetaHumanCrowd`（Private\Mass） | 节点级扩展（无独立宿主） | `MetaHumanCrowd.uplugin`：`IsExperimentalVersion: true` | 3 个 Mass StateTree 节点：FMetaHumanMassTargetLocationEvaluator + 2 个寻点/寻位 Task |
| 7 | MassCrowd | `E:\UnrealEngine\UE_5.8\Engine\Plugins\AI\MassCrowd\Source\MassCrowd`（Tasks 子目录） | 节点级扩展（无独立宿主） | `MassCrowd.uplugin`：`IsExperimentalVersion: true` | 2 个 Mass StateTree 任务：FMassCrowdClaimWaitSlotTask / FMassZoneGraphFindWanderTarget |
| 8 | MassGameplayDebug | `E:\UnrealEngine\UE_5.8\Engine\Plugins\Runtime\MassGameplay\Source\MassGameplayDebug` | 依赖残余（见 §1.3） | `MassGameplay.uplugin`：`IsExperimentalVersion: true` | 调试模块；源码中无任何 "StateTree" 字符串【源码，rg 扫描】 |
| 9 | StateTreeToolset | `E:\UnrealEngine\UE_5.8\Engine\Plugins\Experimental\Toolsets\StateTreeToolset\Source\StateTreeToolset` | 空壳（见 §1.3） | `StateTreeToolset.uplugin`：`IsExperimentalVersion: true`，EditorOnly、NoRedist | "Toolset for StateTree Inspection"；uplugin 插件级依赖 StateTree，模块代码不含 StateTree API |

### 1.2 实验状态横切事实

- 9 个接入点中 8 个 `.uplugin` 标 `IsExperimentalVersion: true`；仅 Avalanche 无此标记（生产/虚拟制作定位）【源码，各 .uplugin】。
- Mass 全家（MassAI/MassCrowd/MassGameplay）在 5.8 官方 Release 的插件级标记仍是 experimental——与社区"Mass 生产可用"的普遍认知存在张力，决策以本机证据为准。

### 1.3 幽灵集成与轻度集成（引用面调研先验证实际使用）

- **MassGameplayDebug**：Build.cs 依赖 StateTreeModule，代码 0 引用【源码，rg 扫描】。
- **StateTreeToolset**：空壳——`StateTreeToolset.cpp` 全文 16 行（仅模块生命周期 + log category），Build.cs 只依赖 Core；StateTree 是 uplugin 插件级依赖。对总览调研的修正：其 "1 include" 实为 `#include "StateTreeToolset.h"`（同名头命中），非 StateTree API 引用。
- **MassAIDebug**（MassAI 插件内）：轻度集成——`UMassDebugStateTreeProcessor`（UMassProcessor 调试遍历）+ `GameplayDebuggerCategory_Mass`【源码 MassAIDebug\Public\MassDebugStateTreeProcessor.h】；确切用途【未证实】（§10）。
- **GameplayInteractions 无 Mass 桥（本构建）**：全引擎无 Mass 侧处理器引用 GameplayInteraction；`GameplayInteractionsModule.Build.cs` 不依赖任何 Mass 模块——本 Release 驱动入口是 Private 的 `UAITask_UseGameplayInteraction`。不要照搬"Mass 驱动交互"的旧教程。

## 2. 宿主三形态与四要素对照

### 2.1 四要素总表（Schema / 上下文注入 / ExecutionExtension / Start-Tick 驱动）

| 集成 | Schema | 上下文注入 | ExecutionExtension | Start/Tick 驱动 |
|---|---|---|---|---|
| MassAIBehavior | UMassStateTreeSchema（白名单+依赖收集） | 无命名注入；FOnCollectStateTreeExternalData（Mass Fragment/Subsystem→EntityView） | FMassExecutionExtension（Entity+OverridesHash） | UMassStateTreeActivationProcessor（Start）+ 信号驱动 UMassStateTreeProcessor（Tick） |
| GameplayInteractions | UGameplayInteractionStateTreeSchema | SetContextDataByName×5 + CollectExternalData lambda | 无 | FGameplayInteractionContext::Activate/Tick/Deactivate（AITask 驱动） |
| UAFStateTree | UStateTreeAnimNextSchema | SetContextDataByName(AnimStateTreeExecutionContextName) + CollectExternalData lambda + SetExternalGlobalParameters | 无 | UAF 动画图遍历（OnBecomeRelevant=Start / PreUpdate=Tick） |
| GameplayCameras | UCameraDirectorStateTreeSchema | SetContextDataByName(ContextOwner) + CollectExternalData lambda（EvaluationData 暂存） | 无 | 相机求值生命周期（OnActivate/OnRun/OnDeactivate） |
| Avalanche | UAvaTransitionTreeSchema | CollectExternalData lambda（FAvaTransitionContext+UWorldSubsystem） | FAvaTransitionExecutionExtension（GetInstanceDescription） | FAvaTransitionExecutor → FAvaTransitionBehaviorInstance::Tick |
| UStateTreeComponent（对照锚，非本批接入点） | UStateTreeComponentSchema | virtual SetContextRequirements() | FStateTreeComponentExecutionExtension（ScheduleNextTick 接组件 Tick） | BeginPlay 自动 StartLogic / TickComponent + ScheduleTickFrame |

（UStateTreeComponent 组件细节 → gameplay-state-tree.md，本文档只作对照锚。）

### 2.2 宿主三形态

| 形态 | 代表 | 生命周期/驱动 | 取舍 |
|---|---|---|---|
| 组件式 | UStateTreeComponent / UStateTreeAIComponent（GameplayStateTree 插件） | BeginPlay 自动 StartLogic（bStartLogicAutomatically）；TickComponent + ScheduleTickFrame(FStateTreeScheduledTick) 按需开关节拍（配合 Extension.ScheduleNextTick） | 适合 NPC/Actor 常驻行为；成本：处理 Pause/Resume/重入。细节→gameplay-state-tree.md |
| 每次调用重建式 | GameplayInteractions / Avalanche / GameplayCameras | 生命周期离散（交互开始/结束、转场、相机激活/停用）；每次 Start/Tick/Stop 前重建 FStateTreeExecutionContext（TOptional 或局部变量） | 收益：实例数据与生命周期强绑定、无悬挂；成本：每 tick 构造开销（官方接受；Mass 另用 CSV 计时盯此项） |
| 遍历驱动式 | UAFStateTree | 嵌入动画图 update traversal（OnBecomeRelevant=Start、PreUpdate=Tick），宿主自身无 Tick 概念 | 收益：零调度侵入；成本：Stop 时机难（官方至今未解决，UE-240683）；GC 需 trait 接口配合 |

- 状态通知：本批集成宿主**无** OnStateTreeRunStatusChanged 等价广播（组件宿主才有，→gameplay-state-tree.md）；Avalanche 用 ConditionallyStop + RunStatus 字段查询（IsRunning）代替。
- 选择结论：宿主就是"Actor 上跑一棵树"→ 直接用/继承 UStateTreeComponent（已实现 IGameplayTaskOwnerInterface + IStateTreeSchemaProvider，virtual SetContextRequirements/CollectExternalData 是官方扩展点）；只有**非 Actor 载体、批量实例池、非常规驱动（信号/动画遍历/播放链）**才按 §7 自建。

## 3. MassAIBehavior 集成详解

### 3.1 运行链路总图

【源码，全部出自 MassAIBehavior 模块根】

```
UMassStateTreeTrait (BuildTemplate)
  └─ 挂 FMassStateTreeSharedFragment（ConstShared，持 UStateTree 资产指针，同资产实体共享一份）
  └─ 挂 FMassStateTreeInstanceFragment（每实体 InstanceHandle + LastUpdateTimeInSeconds）
        │  实体生成后
        ▼
UMassStateTreeActivationProcessor（ExecuteAfter=LOD 组，ExecuteBefore=Behavior 组，GameThread）
  └─ AllocateInstanceData（UMassStateTreeSubsystem 池，Generation 句柄）
  └─ FMassStateTreeExecutionContext::Start() → 加 FMassStateTreeActivatedTag → 发 "StateTreeActivate" 信号
        │  信号进入下一处理阶段
        ▼
UMassStateTreeProcessor（UMassSignalProcessorBase，动态生成，依赖哈希去重，ExecutionInGroup=Behavior）
  └─ SignalEntities：每实体 Tick(AdjustedDeltaTime)；非 Running → Tick(0) 重试一次；仍非 Running → 发 "NewStateTreeTaskRequired"
        │
        ▼
UMassStateTreeFragmentDestructor（观察 FMassStateTreeInstanceFragment 的 Remove）→ Stop() + FreeInstanceData
```

### 3.2 Trait 挂载与 Fragment 布局

- `UMassStateTreeTrait : UMassEntityTraitBase`，属性 `TObjectPtr<UStateTree> StateTree` 带 `meta=(RequiredAssetDataTags="Schema=/Script/MassAIBehavior.MassStateTreeSchema")`——编辑期强制资产 Schema【MassStateTreeTrait.h L25-26】。
- `BuildTemplate`：先按 `UE::MassStateTree::ExecutionFlags`（=`Standalone\|Server`）过滤执行模式（**客户端不跑**）→ `GetOrCreateConstSharedFragment(FMassStateTreeSharedFragment)`（所有同资产实体共享一份）→ `AddFragment<FMassStateTreeInstanceFragment>()`【MassStateTreeTrait.cpp L16-52】。
- `ValidateTemplate`：校验 `UStateTree::IsReadyToRun()` + 每个 Required 外部数据可满足（UWorldSubsystem 查 World、Fragment 族查模板已挂），缺失记入 `FAdditionalTraitRequirements` 并报错【MassStateTreeTrait.cpp L54-131】。

### 3.3 Start / Tick / Stop 驱动

- **Start（UMassStateTreeActivationProcessor）**：查询条件 = InstanceFragment + SharedFragment + **无** FMassStateTreeActivatedTag（EMassFragmentPresence::None）+ 可选 FMassSimulationVariableTickChunkFragment（LOD）；`bRequiresGameThreadExecution=true`（UMassStateTreeSubsystem RW 访问）；执行流 = 分配实例数据 → Start →（延迟）加 ActivatedTag → SignalEntities(StateTreeActivate)；每 LOD 受 `UMassBehaviorSettings.MaxActivationsPerLOD` 限流【MassStateTreeProcessors.cpp L161-247】。
- **Tick（UMassStateTreeProcessor : UMassSignalProcessorBase，信号驱动，无自主 Tick）**：SignalEntities 每实体 `AdjustedDeltaTime = TimeInSeconds - LastUpdateTimeInSeconds`（1/256 精度截断）→ `FMassStateTreeExecutionContext::Tick(AdjustedDeltaTime)`；`GetLastTickStatus() != Running` → 立即 `Tick(0.0f)` 重试找新状态；仍不行 → 实体加入 `NewStateTreeTaskRequired` 信号队列（下一信号阶段再试）【MassStateTreeProcessors.cpp L313-407】。
- **Stop（UMassStateTreeFragmentDestructor）**：UMassObserverProcessor 观察 FMassStateTreeInstanceFragment 的 Remove → `Stop()` + `FreeInstanceData`【MassStateTreeProcessors.cpp L100-156】。

### 3.4 动态 Processor：生成、去重与替换

- **生成**：`UMassStateTreeSubsystem::CreateProcessorForStateTree` 把 Schema `Dependencies`（Link 期由 `UMassStateTreeSchema::Link()` 经各节点 `GetDependencies(FStateTreeDependencyBuilder&)` 收集，含 LinkedAsset 递归）转成 `FMassFragmentRequirements`/`FMassSubsystemRequirements`（按 FMassFragment/FMassTag/FMassChunkFragment/FMassSharedFragment/FMassConstSharedFragment/USubsystem 六路分发）→ **依赖哈希查重** → `NewObject<UMassStateTreeProcessor>(this, DynamicProcessorClass)` → `SetExecutionRequirements`（保证 processor 落在 Mass 处理图正确位置、避免数据竞争）→ `SimulationSubsystem->RegisterDynamicProcessor` → `AddHandledStateTree`（chunk filter 按 `FMassStateTreeSharedFragment.StateTree ∈ HandledStateTrees` 过滤——**一个 processor 可服务多棵需求相同的树**）【MassStateTreeSubsystem.cpp L91-176】。
- **替换扩展**：派生 `UMassStateTreeProcessor` 并设为 `UMassStateTreeSubsystem.DynamicProcessorClass`；配置入口 `UMassBehaviorSettings::DynamicStateTreeProcessorClass`（config=Mass，NoClear）【MassStateTreeProcessors.h L66-70、MassBehaviorSettings.h L28-29】。`NewObject` 失败直接 `checkf` 崩溃——配置非派生类且构造失败即崩【MassStateTreeSubsystem.cpp L159-160】。
- **Schema 侧约束**：`UMassStateTreeSchema::IsStructAllowed` 只放行四个 Mass 节点基类（FMassStateTreeEvaluatorBase / FMassStateTreeTaskBase / FMassStateTreeConditionBase / FMassStateTreePropertyFunctionBase）+ StateTree CommonBase 族；`IsExternalItemAllowed` 只允许 UWorldSubsystem 子类与 FMassFragment/FMassSharedFragment/FMassConstSharedFragment；`AllowQueuedCompilation()=false` 禁队列编译（防 Mass worker 线程触发编译）【MassStateTreeSchema.cpp L20-40、MassStateTreeSchema.h L23-29】。
- 开关：CVar `ai.mass.DynamicSTProcessorsEnabled`（ReadOnly，默认 true；关闭后 Tick 驱动归属回退路径【未证实】）【MassStateTreeSubsystem.cpp L18-24】。

### 3.5 两级依赖：LinkExternalData ≠ GetDependencies

| 层级 | 机制 | 作用 | 范本 |
|---|---|---|---|
| 数据访问级 | 任务持 `TStateTreeExternalDataHandle<T>` 族成员 + `FStateTreeLinker::LinkExternalData(Handle)` | 声明运行期读写的 fragment；EnterState/Tick 经 `Context.GetExternalData(Handle)` 直读 Mass fragment | FMassNavMeshPathFollowTask（链 8 个句柄，写 FMassMoveTargetFragment / FMassDesiredMovementFragment）【MassNavMeshPathfollowTask.h L70-81】 |
| 调度声明级 | 覆写 `GetDependencies(FStateTreeDependencyBuilder&)`（`AddReadOnly<T>()` / `AddReadWrite<T>()`，支持 UObject 类、Fragment 结构体与句柄三种重载，定义于 `MassStateTreeDependency.h`） | 决定节点依赖进入动态 processor 的 query/处理图位置 | FMassZoneGraphStandTask、SmartObject 任务族、FMassCrowdClaimWaitSlotTask【MassCrowdClaimWaitSlotTask.h L37-56】 |

- 两者**解耦**：FMassNavMeshPathFollowTask 链接 8 个 fragment 句柄却不覆写 GetDependencies——这些 fragment 不参与动态 processor 的调度声明，CollectExternalData 仍可经 EntityView 直接读实体 archetype 数据。
- 排障口诀：processor 顺序不对/数据竞争 → 先分清改哪一层。

### 3.6 完成闭环与信号协议

- **完成回传**：任务把"行为完成"翻译回 StateTree 唤醒——`FMassZoneGraphStandTask::EnterState` → `MassSignalSubsystem.DelaySignalEntityDeferred(..., UE::Mass::Signals::StandTaskFinished, Entity, Duration)`【MassZoneGraphStandTask.cpp L82】。
- **延迟转换**：`FMassStateTreeExecutionContext::BeginDelayedTransition` 覆写 → `DelaySignalEntityDeferred(DelayedTransitionWakeup, Entity, TimeLeft + KINDA_SMALL_NUMBER)`——用 Mass 信号系统替代引擎定时器实现"到点再 Tick 验条件"【MassStateTreeExecutionContext.cpp L185-193】。
- **信号协议全集**：`UE::Mass::Signals`（MassStateTreeTypes.h L30-40）：StateTreeActivate / NewStateTreeTaskRequired / DelayedTransitionWakeup / StandTaskFinished / AnimateTaskFinished / LookAtFinished / ContextualAnimTaskFinished + SmartObject 五信号 + FollowPointPath 两信号 + CurrentLaneChanged / AnnotationTagsChanged / HitReceived；`UMassStateTreeProcessor::InitializeInternal` 订阅全部任务信号【MassStateTreeProcessors.cpp L273-301】。
- Mass 域的通知主机制是 **Mass 信号而非 StateTree 事件队列**——树间/任务→树通知走信号；事件队列语义 → events-async.md。
- 调试：`WITH_MASSGAMEPLAY_DEBUG` 下 UMassStateTreeProcessor 对调试实体 VLog 触发 Tick 的信号名列表【MassStateTreeProcessors.cpp L337-354】；`MASSBEHAVIOR_LOG` / `MASSBEHAVIOR_CLOG` 宏统一实体级日志格式【MassAIBehaviorTypes.h L30-38】。

### 3.7 客户端、限流与实例池语义

- **客户端不跑**：`UE::MassStateTree::ExecutionFlags = Standalone\|Server`，BuildTemplate 按 World 执行模式过滤【MassStateTreeTypes.h L24、MassStateTreeTrait.cpp L18-23】——预期"客户端也有行为"会落空。
- **激活限流**：MaxActivationsPerLOD 让新实体树延迟 Start（ActivationProcessor 按 LOD 计数跳过 chunk）——"实体生成后第一帧没有状态"先查这里【MassStateTreeProcessors.cpp L203-208】。
- **实例池句柄**：`UMassStateTreeSubsystem::FreeInstanceData` 后同 slot Generation++，旧句柄 `IsValidHandle` 返回 false；Tick 路径 `GetInstanceData` 拿 nullptr 时**静默跳过**该实体【MassStateTreeSubsystem.h L67-78、MassStateTreeProcessors.cpp L50-51】。

## 4. 其余四宿主档案

### 4.1 GameplayInteractions（Smart Object 交互）

| 维度 | 内容【源码 GameplayInteractionsModule】 |
|---|---|
| 资产锚点 | UGameplayInteractionSmartObjectBehaviorDefinition : USmartObjectBehaviorDefinition，持 FStateTreeReference，meta `Schema="/Script/GameplayInteractionsModule.GameplayInteractionStateTreeSchema"` |
| Schema | UGameplayInteractionStateTreeSchema：可配置 ContextActorClass + SmartObjectActorClass（允许绑定具体 Actor 类属性）；GetContextDataDescs() 命名外部数据（构造填充，PostEditChangeChainProperty 同步） |
| 宿主 | FGameplayInteractionContext（USTRUCT）：FStateTreeInstanceData + ClaimedHandle / SlotEntranceHandle / 双 Actor / AbortContext + CurrentlyRunningExecContext 重入哨兵 |
| 驱动 | Activate()（防重入 → ValidateSchema 运行时校验 Actor 类 → SetContextRequirements → SmartObject slot 写 UserActor → Start）→ Tick()（返回 RunStatus==Running）→ Deactivate()（Stop + 清 UserActor）→ SendEvent()（FStateTreeMinimalExecutionContext） |
| 驱动方（本构建） | UAITask_UseGameplayInteraction : UAITask（Private-only，非公开 API 面）；含 MoveTo 前置（MoveToAndUseSmartObjectWithGameplayInteraction）与 RequestAbort |
| ExecutionExtension | 无；Start 用 `StateTreeReference.GetGlobalParameters()`（5.8 形态） |
| 坑 | Activate/Tick 重入直接返回 false 并记 Error（非优雅排队）；无 Mass 桥（§1.3） |

### 4.2 UAFStateTree（动画域，实验）

| 维度 | 内容【源码 UAFStateTree】 |
|---|---|
| Schema | UStateTreeAnimNextSchema（Internal 目录，HideDropDown）：GetContextDataDescs 命名注入；GetGlobalParameterDataType() 覆写（全局参数类型定制）；编辑器禁用 Utility Considerations / Evaluators / 队列编译；静态名 AnimStateTreeExecutionContextName |
| 资产 | UAnimNextStateTree : UUAFAnimGraph（编译产物内嵌 `TObjectPtr<UStateTree> StateTree` + 自定义版本 FAnimNextStateTreeCustomVersion） |
| 宿主双路径 | ① Trait：UE::UAF::FStateTreeTrait（TraitCore，AUTO_REGISTER_ANIM_TRAIT，IUpdate+IGarbageCollection）+ FAnimNextStateTreeTraitSharedData（FStateTreeReference ExportAsReference + FStateTreeReferenceOverrides + latent pins）；② AnimNode：FUAFStateTreeNode : FUAFBlendStack + FUAFStateTreeNodeData（Start 细节【未证实】，§10） |
| 上下文 | SetContextDataByName(AnimStateTreeExecutionContextName) 交 FUAFStateTreeTraitContext（能力视图：PushAssetOntoBlendStack / QueryPlaybackInfo / GetVariablesOwner）；SetExternalGlobalParameters 把全局参数绑定重映射到 RigVM ExternalVariableRuntimeData 内存（按 PropertyBag 偏移区间，Add(Copy, MemoryPtr)）；SetCollectExternalDataCallback 按 FUAFStateTreeContext::StaticStruct() 给 trait 上下文视图 |
| 驱动 | OnBecomeRelevant → 装配上下文 → Start()；PreUpdate → Tick(TraitState.GetDeltaTime()) → IUpdate::PreUpdate 继续遍历；GC：AddReferencedObjects 收集 StateTree 指针 |
| **坑** | **不调 Stop**：FInstanceData::Destruct 的 Stop 逻辑整段注释，@TODO UE-240683——任务依赖 ExitState 清理需自行评估【AnimStateTreeTrait.cpp L33-72】 |
| 其他 | 非 debug 构建 Owner=GetTransientPackage()（仅 ENABLE_ANIM_DEBUG 用真实 host 对象） |

### 4.3 GameplayCameras（相机导演）

| 维度 | 内容【源码 GameplayCameras】 |
|---|---|
| 资产锚点 | UStateTreeCameraDirector : UCameraDirector（FStateTreeReference + meta Schema）→ OnBuildEvaluator 构建运行时 FStateTreeCameraDirectorEvaluator（Private 类，持 FStateTreeInstanceData + EvaluationData） |
| Schema | UCameraDirectorStateTreeSchema：ContextDataDescs 构造注入 FStateTreeContextDataNames::ContextOwner；IsStructAllowed 放行 FGameplayCamerasStateTreeTask / FGameplayCamerasStateTreeCondition（Hidden 域基类） |
| 输出模式 | **"输出暂存结构作为外部数据"**：FCameraDirectorStateTreeEvaluationData{ActiveCameraRigs, ActiveCameraRigProxies} 经 CollectExternalData 提供（FStructView::Make）——任务写入，宿主 OnRun 读出汇总 |
| 驱动 | OnActivate → Start（5.8 分支 `GetGlobalParameters()`，旧分支 `&GetParameters()`，版本宏切换，§8.2）；OnRun → Tick(Params.DeltaTime) → EvaluationData 的 Rig 逐个 OutResult.Add；OnDeactivate → Stop（相机求值生命周期驱动） |
| 任务族 | FGameplayCamerasActivateCameraRigTask / FGameplayCamerasActivateCameraRigViaProxyTask：持 `TStateTreeExternalDataHandle<FCameraDirectorStateTreeEvaluationData>`，bRunOnce 控制是否立即完成 |
| GC | OnAddReferencedObjects → StateTreeInstanceData.AddStructReferencedObjects |

### 4.4 Avalanche（虚拟制作转场，非实验）

| 维度 | 内容【源码 AvalancheTransition】 |
|---|---|
| 资产子类 | UAvaTransitionTree : UStateTree（DisplayName="Motion Design Transition Tree"）——**[5.8 变更]** 配置面正从资产迁往 IAvaTransitionBehavior（7 成员 UE_DEPRECATED(5.8)，§8.1）；二次开发直接走 Behavior 接口 |
| Schema | UAvaTransitionTreeSchema：IsStructAllowed 白名单 = FAvaTransitionTask / FAvaTransitionCondition / FStateTreePropertyFunctionCommonBase；IsClassAllowed = UAvaTransitionTaskBlueprint / UAvaTransitionConditionBlueprint；IsExternalItemAllowed = FAvaTransitionContext / UWorldSubsystem；AllowEnterConditions / AllowEvaluators / AllowMultipleTasks 全开 |
| 宿主 | FAvaTransitionBehaviorInstance：TWeakInterfacePtr\<IAvaTransitionBehavior\> + FStateTreeInstanceData + FAvaTransitionContext + RunStatus；接口 Setup/Start/Tick/Stop/ConditionallyStop；AddReferencedObjects 收集 InstanceData |
| 上下文 | 每次 Setup/Start/Tick/Stop 都 `TOptional<FAvaTransitionExecutionContext>` 重建（UpdateContext → ValidateTransitionScene → MakeContext）→ SetCollectExternalDataCallback（FAvaTransitionContext → FStructView；UWorldSubsystem → World）→ AreContextDataViewsValid() 收口 |
| ExecutionExtension | FAvaTransitionExecutionExtension 只重载 GetInstanceDescription（SceneDescription=TransitionType 显示名）——**唯一把 Extension 用作"纯描述定制"的宿主**；注意 Start 参数仍用旧 `StateTreeReference.GetParameters()`【BehaviorInstance.cpp L101】 |
| 驱动 | FAvaTransitionExecutor.Tick → InInstance.Tick(InDeltaSeconds)【AvaTransitionExecutor.cpp L279】；上游接 AvalancheMedia 播放链（AvaPlaybackManager / AvaPlayableGroup 的 TransitionToTick）与 FAvaTransitionSubsystem；自动停止 ConditionallyStop（Start/Tick 后 RunStatus 非 Running 即 Stop） |

## 5. 宿主公共 API 与上下文注入两路

### 5.1 宿主接入公共层（StateTreeModule，所有宿主必用）

| API 全名 | 语义一句话 |
|---|---|
| UStateTreeSchema（抽象基类） | 定义树的 ContextDataDescs、节点/外部数据白名单、编辑器约束 |
| FStateTreeExecutionContext(UObject& Owner, const UStateTree&, FStateTreeInstanceData&) | 完整执行上下文构造（每次 Start/Tick/Stop 前重建） |
| FStateTreeExecutionContext::Start(FStartParameters) | 启动树；FStartParameters 全部 6 成员：InitialGlobalParameters / ExecutionExtension / RandomSeed / SharedEventQueue / SelectStateOverrideArgs / GlobalParameters（弃用）。**[5.8 变更]** 5.8 实变 = InitialGlobalParameters 替代 GlobalParameters 字段（StateTreeExecutionContext.h L466-470，GlobalParameters UE_DEPRECATED(5.8)）+ 新增 Start(FConstStructView) 重载（§8.1） |
| FStateTreeExecutionContext::Tick(float) / GetLastTickStatus() | 驱动一次评估；查询运行状态 |
| FStateTreeExecutionContext::Stop(EStateTreeRunStatus) | 停止树 |
| FStateTreeMinimalExecutionContext::SendEvent(Tag, Payload, Origin) | 轻量上下文只发事件 |
| FStateTreeReadOnlyExecutionContext::GetStateTreeRunStatus() | 只读查询运行状态 |
| FStateTreeReference（GetStateTree / GetGlobalParameters / GetParameters / SetStateTree…） | 资产锚点句柄（参数覆盖与 LinkedStateTreeOverrides） |
| TStateTreeExternalDataHandle\<T\> + FStateTreeLinker::LinkExternalData | 节点声明外部数据依赖的习语 |
| FStateTreeInstanceData + AddStructReferencedObjects | 实例数据宿主与 GC |
| UStateTree::IsReadyToRun() | 启动前编译/Link 就绪检查 |

（事件队列语义 → events-async.md；执行上下文内部机制超出本集成面文档范围。）

### 5.2 上下文注入两路（→ AreContextDataViewsValid 收口）

| 路 | API | 语义 | 采用者 |
|---|---|---|---|
| 命名注入 | `FStateTreeExecutionContext::SetContextDataByName(FName, FStateTreeDataView)` | 按 Schema ContextDataDescs 的名字注入上下文对象 | GameplayInteractions（`UE::GameplayInteraction::Names::ContextActor / SmartObjectActor / SmartObjectClaimedHandle / SlotEntranceHandle / AbortContext` 五连，名字注释明示"与 StateTreeComponentSchema 命名一致"）；UAF（AnimStateTreeExecutionContextName）；GameplayCameras（ContextOwner）；UStateTreeComponent 走 virtual SetContextRequirements（→gameplay-state-tree.md） |
| 类型描述注入 | `FStateTreeExecutionContext::SetCollectExternalDataCallback(FOnCollectStateTreeExternalData)` | 按 FStateTreeExternalDataDesc 逐项解析（descs→FStateTreeDataView）：Mass 解析 Fragment 族→`FMassEntityView::Get*FragmentDataStruct`、UWorldSubsystem→`World->GetSubsystemBase`；Required 缺失→Error + bFoundAll=false | Mass（`CreateStatic(UE::MassBehavior::CollectExternalData)`）；Avalanche / GameplayCameras / UAF（lambda） |
| 全局参数外部映射 | `FStateTreeExecutionContext::SetExternalGlobalParameters(FExternalGlobalParameters*)` | 注入全局参数外部内存映射（按 PropertyBag 偏移区间 Add(Copy, MemoryPtr)） | 仅 UAF（RigVM 联动） |
| 收口校验 | `FStateTreeExecutionContext::AreContextDataViewsValid()` | 校验所有 Required 外部数据已就位；失败拒绝执行 | **所有官方宿主一致**（Mass 在 ForEachEntityInChunk 每实体 ensure 校验后才回调【MassStateTreeProcessors.cpp L46-73】） |

- Mass 不走命名注入：构造 `FMassStateTreeExecutionContext` 时即传 CollectExternalData 静态回调【MassStateTreeExecutionContext.cpp L122-126】。
- 调用纪律：**每次 Start/Tick/Stop 前重新装配**（重建式宿主每次 TOptional 重建；Mass 每实体每 Tick 构造）。

## 6. ExecutionExtension 四钩子

注入方式：`FStateTreeExecutionContext::Start(FStartParameters{…, ExecutionExtension = TInstancedStruct<FYourExtension>::Make(…)})`（范本 MassStateTreeExecutionContext.cpp L128-154、AvaTransitionExecutionContext.cpp L37-41）。

| 钩子（FStateTreeExecutionExtension 虚函数） | 语义 | 5.8 使用者 |
|---|---|---|
| GetInstanceDescription | 日志/Trace 实例描述 | Mass（FMassExecutionExtension，"Entity [...]"）；Avalanche（FAvaTransitionExecutionExtension，场景/转场描述——唯一"纯描述定制"用法） |
| ScheduleNextTick(FContextParameters, FNextTickArguments) [UE 5.7+] | "休眠-唤醒"按需调度（FNextTickArguments 含 UE::StateTree::ETickReason） | 组件宿主 FStateTreeComponentExecutionExtension（接 ScheduleTickFrame）；Mass 不用它（走信号） |
| OnLinkedStateTreeOverridesSet | 感知 Linked 树 overrides 变化 | Mass（FMassExecutionExtension，OverridesHash 变更检测；@todo 更新 mass dependencies 未实现）；5.7 在 Mass 实装 |
| OnBeginApplyTransition【推断，引入版本未证实】 | 转换应用前回调（埋点） | 5.8 头文件在册【StateTreeExecutionExtension.h L76-80】；Mass/Avalanche 均未重载 |

- 旧签名 `ScheduleNextTick(const FContextParameters&)` 5.7 起 final + 弃用——自定义 Extension 必须用新签名（§8.1）。

## 7. 自定义宿主接入：10 步清单与路线取舍

> 权威声明：本节是本技能"自定义宿主接入"的**权威版本**；`customization-guide.md` 只链接本节、不得复制（若发现重复，以本文档为准）。

9 个接入点去重后的公共骨架：**资产锚点 → Schema 白名单 → 实例数据宿主 → 上下文装配 → Start/Tick/Stop 驱动 →（可选）ExecutionExtension → 异步唤醒 → GC/调试收尾**。

### 7.1 十步接入清单（每步给官方范本路径）

**步骤 1：选资产锚点形态**（三选一）
- A. 宿主成员 `FStateTreeReference` + `meta=(Schema="/Script/<Module>.<YourSchema>")`（编辑器筛选资产）——范本：GameplayInteractions `GameplayInteractionSmartObjectBehaviorDefinition.h` L19-20、GameplayCameras `StateTreeCameraDirector.h` L34-36。
- B. 裸 `UStateTree*` + `meta=(RequiredAssetDataTags="Schema=...")`——范本：`MassStateTreeTrait.h` L25-26（Trait 场景）。
- C. `UStateTree` 资产子类——范本：`UAvaTransitionTree`；注意 Avalanche 正在从资产子类承载配置撤退（§8.1），新项目慎选此形态承载可变配置。

**步骤 2：定义域节点基类 + Schema 子类**
- 建 Hidden 域基类族：`F<域>StateTreeTaskBase : FStateTreeTaskBase`、`F<域>StateTreeConditionBase : FStateTreeConditionBase`（范本：`GameplayInteractionsTypes.h` L69-81、`CameraDirectorStateTreeSchema.h` L77-89、`MassStateTreeTypes.h` L45-108）。
- `U<域>Schema : UStateTreeSchema`：`IsStructAllowed` 只放行域基类 + StateTree CommonBase 族（范本：`MassStateTreeSchema.cpp` L20-31）；`IsExternalItemAllowed` / `IsClassAllowed` 决定外部数据白名单（范本：Mass L33-40、Avalanche `AvaTransitionTreeSchema.cpp` L28-31）；命名注入则覆写 `GetContextDataDescs()`（范本：GameplayInteractions / GameplayCameras Schema）。
- 编辑器约束按需：`AllowQueuedCompilation()=false`（避免 worker 线程编译；Mass/UAF 均如此——注意与 5.7 引入的 `UE::StateTree::Compiler::FCompilerManager` 队列机制相斥，要禁就同步关掉队列编译假设）。

**步骤 3：准备实例数据宿主**
- 成员 `FStateTreeInstanceData`：UPROPERTY 挂载（范本 `GameplayInteractionContext.h` L97-98）或非反射宿主 + GC 钩子 `AddStructReferencedObjects`（范本 `StateTreeCameraDirector.cpp` L212-215、`AvaTransitionBehaviorInstance.cpp` L154-157）。
- 批量实例池化：仿 `UMassStateTreeSubsystem`——数组 + Freelist + Generation 句柄 + 事务安全访问探测（范本 `MassStateTreeSubsystem.h` L28-99）。

**步骤 4：上下文装配（每次 Start/Tick/Stop 调用前都要做）**
- 构造 `FStateTreeExecutionContext(*Owner, *StateTree, InstanceData)`（或派生上下文）→ `IsValid()` 检查。
- 命名注入 / 类型注入 / 可选 `SetExternalGlobalParameters`（两路细节见 §5.2）。
- 收口：`AreContextDataViewsValid()`，失败拒绝执行（所有官方宿主一致）。

**步骤 5：Start**
- 无扩展：`FStateTreeExecutionContext::Start(StateTreeRef.GetGlobalParameters())`（**[5.8 变更]** 推荐形态，范本 `StateTreeCameraDirector.cpp` L99）。
- 有扩展：组 `FStartParameters{ .InitialGlobalParameters = …, .ExecutionExtension = TInstancedStruct<FYourExtension>::Make(…), .RandomSeed = … }`（范本 `MassStateTreeExecutionContext.cpp` L128-154、`AvaTransitionExecutionContext.cpp` L37-41）。

**步骤 6：Tick 与"非 Running 状态策略"**
- `FStateTreeExecutionContext::Tick(DeltaTime)` → 按 `EStateTreeRunStatus` 决定宿主行为。三种官方策略：
  - 自动停：`ConditionallyStop`（Avalanche）；
  - 照常返回等下一次外部驱动（GameplayCameras——每帧相机求值自然重入）；
  - 立即 `Tick(0)` 重试一次 + 仍失败发唤醒信号下轮再试（Mass，`MassStateTreeProcessors.cpp` L356-370）。

**步骤 7：Stop 与重入防护**
- Stop 前同样装配上下文（Stop 也需要外部数据：范本 `StateTreeCameraDirector.cpp` L128-133、`AvaTransitionBehaviorInstance.cpp` L131-142）。
- 重入哨兵：成员 `FStateTreeExecutionContext* CurrentlyRunningExecContext` + `TGuardValue`（范本 `GameplayInteractionContext.h` L121 + .cpp L55/122/162）。**UAF 缺失 Stop 是反面教材**（§9-1）。

**步骤 8（可选）：ExecutionExtension**
- 四钩子取舍见 §6：`GetInstanceDescription`（日志/Trace 描述）；`ScheduleNextTick`（需要"休眠-唤醒"调度的宿主必接；Mass 不用、走信号）；`OnLinkedStateTreeOverridesSet`（感知 Linked 树 overrides 变化）；`OnBeginApplyTransition`（转换前埋点）。

**步骤 9：异步唤醒与事件**
- 发事件：构造 `FStateTreeMinimalExecutionContext` → `SendEvent`（范本 `GameplayInteractionContext.cpp` L185-200）；事件队列语义与上限 → events-async.md。
- 延迟转换唤醒：宿主必须提供"到点再 Tick"机制——Mass=信号延迟重投递（`BeginDelayedTransition` 覆写）；组件=ScheduledTick；每帧驱动的宿主（Camera/UAF）天然覆盖。

**步骤 10：校验、GC 与调试收尾**
- 运行时 Schema 校验（可选）：`ValidateSchema`（GameplayInteractions 校验 Actor 类匹配，范本 `GameplayInteractionContext.cpp` L202-240）。
- GC：见步骤 3。
- Trace：`SetOuterTraceId`（Mass L59、UAF L100/229）；实例描述给 `GetInstanceDescription`。
- 编辑期校验（Trait/模板场景）：仿 `UMassStateTreeTrait::ValidateTemplate` 检查 Required 外部数据可满足。

### 7.2 三条已验证宿主路线（带取舍）

1. **组件式**（Actor 常驻树）：组件生命周期托管 + 按需调度；适合 NPC/Actor 行为。成本：处理 Pause/Resume/重入。细节→gameplay-state-tree.md。
2. **每次调用重建式**（GameplayInteractions/Avalanche/GameplayCameras）：生命周期离散（交互开始/结束、转场开始/结束、激活/停用），每次调用重建 `FStateTreeExecutionContext`（TOptional 或局部变量）。成本：每 tick 构造开销（官方接受；Mass 另有 CSV 计时关注此项）；收益：实例数据与生命周期强绑定、无悬挂。
3. **遍历驱动式**（UAF）：嵌入既有求值管线（动画图 update traversal），宿主自身无 Tick 概念。成本：Stop 时机难（官方至今未解决，UE-240683）；GC 需 trait 接口配合。

### 7.3 节点级扩展（挂现有宿主，最快路径）

- 挂 Mass 宿主：继承 `FMassStateTreeTaskBase` 等 → `LinkExternalData` 声明 fragment/subsystem → 需要 shaping 处理图则覆写 `GetDependencies` → 完成用 `DelaySignalEntityDeferred` 发约定信号。范本：`MassCrowdClaimWaitSlotTask.h` L37-56（两级习语齐备）。
- 挂相机宿主：继承 `FGameplayCamerasStateTreeTask`，持 `TStateTreeExternalDataHandle<FCameraDirectorStateTreeEvaluationData>` 写输出。范本：`StateTreeCameraDirectorTasks.h`。
- 挂转场宿主：继承 `FAvaTransitionTask` / `FAvaTransitionCondition`，读 `FAvaTransitionContext`。
- 挂交互宿主：继承 `FGameplayInteractionStateTreeTask`，经 `UE::GameplayInteraction::Names` 取上下文。
- 挂动画宿主（实验）：继承 `UStateTreeAnimNextSchema` 放行的节点族，经 `AnimStateTreeExecutionContextName` 取 `FUAFStateTreeContext`。

## 8. 弃用与版本敏感 API

### 8.1 弃用 API 单列表

| 弃用 API | 弃用版本 | 替代品 |
|---|---|---|
| UAvaTransitionTree::GetTransitionLayer / SetTransitionLayer / IsEnabled / SetEnabled / SetInstancingMode / GetInstancingMode / GetEnabledPropertyName + 3 个 UPROPERTY【源码 AvaTransitionTree.h L24-67，7 处 UE_DEPRECATED(5.8)】 | 5.8 | IAvaTransitionBehavior 同名成员 |
| FStateTreeExecutionContext::Start(const FInstancedPropertyBag*, int32 RandomSeed=-1) 等旧 Start 重载【源码 StateTreeExecutionContext.h L477-493，总览调研转引】 | 5.8 | Start(FStartParameters)（.InitialGlobalParameters / .ExecutionExtension / .RandomSeed）**[5.8 变更]**：5.8 实变 = InitialGlobalParameters 替代 GlobalParameters 字段（StateTreeExecutionContext.h L466-470，GlobalParameters UE_DEPRECATED(5.8)）+ 新增 Start(FConstStructView) 重载 |
| FStateTreeExecutionExtension::ScheduleNextTick(const FContextParameters&)（final）【源码 StateTreeExecutionExtension.h L67-68】 | 5.7 | ScheduleNextTick(const FContextParameters&, const FNextTickArguments&) [UE 5.7+] |
| FMassStateTreeExecutionContext 旧构造（带 EntityManager + SignalSubsystem 参数）【源码 MassStateTreeExecutionContext.h L41-50】 | 5.6 | 不要求 EntityManager / SignalSubsystem 的新构造 |
| `MassStateTreeFragments.h` include（自 Processors 头降级为 deprecated-include）【MassStateTreeProcessors.h L6-8】 | 5.6 | 直接 include 各 Fragment 头；MassStateTreeExecutionContext / Processors / Subsystem 头内 `UE_ENABLE_INCLUDE_ORDER_DEPRECATED_IN_5_6` 迁移块：老代码直接 include `MassEntityTypes.h` / `MassLODTypes.h` 需调整 |

（Mass/UAF 层无其他 UE_DEPRECATED 标记命中本模块接口层。）

### 8.2 版本敏感但未弃用

- **GetParameters()/GetGlobalParameters() 并存无弃用**：`FStateTreeReference::GetParameters()`（FInstancedPropertyBag*）与 `FStateTreeReference::GetGlobalParameters()`（FConstStructView）并存、均无弃用标记【StateTreeReference.h L47/L61】；**[5.8 变更]** 5.8 起 Start 推荐 FConstStructView 形态进 `FStartParameters.InitialGlobalParameters`。
- **跨版本编译兼容范式**：照抄 GameplayCameras 的版本宏分支 `#if UE_VERSION_NEWER_THAN_OR_EQUAL(5,8,0)`（`Start(GetGlobalParameters())` vs 旧 `Start(&GetParameters())`）【StateTreeCameraDirector.cpp L98-102】；Mass/Avalanche 新代码同走 GetValue() 形态。
- **OnBeginApplyTransition**：引入版本【未证实】（5.8 头文件在册，总览调研 5.7 波未列；无本地 5.7 源码比对，§10）。

## 9. 关键坑速查

1. **UAF 宿主不调 Stop**：`FStateTreeTrait::FInstanceData::Destruct` 的 Stop 逻辑整段注释，@TODO **UE-240683**——动画域无干净停止路径，任务依赖 ExitState 清理需自行评估【AnimStateTreeTrait.cpp L33-72】。
2. **GetParameters()/GetGlobalParameters() 并存无弃用**：5.8 Start 推荐 FConstStructView 形态；跨版本编译照抄 GameplayCameras 版本宏分支（§8.2）。
3. **Mass 客户端不跑**：`UE::MassStateTree::ExecutionFlags = Standalone\|Server`（§3.7）。
4. **两级依赖别混淆**：`LinkExternalData`（运行期数据句柄）≠ `GetDependencies`（处理图调度声明）（§3.5）。
5. **Mass ConstSharedFragment 的 const_cast**：CollectExternalData 对 FMassConstSharedFragment 取内存后 const_cast 塞 FStateTreeDataView【MassStateTreeExecutionContext.cpp L83】——写"只读共享 fragment"不被类型系统拦截，靠 processor query（AddConstSharedRequirement）约束。
6. **重入直接报错**：FGameplayInteractionContext Activate/Tick 重入返回 false 并记 Error（非优雅排队）【GameplayInteractionContext.cpp L48-52、L115-119】。
7. **每帧重建上下文的成本**：GameplayInteractions/Avalanche/GameplayCameras/Mass 全部每次 Start/Tick/Stop 前重建；Mass 用 CSV（MassStateTreeProcessor 分类）盯 ExternalDataValidation/Execute【MassStateTreeProcessors.cpp L26、L63、L317-318】。
8. **Unicode 标识符**：UMassStateTreeSubsystem 成员/局部变量名是 `ĘntityManager`（E-ogonek）【MassStateTreeSubsystem.h L104 等】——文本搜索、脚本重构容易漏。
9. **激活限流**：MaxActivationsPerLOD 延迟新实体 Start（§3.7）。
10. **实例池句柄失效**：Generation++ 防悬挂；Tick 路径拿 nullptr 静默跳过（§3.7）。
11. **幽灵模块**：MassGameplayDebug / StateTreeToolset——引用面调研先验证实际代码使用，勿按依赖表臆断集成深度（§1.3）。
12. **GameplayInteractions 无 Mass 桥**（本构建）：不要照搬"Mass 驱动交互"旧教程（§1.3）。
13. **Schema 禁队列编译与 FCompilerManager 相斥**：Mass/UAF `AllowQueuedCompilation()=false`——自定义域要禁就同步关掉队列编译假设（§7.1 步骤 2）。
14. **事件队列 64 上限**：高频 SendEvent 宿主注意 `FStateTreeEventQueue::MaxActiveEvents=64` 溢出语义（→ events-async.md）。
15. **动态 processor 类替换崩溃**：`NewObject` 失败 `checkf` 崩溃；`DynamicStateTreeProcessorClass` 标 NoClear（§3.4）。

## 10. 开放问题

- 【未证实】`FStateTreeExecutionExtension::OnBeginApplyTransition` 的引入版本（推断 5.8 新增；本地无 5.7 源码比对）。
- 【未证实】Mass 集成并入 MassAIBehavior（`MassStateTree*.h` 命名残留）的确切版本。
- 【未证实】GameplayInteractions 的 Mass 驱动路径在 5.8 Release 缺失的原因（从未随源码发布 / 移至其他插件 / 移除，三说均无本地证据）。
- 【未证实】`ai.mass.DynamicSTProcessorsEnabled=false` 时 StateTree 实体 Tick 驱动的回退路径（代码显示不生成动态 processor，静态回退未见）。
- 【未证实】UAF AnimNode 路径（FUAFStateTreeNode）的 Start 驱动细节（`UAFStateTreeNode.cpp` 未读；推断与 Trait 路径同为 PreUpdate 驱动）。
- 【未证实】`UMassDebugStateTreeProcessor` 的确切用途与触发条件（仅读头文件，未读 cpp 实现与注册逻辑）。
- 【未证实】Avalanche 播放链上游（AvaPlaybackManager → TransitionToTick → Executor → BehaviorInstance）完整调用链时序（仅确认 Executor L279 一跳）。
- 【推断】`bProcessEntitiesInParallel=true`（config，默认 false）时 SignalEntities 并行 Chunk 处理与 UMassStateTreeSubsystem 读锁、FStateTreeInstanceData 线程安全的组合正确性（依赖 UE_MT 访问探测器兜底，无显式文档）。
- 【推断】Mass "GetDependencies 未覆写时 fragment 不进 processor 调度声明" 的完整影响面（FMassNavMeshPathFollowTask 反例 + Schema 佐证，未逐任务核对）。
