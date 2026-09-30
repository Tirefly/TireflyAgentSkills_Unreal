---
name: unreal-development-workflow
description: Unreal 项目开发的执行哲学与验证纪律（Tirefly 用户规范）。任何 Unreal 玩法/系统/插件/编辑器工具/UnrealSharp 开发任务开始时使用：默认禁止 TDD，直接实现加编译/构建验证，编辑器自动化不可用时标注人工验证点，不因流程需求发明自动化测试。
---

# Unreal 开发工作流（Tirefly 规范）

## 验证哲学（默认纪律）

- Unreal 项目开发默认禁止 TDD：不使用 `test-driven-development` 技能、红绿重构循环、测试先行实现或 TDD 式规划；仅当用户明确请求该特定任务的测试时才添加。
- 不要仅为满足通用 agent 工作流或 Superpowers 技能而添加自动化测试。
- 规划 Unreal 工作、OpenSpec 任务或验证流程时，默认不设计自动化测试任务/流程步骤；用户明确提到自动化测试时才添加。
- 复杂实时玩法：优先直接实现 + 编译/构建验证。
- 编辑器自动化不可用时：明确标注人工验证点，不强行测试先行循环。
- 自动化测试仅在用户明确要求、或既有项目已要求对进行中变更做特定测试更新时添加。

## 与其他 Unreal 技能的分工

- C++ 编译（引擎检测/UBT 路径/项目刷新/编译/失败排查）：`unreal-cpp-compile`。
- C++ 风格（创建/修改/审查/格式化前）：`unreal-cpp-style`。
- GameplayTag（域划分/层级/命名/声明位置/改名重定向/引擎机制事实）：`unreal-gameplay-tags`。
- UnrealSharp（C# 预检流程/诊断链路）：`unrealsharp-agent-skill`。

## 引擎机制事实（编译失败高发点速查）

本节承载引擎行为的地面真相——与文档措辞冲突时以实测为准（2026-09-10 TCS R3 Task 0 编译实证）：

- **API 导出宏按模块名派生，与插件名无关**：宏 = 大写模块名 + `_API`（模块 TcsCore → `TCSCORE_API`；引擎实证：AudioGameplay 模块 → `AUDIOGAMEPLAY_API`）。设计/计划文档写"插件名_API"时，以实际编译模块名为准。
- **导出宏只给"有 out-of-line 成员或反射符号"的类型，全内联值类型不加**（2026-09-16 TCS Task 4 链接实证）：宏会让消费方去别的 DLL **导入**符号，而 MSVC 只为"本模块自己用到的类型"生成导出符号——本模块从未实例化的类型（无 out-of-line 成员、无 UHT 生成物）在消费方以 LNK2019 炸开（实测：`FTcsSourceHandle` 的隐式默认构造、`XxxRegistry::Allocate()` 这类全内联成员）。判据：该类型有没有定义在本模块 `.cpp` 里的成员、或 UHT 生成的 `Z_Construct_*`/`StaticStruct`（反射 USTRUCT / UINTERFACE / UCLASS 有，纯 C++ 账本值类型没有）。**根治方式是去掉宏**（消费方各自在头内实例化，ODR 安全），不是"在本模块补一处强制实例化"。
- **UHT 把枚举值上方的 `//` 行注释转成 ToolTip 元数据**：与 UMETA 显式 `ToolTip` 同用时 UHT 报 `Metadata key 'ToolTip' first seen ... then ...`——枚举值描述只写 UMETA，值上方不再放行注释。
- **`UDeveloperSettings` 住独立的 `DeveloperSettings` 模块**：头文件路径仍是 `Engine/DeveloperSettings.h`（易误判为 Engine 模块）；Build.cs 缺 `"DeveloperSettings"` 依赖会在链接期报 LNK2019（`__declspec(dllimport)` 符号未解析）。
- **USTRUCT 抽象手法 = 中性默认实现 + `meta=(Hidden)`（禁 `=0` 与 `PURE_VIRTUAL`）**：UHT 为每个 USTRUCT 无条件生成 `TCppStructOps<T>`（构造路径 `new T` 需可默认构造），纯虚基类报 C2259 无法实例化抽象类；而 **`PURE_VIRTUAL` 在 `CHECK_PUREVIRTUALS` 开启时展开为 `=0`、关闭时才是致命错误体（`CoreMiscDefines.h:100-102`）**——同一份代码在 Development 编不过、Shipping 能过（最坏的一类失败）。故策略/条件类基 struct 一律：**默认实现返回中性值 + `meta=(Hidden)`**（picker 按 Hidden 过滤，基类不可选；先例 = 本仓 `FTcsParamValueSource`、TcsTargeting 两份契约、TcsDamage 流程步骤基类）。计划 sketch 写"PURE_VIRTUAL 纯虚"时**不要照抄**。
- **`SetTimerForNextTick` 的"下一 tick" ≠ "下一帧"**：它设 `ExpireTime = InternalTime`，而 `FTimerManager::Tick` 以**严格大于**判到期（`InternalTime > ExpireTime`）——故游戏逻辑期间设置的 next-tick 定时器会在**本帧**的 TimerManager tick 触发（该 tick 位于 `UWorld::Tick` 尾部 `TickObjects` 之前）。想做"帧末之后"的校验必须**逐 tick 轮询观察**（或跨帧多次采样），不能单次延迟假定下一帧（2026-09-11 TCS Task 2 检查点实测踩坑）。
- **Tickable 自 tick 到不了 PrePhysics（泵类设施必须挂帧首委托）**：`FTickableGameObject::TickObjects` 位于 `UWorld::Tick` 尾部（LevelTick.cpp，晚于全部 tick 组与 TimerManager）；帧首挂点是 `FWorldDelegates::OnWorldTickStart`（`UWorld::Tick` 开头无条件广播 `(UWorld*, ELevelTick, float)`，每帧每世界一次，进程级静态委托需自行按 World 过滤）。停用 tickable 子系统自 tick 的正确机制是**重写 `GetTickableTickType()` 返回 `ETickableTickType::Never`**——`UTickableWorldSubsystem::Initialize` 会用该返回值调 `SetTickableTickType`（构造期设置会被重注册覆盖）。
- **ensure 每站点每进程只上报一次（"首次运行才报错/断点"的真因）**：每个 ensure 站点持 `static std::atomic<uint8> bExecuted`，触发时 `exchange(GEnsureResetState)`——值已等于 `GEnsureResetState`（初值 1）时静默返回，既不写日志也不断点。故编辑器会话内**第一次**跑到某 ensure 站点才有完整输出（Error 级约 11 行：ensure 消息 + 4 行 callstack + `EnsureFailed` 重复块），之后重跑同一路径完全静默。相关 CVar：`core.ResetEnsureState`（递增重置状态 → 所有 ensure 站点重新可报，用于复现首次现象）、`core.EnsureBreakEnabled`（默认 true = 附加调试器时断点捕获——即"断点式卡顿"来源）、`core.EnsuresAreErrors`（Error/Warning 级）。**实践结论**：测试装置里"故意触发 ensure"的检查必须**独立成 opt-in 命令**，不混入常规检查命令——否则每次开编辑器首次运行必现红字刷屏 + 断点卡顿（2026-09-16 TCS Task 3 用户实测反馈）。
- **上一条的泛化（2026-09-21 TCS Task 5 用户实测指出，同一错误复犯）：任何"故意触发失败输出"的检查都必须独立成 opt-in 命令，不止 ensure**——包括**故意触发的 Error/Warning 日志**（如"未登记 id → Error 拒绝"这类拒绝面检查）。判据很简单：**常规验收命令的输出应当是"零红字"**，跑完只看 PASS/FAIL 行；任何以"某条 Error 是预期的"为注解的输出都说明该检查放错了命令。反模式（本次实证）：把"未登记链 → 拒绝"的检查放进主命令，用户每次跑验收都看到 `Error: ... 未登记——拒绝起链`，既像真实缺陷、又让"零红字"这一验收信号失效——**用户会来问"这个红字是什么"，而正确做法是它根本不该出现在常规命令里**。命名约定：主命令 `Tcs.Test.<域>`（零红字）/ 拒绝面 `Tcs.Test.<域>.Reject`（自带屏显声明"红字为预期"）。
- **原生 GameplayTag 的三条事实（层级按 `.` 切分且父节点非"显式 tag"、常量名与 tag 文本解耦、两段式注册）已迁出本技能 → `unreal-gameplay-tags`（2026-10-01 迁移；原文为 2026-09-21 源码核实）**。tag 的域划分、命名、声明位置、改名重定向与全部引擎机制事实见该技能的 `references/engine-facts.md` 与 `references/authoring.md`；本节不再保留副本（避免双份载体）。
- **`UE_DECLARE_GAMEPLAY_TAG_EXTERN` 展开为裸 `extern`（无 dllexport）——跨模块引用原生 Tag 变量会 LNK2001**（2026-09-21 TCS Task 6 实测）：引擎宏本体是 `#define UE_DECLARE_GAMEPLAY_TAG_EXTERN(TagName) extern FNativeGameplayTag TagName;`（`NativeGameplayTags.h:31`），**不带 `__declspec(dllexport)`**。故凡"设计意图是供其他模块/宿主使用"的框架 Tag，声明处 MUST 显式加模块导出宏：`extern TCS<模块>_API FNativeGameplayTag Tag_X;`（定义处零改动——定义 TU 见到 dllexport 声明即导出符号，前提是该 TU include 了声明头）。**同一原理适用于任何"公共调用面"的非内联符号**（本次另一例：`FTcsFlowAttributes` 的 `Submit`/`Read` → LNK2019）。判据：该符号**是否被跨模块引用**，不是"现在有没有人用"——设计意图供外部用的，写时就带宏。**tag 专属的声明写法**（手写 `extern <模块>_API FNativeGameplayTag` 的具体形态、常量名逐段对应规则）见 `unreal-gameplay-tags`。
- **unity build 把同模块多个 `.cpp` 合并为一个翻译单元——匿名命名空间的通用符号名会跨文件相撞**（2026-09-18 TCS plan1 Task 6 首编译实证）：同一模块内多个 `.cpp` 各自定义同名 file-local 辅助函数（`MakeLiteralModifier` / `IsClose` 这类）时，UBT 的 unity 合并会把它们放进同一 TU、`namespace {}` 随之合并 → `error C2084: 函数"`anonymous-namespace'::Xxx"已有主体`，并级联 `C2264/C2660`。**症状误导性极强**：报错位置落在**先定义该符号的那个文件**（往往是本次没改的旧文件），照报错方向查会一路查错。实践结论：①同模块内跨 `.cpp` 的 file-local 符号一律带**文件/装置前缀**（`MakeAcceptanceLiteralModifier` 而非 `MakeLiteralModifier`），哪怕当前只有一处定义；②看到 C2084/C2264"已有主体 / 函数定义或声明中有错误"落在"自己这次没改的文件"里，**第一反应应是 unity 合并撞名**，而非该文件本身坏了；③`Private/Testing/` 这类多装置同居一目录的场景最易踩（多个装置各自的便捷件重名）。

**以下为 2026-09-16 从 TAH 卡（MEM-20260821-02 / MEM-20260822-02）迁入的反射与布局事实**（原卡保留环境/流程部分；枚举 `//` 注释与 UMETA ToolTip 冲突一条本已在册，未重复）：

- **UHT 容器限制：`TMap<Key, TArray<Value>>` 不能作 `UPROPERTY`**（嵌套容器作属性值受限）——需包一层 USTRUCT 或改扁平容器。
- **`BlueprintNativeEvent` 规则**：函数**不带 `const`**；UHT 自动生成 `Execute_*`，须在头文件显式声明 `_Implementation`、默认实现留 `.cpp`（UINTERFACE 同规则，缺默认体会在链接期炸）。
- **`uint32` 不能作 `BlueprintReadOnly` 的 `UPROPERTY`**——蓝图暴露的整型用 `int32`（或 `int64`）。
- **`TMap`/`TSet` 元素地址不稳定——扩容即搬移（2026-09-17 TCS Task 4 PIE 实测暴露）**：`TSet`（`TMap` 的底层）元素存在 `TArray<FElementOrFreeListLink<...>>` **连续缓冲**里（`SparseArray.h:499` 的 `DataType Data;`），插入导致扩容时整块搬移——**按值存在 map 里的对象，其地址在后续插入后失效**。实践结论：①"缓存容器/元素指针"类设计必须**经间接层**（`TMap<K, TUniquePtr<V>>`）或改用指针稳定容器，否则缓存指针会悬空（实测症状：装置里缓存 `FTcsAttributeInstance*` 后再插入 32 条，指针不再相等）；②跨插入只保证**按名/按键查回数据未损**，不要写"元素地址稳定"这类论断；③"热路径不重复查找"要靠**对象自持数据**而非缓存指针。
- **`UObject::IsDataValid` 基类默认返回 `NotValidated` 而非 `Valid`（同轮实证，`Obj.cpp:6096`）**：因此 `Super::IsDataValid(Context)` 起步、无错无警的资产返回的是 `NotValidated`——装置若断言 `== Valid` 必然 FAIL，编辑器也会把"已校验通过"显示为"未验证"。实践结论：资产确有校验规则时，在 `IsDataValid` 末尾把 `NotValidated` **提升为 `Valid`**（有错再置 `Invalid`）；警告降级分支判 `Result == Valid` 才成立。
- **编辑器开着时命令行 UBT 编译被 Live Coding 阻断**：报 `Unable to build while Live Coding is active. Exit the editor and game, or press Ctrl+Alt+F11...`——不是代码问题。要么请用户关编辑器再编，要么请其在编辑器内 `Ctrl+Alt+F11` 走 Live Coding（顺带即时生效）。
- **`DECLARE_LOG_CATEGORY_EXTERN` 不带 API 宏不能跨模块链接**——跨模块日志须用独立静态类别或加导出宏（TCS 的 `Public/<模块名>LogChannel.h` + `Private/<模块名>LogChannel.cpp` 配对正是此规避的产物）。
- **用户声明的移动构造会抑制隐式默认构造**（含 `= default` 外联）：含 `TUniquePtr` 成员的类补了移动构造，就必须显式补默认构造。该缺陷**编译不报、首次真实例化才炸**——**编译门只覆盖被实例化的代码**，纯头类的潜伏缺陷靠真实体化（值成员/用例）捕获。
- **模板成员调用不完整类型需先 include 完整定义**（如 `ItemDef->FindFragment<T>()`），否则 `<` 被误解析为小于号。
- **`ENABLE_DRAW_DEBUG` 经 `DrawDebugHelpers.h` 映射为 `UE_ENABLE_DEBUG_DRAWING`**（Development=1 / Shipping=0）；**勿在 Build.cs 强加定义**（触发 C4005 重定义警告）。
- **细节面板可编辑性与 `USTRUCT(BlueprintType)` 无关（2026-09-20 源码核实）**：属性显示/可改由 `PropertyEditorHelpers::ShouldBeVisible` 判定（`PropertyEditorHelpers.cpp:407`）——只看成员自己的 `CPF_Edit`（`EditAnywhere` 等）+ 排除 `InlineEditConditionToggle` 与 `DisableEditOnInstance`；结构类型选择器 `FInstancedStructFilter::IsStructAllowed`（`SInstancedStructPicker.cpp:64`）的过滤条件是 Allowed/Disallowed 元数据、`UUserDefinedStruct`、**`Hidden` 元数据**、BaseStruct 子类、资产引用过滤——两条路径都不读 BlueprintType。**`BlueprintType` 由 UHT 写成结构体元数据（`UhtDefaultSpecifiers.cs:98`），只被蓝图图形 schema 读**（`EdGraphSchema_K2.cpp:1231` 注释原文 "struct needs to be marked as BP type"）：决定能否当蓝图变量/引脚类型、能否提升为变量、Make/Break Struct 节点可用性。真正的两个坑：①成员自己没 `Edit*` → 面板里看不到（"配不了"的常见真因）；②把非 BlueprintType 结构体挂到 `BlueprintReadOnly/BlueprintReadWrite` 属性上 → **UHT 报错** `Type 'X' is not supported by blueprint`（`UhtClass.cs:2203-2210`，UhtScriptStruct/UhtFunction 同款）——是编不过，不是配不了。
- **`TInstancedStruct<T>` 的 `BaseStruct` 元数据由 UHT 自动写入**（`UhtStructProperty.cs:634-635`）：属性上再显式写 `meta=(BaseStruct=...)` 会**报错**（"implicitly set from the TInstancedStruct template argument and should not be explicitly specified"）——策略基类写成 `TInstancedStruct<FTcsXxxStrategyBase>` 即得"只列子类"的选择器（是否列出基类自身由 `bExcludeBaseStruct` 控制）。无公共基类的 `TArray<FInstancedStruct>` 会列出全部反射结构体（选择器自带搜索框可按名过滤）；要收窄可用属性元数据 `AllowedClasses` / `GetAllowedClasses`（`SInstancedStructPicker.cpp:321/361`），代价是新增类型要同步维护白名单。
- **`FInstancedStruct::GetPtr<T>()` 会类型校验，但「双模板参数重载」在 Shipping 下不校验**（2026-09-30 TCS 源码核实）：单参数版走 `UE::StructUtils::GetStructPtr<T>`（`StructUtils.h:52-62`）——`StructMemory == nullptr`（空载荷）**或** `ScriptStruct` 既非 `T` 亦非其子类时**返回 `nullptr`** ⇒ 一个 `if (!Ptr)` 判据即可同时覆盖"载荷缺失"与"类型不符"两种降级（引擎注释自述 "or nullptr if cast is not valid"）。**⚠️ 双模板参数重载 `GetPtr<T, BaseStructT>(…)`（`StructUtils.h:66-89`）是陷阱**：`WITH_EDITOR || !UE_BUILD_SHIPPING` 下走 `ensureAlwaysMsgf` 校验并回落 `nullptr`，但 **Shipping 走 `#else` 直接 `return ((T*)StructMemory);`——完全不校验**（源码注释自认 "this may crash in shipping!"）⇒ **同一份代码编辑器里安全、Shipping 里类型混淆，编译查不出来**。**纪律**：取 `FInstancedStruct` 内层一律用单参数 `GetPtr<T>()` / `GetMutablePtr<T>()`（双参数形式本仓与 LAC 全库零使用）。另注 `Get<T>()` 系（`GetStructRef`，`:36-48`）类型不符时是**报错后仍返回引用**（无 `nullptr` 语义）——热路径的降级判据不要用它。

- **复制安全速查（2026-09-20 源码核验，详见 `Documents/combat-system-design/2026-09-20-replication-posture-research.md`）**：①`FInstancedStruct` **有原生复制**（StructUtils `NetSerialize`；经典路径用内层 struct 的 `FRepLayout`，Iris 有 `FInstancedStructNetSerializer`）——但**内层 struct 是否可复制 UHT 查不了**，需自带校验器；②**`TFunction` 做 `UPROPERTY` 是 UHT 编译错误**（`UhtSession.cs:2645`）→ 回调绝不可留在要过网的结构里（非 UPROPERTY 则可留但永不过网）；③**`TMap`/`TSet` 结构上不可复制**（UHT 报错；运行期只打 Error 不写数据），`TMap<K,TArray<V>>` 连 UPROPERTY 声明都非法；④通道：追加型结果流 → `FFastArraySerializer`、低频事件 → RPC（不可靠 Multicast 每次 net update 限 2 条、可靠溢出断连）、复制属性 = 状态语义；⑤PushModel 默认关（仅 Editor target 默认开），**Iris 下经典 PushModel 句柄被禁用**；5.8 默认仍走经典复制（`net.Iris.UseIrisReplication=0`），ReplicationGraph 与 Iris 互斥。

- **全项目头文件名必须唯一——UHT 硬门槛，与模块无关（2026-09-21 TCS Task 5 编译实证）**：两个不同模块各有一个 `TcsEntityQuery.h`（TcsEffect 的契约头 + TcsIntegration 的实现头）时，UHT 直接报
  `Two headers with the same name is not allowed. 'A\Entity\TcsEntityQuery.h' conflicts with 'B\Host\TcsEntityQuery.h'`，**编译在 UHT 阶段即失败**（不是 include 路径歧义、不是链接问题——是 UHT 的全局头名注册表去重）。实践结论：跨模块"契约头 vs 实现头"的命名方案必须**文件名也不同**（本仓定为契约 `TcsEntityQuery.h` / 实现 `TcsPieEntityQuery.h`），不能靠"同名不同目录"规避。同理适用于 UCLASS 类名（`UTcsEntityQuery` 被 UINTERFACE 的 U 类占用 → 实现类必须改名）。

- **`UPrimaryDataAsset` 子类持"非 BlueprintType 结构体"字段时不能加 `BlueprintReadOnly`**（2026-09-21 TCS Task 5 编译实证）：`UCLASS(BlueprintType)` 上的 `BlueprintReadOnly` 属性要求其类型可蓝图化，UHT 报
  `Type 'FTcsEffectChain' is not supported by blueprint. Class: UTcsEffectChainDef Property: Chain`（`UhtClass.cs:2203-2210` 同款）。**修法是去掉该属性的 `BlueprintReadOnly`，保留 `EditAnywhere`**——细节面板可编辑性只看 `CPF_Edit`，与 BlueprintType 无关（见上一条 2026-09-20 核实），故策划侧零损失；给下游结构补 `BlueprintType` 反而是更重的改动（会影响该结构全部消费方）。

- **运行时注册组件会触发 `BeginPlay`——前提是"所属 Actor 已开始 BeginPlay"（2026-09-21 源码核实）**：`UActorComponent::RegisterComponentWithWorld` 在"游戏世界 + 有 Owner"分支转 `AActor::HandleRegisterComponentWithWorld`（`ActorComponent.cpp:2052`），后者判 `HasActorBegunPlay() || IsActorBeginningPlay()`（`Actor.cpp:6429`）为真才调 `Component->BeginPlay()`（`:6449`）。故装置/宿主在 PIE 运行期 `NewObject` + `AddInstanceComponent` + `RegisterComponent` 的组件**会正常走注册路径**（可用来做装置夹具）；但若在 Actor 尚未 BeginPlay 前注册，则 BeginPlay 推迟到 Actor 自己的时机——装置里"注册后立刻断言句柄有效"的写法只在世界已开跑时成立。

## 个人 Harness 纪律（本技能是 Unreal 任务的必经加载位，故在此复述）

条款本体住 `~/.agents/AGENTS.md`「个人 Harness 工作流」，但**该文件不在会话自动注入路径上**（2026-09-16 实证：连续三度漏调 `harness-router`、漏做回答后判定）——故由本技能在场提醒：

- **任何实质性任务开始时，先调用 `harness-router` 技能**，再探索文件或提出澄清问题；任务类型中途切换（如设计讨论 → Unreal 开发）需为新类型重跑。
- **每次最终回答前做「回答后 TAH 判定」自检**：命中触发条件（产出交付物 / 失败后重试成功 / 用户纠正了 agent 判断 / 高影响决策 / 长任务将尽且存在未关闭检查点）→ 加载 `harness-retro` 并**用 `ask_user_question` 提议**（纯文本提议会被自动轮湮没）；同时检查检查点纪律（约每 5 轮实质交流或 `checkpoint: true` 边界）。未命中则静默跳过，不提及。
- **记忆写入只走 `harness-retro` 门控**，绝不自动写卡；载体判据（2026-10-01 扩为三载体）：**引擎机制事实与跨模块通用原理**入本技能、**专属横切体系的规范与机制事实**入其专属技能（如 GameplayTag → `unreal-gameplay-tags`）、**美学/格式约定**入 `unreal-cpp-style`、**事件教训**入 TAH 卡（见 MEM-20260910-02）。判据一句话：**同一主题只允许一个载体，别的地方放指针。**

## 适用时机

- 任何 Unreal 开发任务开始时加载本技能，按上述纪律推进；本技能只承载执行哲学，编译/风格/UnrealSharp 细节走分工技能。
