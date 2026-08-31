# StateTree 属性绑定与 PropertyRef（UE 5.8）

> 版本基线：UE 5.8.0 (Release-5.8, CL 55116800) · 版本标记约定：**[UE 5.x+]**=该版本新增，**[仅 <5.x]**=已移除/旧行为，**[5.8 变更]**=本版变更；现行 API 判定标准=声明无 UE_DEPRECATED 标记。

## TL;DR

- 属性绑定分三层：**①底座**=独立插件 PropertyBindingUtils（Beta）的 `FPropertyBindingPath`/`FPropertyBindingBindingCollection`/`EPropertyCopyType`；**②序列化产物**=`FStateTreePropertyBindings`（继承 BindingCollection）持有 `SourceStructs`/`PropertyPathBindings`/`PropertyReferencePaths`/`CopyBatches`；**③运行时解析**=`UStateTree::Link()` 内 `PatchBindings()`+`ResolvePaths()` 把编辑态绑定变成 uint16 间接链+`FPropertyBindingCopyInfo` 批量拷贝指令。
- 执行期 `FStateTreeExecutionContext::CopyBatchInternal` 按时机批量 `CopyProperty`：EnterState/Tick/ExitState；任务可关 `bShouldCopyBoundPropertiesOnTick`/`bShouldCopyBoundPropertiesOnExitState`；条件/consideration 测后 `ResetObjects` 清 UObject 引用。
- 绑定是**值拷贝**（单向快照，无观察者）；soft/weak/lazy object 互拷走 `CopyComplex` 不解引用；`FStateTreeStructRef` 拷指针（仅正向）；偏移与数组索引均限 uint16（结构内 64KB 之外的属性不可绑定）。
- `FStateTreePropertyRef` 只存 `FStateTreeIndex16 RefAccessIndex`；**[5.8 变更]** 异步取值弃用 `FStateTreePropertyRefExternalHandle`，改 `MakeWeakExecutionContext()` → `MakeStrongExecutionContext()` → `GetPtrTupleFromStrongExecutionContext()`，官方范本 `FStateTreeRunEnvQueryTask`（§5.4）。
- ⚠ **[5.8 变更]** `FStateTreePropertyRef::GetMutablePtrTuple` 为疑似编译死代码（5 参调 4 参，全引擎零实例化；Release 可编过、用户调用即报错）——改用 `GetPtrTupleFromStrongExecutionContext` 或逐类型 `GetMutablePtr`（§5.5）。
- 参数绑定链：`UStateTree::Parameters`（FInstancedPropertyBag）→ `FStartParameters::InitialGlobalParameters` 严格校验失败回退资产默认值 → `FStateTreeInstanceStorage::GlobalParameters`（Transient）；`FExternalGlobalParameters` 按 hash 注入外部内存，**linked tree 不支持**（§6）。
- 编辑器↔运行时类名对照（防混淆）：`FStateTreeEditorPropertyBindings`↔`FStateTreePropertyBindings`、`FStateTreePropertyBindingCompiler`↔`ResolvePaths`/`PatchBindings`、`FStateTreeBindingLookup`↔`IStateTreeBindingLookup`（§7）。

## 目录

- [1. 源码地图与证据约定](#1-源码地图与证据约定)
- [2. 三层数据流：编辑态绑定 → 拷贝指令](#2-三层数据流编辑态绑定--拷贝指令)
- [3. 运行时拷贝执行](#3-运行时拷贝执行)
- [4. CopyType 判定规则与共享语义](#4-copytype-判定规则与共享语义)
- [5. FStateTreePropertyRef 属性引用](#5-fstatetreepropertyref-属性引用)
- [6. 参数绑定链](#6-参数绑定链)
- [7. 编辑器↔运行时类名对照表](#7-编辑器运行时类名对照表)
- [8. 弃用 API 列表](#8-弃用-api-列表)
- [9. 常见坑速查](#9-常见坑速查)
- [10. 交叉文档](#10-交叉文档)
- [开放问题](#开放问题)

## 1. 源码地图与证据约定

路径缩写（引用格式 `缩写\相对路径 L行号`，均为本机 5.8 源码，行号以 CL 55116800 为准、升级后可能漂移）：

- **ST** = `E:\UnrealEngine\UE_5.8\Engine\Plugins\Runtime\StateTree\Source\StateTreeModule\`
- **PBU** = `E:\UnrealEngine\UE_5.8\Engine\Plugins\Runtime\PropertyBindingUtils\Source\PropertyBindingUtils\`
- **GST** = `E:\UnrealEngine\UE_5.8\Engine\Plugins\Runtime\GameplayStateTree\Source\GameplayStateTreeModule\`

| 文件 | 核心类型 | 职责 |
|---|---|---|
| `ST\Public\StateTreePropertyBindings.h` / `Private\…cpp` | `FStateTreePropertyBindings`、`FStateTreePropertyPathBinding`、`FStateTreeBindableStructDesc`、`FStateTreePropertyAccess`、`FStateTreePropertyRefPath`、`IStateTreeBindingLookup` | 绑定运行时表示与存储 |
| `ST\Public\StateTreePropertyRef.h` / `Private\…cpp` | `FStateTreePropertyRef`、`TStateTreePropertyRef<TRef>`、`FStateTreeBlueprintPropertyRef`、`FStateTreePropertyRefExternalHandle`(弃用) | 属性引用（指针语义）取值 |
| `ST\Public\StateTreePropertyRefHelpers.h` / `Private\…cpp` | `PropertyRefHelpers::Validator<T>`、`GetMutablePtrToProperty`、兼容性校验 | RefType meta 解析与类型闸门 |
| `ST\Private\StateTreeExecutionContext.cpp` / `Public\…h` | `CopyBatchInternal`、`FStartParameters`、`FExternalGlobalParameters` | 绑定从"数据"变"执行"的场所 |
| `ST\Public\StateTreeInstanceData.h` / `Private\…cpp` | `UE::StateTree::InstanceData::GetDataView[OrTemporary]`、Storage::GlobalParameters | 数据源按帧相对寻址 |
| `PBU\Public\PropertyBindingPath.h` | `FPropertyBindingPath`、`EPropertyCopyType`、`FPropertyBindingCopyInfo(Batch)` | 路径模型+拷贝指令模型 |
| `PBU\Public\PropertyBindingBindingCollection.h` / `Private\…cpp` | `FPropertyBindingBindingCollection` | ResolvePaths/CopyProperty/ResetObjects 拷贝引擎 |
| `PBU\Public\PropertyBindingDataView.h` / `PropertyBindingTypes.h` | `FPropertyBindingDataView`、`EPropertyBindingPropertyAccessType`、`GetPropertyCompatibility` | 视图/间接访问类型/兼容性 |

归属澄清：PropertyBindingUtils 是独立插件（非任务早期猜测的 `Engine\Plugins\Runtime\PropertyBinding`，该目录 5.8 不存在）；`ST\StateTreeModule.Build.cs` L77 将其列为 Public 依赖、L83 将 PropertyPath 列为 Private。【源码，`E:\UnrealEngine\UE_5.8\Engine\Plugins\Runtime\PropertyBindingUtils\PropertyBindingUtils.uplugin`，IsBetaVersion=true】

## 2. 三层数据流：编辑态绑定 → 拷贝指令

### 2.1 层次图

```
[编辑器] UStateTreeEditorData.EditorBindings : FStateTreeEditorPropertyBindings
   │  FStateTreeCompiler 调 FStateTreePropertyBindingCompiler::CompileBatch(…)   → 编译流程见 editor.md
   ▼  写入运行时资产字段（随资产保存）
UStateTree::PropertyBindings : FStateTreePropertyBindings（§2.2）
   ▼  加载后 UStateTree::Link()（ST\Private\StateTree.cpp L783）
PatchBindings()（重定类/更新参数 bag struct/烙实例类型进路径段，§2.3）
ResolvePaths()（路径→uint16 间接链 + CopyInfo 判定，§2.3）  → CompileStatus=Executable
   ▼  运行时
FStateTreeExecutionContext::CopyBatchInternal（先评估 PropertyFunction 再逐条 CopyProperty，§3）
```

### 2.2 序列化产物：FStateTreePropertyBindings 字段表

`FStateTreePropertyBindings : FPropertyBindingBindingCollection`（`ST\Public\StateTreePropertyBindings.h`）：

| 字段 | 类型 | 语义 |
|---|---|---|
| `SourceStructs` | `TArray<FStateTreeBindableStructDesc>` | 可绑定源描述；`DataHandle` 是运行时寻址键，`DataSource : EStateTreeBindableStructSource`（Context/Parameter/Evaluator/GlobalTask/StateParameter/Task/Condition/Consideration/TransitionEvent/StateEvent/PropertyFunction/Transition 共 12 类） |
| `PropertyPathBindings` | `TArray<FStateTreePropertyPathBinding>` | 绑定声明：Source/Target 路径+`SourceDataHandle`+`bIsOutputBinding`（反向拷贝，语义经 5.7 新增的 `ResolveBindingCopyInfo` 虚函数生效）+`TaskCompletionCondition : TOptional<UE::StateTree::ETaskCompletionCondition>`（引入版本未证实，见开放问题 6；SourcePath.StructID=任务节点 ID 且 Segments 为空时为任务完成绑定） |
| `PropertyReferencePaths` | `TArray<FStateTreePropertyRefPath>` | PropertyRef 绑定声明 `{SourceDataHandle, SourcePropertyPath}` |
| `CopyBatches` | `TArray<FPropertyBindingCopyInfoBatch>` | 每目标 struct 一个 batch：`TargetStruct`+`BindingsBegin/End`+`PropertyFunctionsBegin/End` |
| `PropertyCopies`/`PropertyIndirections` | Transient | 运行时 `ResolvePaths` 产物，不序列化 |

`FStateTreePropertyBindings` 编辑侧 Add/Remove/Find/Has 全部 `checkf(false)`——运行时集合不可编辑。`OnResolvingPaths()`（StateTreePropertyBindings.cpp L228-254）把 `PropertyReferencePaths` 逐条编译为 `FStateTreePropertyAccess{SourceIndirection, SourceLeafProperty, SourceStructType, SourceDataHandle}` 存入 `PropertyAccesses`，`FStateTreePropertyRef::GetRefAccessIndex()` 即其下标。

### 2.3 Link 内两阶段：PatchBindings → ResolvePaths

`UStateTree::Link()` 流程（`ST\Private\StateTree.cpp`）：`ResetLinked()` 清解析产物（`bBindingsResolved=false`）→ 节点/Schema Link → `PatchBindings()`（L1028-1334）→ `PropertyBindings.ResolvePaths()`（L902）→ `CompileStatus=Executable`；`IsReadyToRun()` 要求 `PropertyBindings.IsValid()`（L59）。

**PatchBindings 七步**（StateTree.cpp L1028-1334）：

| # | 步骤 |
|---|---|
| 1 | 重定过时类：`CLASS_NewerVersionExists` → `GetAuthoritativeClass`（SourceStructs / CopyBatch.TargetStruct / 路径段 InstanceStruct） |
| 2 | 树参数源 desc->Struct = `UStateTree::Parameters.GetPropertyBagStruct()`（L1097） |
| 3 | 带参数状态的 desc->Struct 与 `ParameterBindingsBatch.TargetStruct.Struct` 更新为对应 bag struct（L1115-1132） |
| 4 | Linked 状态要求参数 bag struct 与目标状态相同；LinkedAsset 要求与目标资产 Parameters 的 bag struct 相同（L1136-1172） |
| 5 | 构建 DataViews（树参数/Context 类型视图/状态参数/节点实例数据）与 BindingBatchDataView（batch index→目标数据视图）（L1174-1237） |
| 6 | 逐 batch 逐绑定 `UpdateSegmentsFromValue(Source/Target)`（事件源跳过）——把实例类型烙进路径段，供运行时无值解析（L1258-1306） |
| 7 | 计算 `PropertyFunctionEvaluationScopeMemoryRequirements[batch]`（L1309-1332） |

**ResolvePaths 流程**（`PBU\Private\PropertyBindingBindingCollection.cpp` L349-463）：

1. `PropertyCopies.SetNum(GetNumBindings())`；逐 batch 逐绑定：`Copy.SourceDataHandle = Binding.GetSourceDataHandleStruct()` → StateTree 侧按 DataHandle 在 `SourceStructs` 线性查找描述符。
2. `FPropertyBindingPath::ResolveIndirectionsWithValue` 解析 Source/Target 路径并**压缩间接链**（相邻 Offset 合并；数组/实例间接后的空 Offset 删除），链式存入 `PropertyIndirections`（首项内联在 Copy 内、后续按 `NextIndex` 串联）。
3. 虚函数 `ResolveBindingCopyInfo` **[UE 5.7+]**（StateTree 先置 `bCopyFromTargetToSource = IsOutputBinding()` 再调 Super）→ 基类 `ResolveCopyInfoBetweenIndirections` 判定 `Type`/`CopySize`/`LeafProperty`（规则见 §4.1）。
4. 失败语义：该绑定 `Copy.Type=None`（运行时静默跳过）且 `bBindingsResolved=false` → Link 失败 → 资产不可执行。
5. 运行时 ResolvePaths 无 BindingsOwner，SourceDataView 只传 `{Struct, nullptr}` 类型视图（L406-421）；`SetBindingsOwner` 仅编辑器使用。

## 3. 运行时拷贝执行

### 3.1 CopyBatchInternal 流程

`FStateTreeExecutionContext::CopyBatchInternal<bOnActiveInstances>`（`ST\Private\StateTreeExecutionContext.cpp` L3347-3408）：

1. `Super::GetBatch(BindingsBatch)` 取 batch；`check(TargetView.GetStruct() == Batch.TargetStruct.Struct)`。
2. batch 含 PropertyFunction 时：alloca 分配评估作用域内存 → `PushEvaluationScopeInstanceContainer` → `InitEvaluationScopeInstanceData` → `EvaluatePropertyFunctions(…)`（每个函数**先 CopyBatch 自己的 BindingsBatch** 拷输入（L5421/5425），再调 `FStateTreePropertyFunctionBase::Execute`）——节点契约详见 nodes-builtin.md。
3. 逐 `FPropertyBindingCopyInfo`：活跃实例走 `InstanceData::GetDataView`、校验模式走 `GetDataViewOrTemporary`（可命中临时实例）→ `Super::CopyProperty(Copy, SourceView, TargetView)`。

`CopyProperty`（`PBU\Private\PropertyBindingBindingCollection.cpp` L1252-1286）：`ensure(bBindingsResolved)`；`Type==None` 直接跳过；`GetAddress` 沿间接链寻址（Offset/Object/WeakObject/SoftObject/ObjectInstance/StructInstance/StructInstanceContainer/SharedStruct/IndexArray）→ `PerformCopy`（`bCopyFromTargetToSource` 时交换源/目标）→ 按 `EPropertyCopyType` switch 拷贝。

### 3.2 拷贝时机矩阵

【源码，StateTreeExecutionContext.cpp 调用点行号】

| 时机 | 拷贝对象 | 门控 |
|---|---|---|
| EnterState（L3634 起） | Linked/LinkedAsset 状态 `ParameterBindingsBatch`（L3794；校验版 L7202）；任务 `BindingsBatch`（L3836、L5970）；输出 batch（L3862） | 输入绑定无条件拷 |
| ExitState（L3904 起） | `CopyAllBindingsOnActiveInstances(ECopyBindings::ExitState)`：Evaluators+GlobalTasks+活跃状态逐任务（L3929）；输出 batch（L4043） | 任务 `bShouldCopyBoundPropertiesOnExitState`（默认 true，可关） |
| Tick | 全局帧 Evaluators 输入+输出 batch（L4192-4217、L4407-4433）；GlobalTasks（L4481-4514）；任务输入 batch（L4977，门控 `bShouldCopyBoundPropertiesOnTick`）；任务输出 batch（L5013）；Linked/LinkedAsset 状态参数（L4825） | `ECopyBindings{EnterState, Tick, ExitState}`（StateTreeExecutionContext.h L1485-1490） |
| 条件/Consideration | 每条条件拷 `Cond.BindingsBatch`（L5105/5229）、consideration（L5325，WithValidation 版）→ **测后 `ResetObjects` 清目标 UObject 引用**（L5127/5255/5338） | 防悬挂引用 |
| 异步 | `TStateTreeStrongExecutionContext::CopyInputBindings/CopyOutputBindings` → `CopyBindingBatchForAsync`（StateTreeAsyncExecutionContext.cpp L395-445） | 仅 `DoesRequireInstanceStorage` 源；含 PropertyFunction 的 batch 拒绝 |

时机门控补充：`bShouldCopyBoundPropertiesOnTick`/`bShouldCopyBoundPropertiesOnExitState` 是任务级标志（`ST\Public\StateTreeTaskBase.h`，默认 true）；`ResetObjects` 只清 5 类 Type（CopyComplex/CopyStruct/CopyObject/StructReference/CopyFixedArray）的目标值（PropertyBindingBindingCollection.cpp L1288-1345+）。条件/consideration 实例数据测后自动清；**任务/评估器实例数据不会自动清**——跨状态残留需任务自行处理。

### 3.3 异步拷贝（绑定侧）

- `CopyInputBindings()`：等价 Tick 前输入拷贝；context/external 源跳过并返回 false；**含 PropertyFunction 的 batch 无法在无完整 Context 时求值，直接拒绝**（StateTreeAsyncExecutionContext.h 头注释 L184-191）。
- `CopyOutputBindings()`："Output binding batches never contain property functions, so this call is always async-safe"（L193-200）——输出绑定拥有独立 batch（`OutputBindingsBatch`，**[UE 5.7+]**）且编译器保证不含 PropertyFunction，是异步安全前提。

## 4. CopyType 判定规则与共享语义

### 4.1 EPropertyCopyType 判定表

判定入口 `ResolveCopyInfoBetweenIndirections`（`PBU\Private\PropertyBindingBindingCollection.cpp` L623-915）+ `UE::PropertyBinding::GetPropertyCompatibility`（`PBU\Public\PropertyBindingTypes.h` L139-163，返回 `EPropertyCompatibility{Incompatible, Compatible, Promotable}`）：

| 规则 | 结论 |
|---|---|
| `bCopyFromTargetToSource`（=IsOutputBinding） | 先交换 source/target 再判定与拷贝（L644-653、PerformCopy L1056-1060） |
| 源为整个 struct（源路径为空） | 目标 `FStructProperty` 同型 → `CopyStruct`；目标 `FObjectPropertyBase` 且 IsChildOf → `CopyObject`（L655-676）——整 struct 源**只支持 struct/object 目标** |
| `StructReference` | 目标 leaf 恰为 `PropertyReferenceStructType`（StateTree=FStateTreeStructRef）且源不是同型 → `StructReference`，**仅正向**（"target may outlive source"，L680-697） |
| Compatible | FName→`CopyName`；bool→`CopyBool`（位域安全）；struct→`CopyStruct`（走 ScriptStruct 拷贝）；object→`CopyObject`（拷指针值），但 **soft/weak/lazy 对 soft/weak/lazy → `CopyComplex`（拷引用路径不解引用）**；`EditFixedSize` 数组→`CopyFixedArray`（按 min 数量逐元素）；PlainOldData→`CopyPlain`（memcpy，`CopySize=ElementSize×ArrayDim`）；其余→`CopyComplex`（CopyCompleteValue） |
| Promotable | 数值提升（见 §4.2） |
| 枚举 | 取 underlying property 再判定（L714-723） |
| 数组提升 `bPromoteArrayCopy` | 双方都是动态数组且元素 Promotable：目标 resize 到源数量后逐元素拷（`EditFixedSize` 要求等长，L1223-1247） |

间接访问类型 `EPropertyBindingPropertyAccessType`：Offset/Object/WeakObject/SoftObject/ObjectInstance/StructInstance/IndexArray/`SharedStruct`/`StructInstanceContainer`/Unset（对应 StructUtils；5.6 起取代 `EPropertyBindingAccessType`；SharedStruct/StructInstanceContainer 的确切引入版本未证实——5.6 改名时或 5.8 才加入，见开放问题 6）。

自定义拷贝语义扩展点：继承 BindingCollection，构造时设 `PropertyReferenceStructType = T::StaticStruct()` + `PropertyReferenceCopyFunc/ResetFunc`；需额外判定覆写虚 `ResolveBindingCopyInfo`（先改 `OutCopyInfo` 再调 Super，`ST\Private\StateTreePropertyBindings.cpp` L161-178/L219-226 为官方模式）；自定义解析后处理覆写 `OnResolvingPaths()`/`OnReset()`。完整步骤见 customization-guide.md §10「自定义绑定拷贝语义扩展点」。

### 4.2 Promotions（数值提升）

`Promotable` 方向全表（PropertyBindingPath.h L504-540）：Bool→Byte/Int32/UInt32/Int64/Float/Double；Byte→同上；Int32→Int64/Float/Double；UInt32→Int64/Float/Double；Float→Int32/Int64/Double；Double→Int32/Int64/Float。

### 4.3 共享语义：一切皆值拷贝

- 绑定是**单向值快照**，无引用/观察者语义——源变化不自动传播，只有 §3.2 时机矩阵的再拷贝。输出绑定只是**方向反转的值拷贝**，不是持续同步。
- 唯二"引用"形态：①`EPropertyCopyType::StructReference`（拷指针，目标可能先于源失效，生命周期自理）；②`FStateTreePropertyRef`/`FStateTreeStructRef` 成员（运行时取地址，同样要求源在生存期内，§5.6）。
- `CopyObject` 拷的是 UObject 指针值；soft/weak/lazy 互拷走 `CopyComplex` 拷引用路径——两者语义差异易踩。

### 4.4 uint16 硬限制

【源码，`PBU\Private\PropertyBindingBindingCollection.cpp` ResolvePath L493/L504-509】

- 属性偏移必须 ≤ `MAX_uint16`：单个容器结构内 **64KB 偏移之外**的属性无法绑定（check 失败）。
- 动态数组索引必须可表示为 uint16：超限 `ResolvePaths` 失败 → Link 失败 → 资产不可运行。
- 索引类型 `FPropertyBindingIndex16` 无效值 `MAX_uint16`。

## 5. FStateTreePropertyRef 属性引用

### 5.1 声明形态与 RefType meta

【源码，`ST\Public\StateTreePropertyRef.h` L100-134】

- `FStateTreePropertyRef`：仅存 `FStateTreeIndex16 RefAccessIndex`（friend `FStateTreePropertyBindingCompiler`）。
- `TStateTreePropertyRef<TRef>`：类型安全包装，自动定义 RefType meta；提供单指针与元组取值。
- `FStateTreeBlueprintPropertyRef : FStateTreePropertyRef`：BP 可用（BlueprintType），显式存 `EStateTreePropertyRefType RefType + bIsRefToArray + bIsOptional + TypeObject`，可作 StateTree 参数。
- Meta specifiers：`RefType`（逗号分隔类型列表：bool/byte/int32/int64/float/double/Name/String/Text/UObject 指针/struct 完整路径）、`IsRefToArray`、`CanRefToArray`、`Optional`（未绑定时编译器报错，除非标记）。

```cpp
// 官方头文件注释示例（StateTreePropertyRef.h L117-133）
UPROPERTY(EditAnywhere, meta = (RefType = "float"))
FStateTreePropertyRef RefToFloat;
UPROPERTY(EditAnywhere, meta = (RefType = "/Script/ModuleName.TestStructBase"))
FStateTreePropertyRef RefToTest;
UPROPERTY(EditAnywhere, meta = (RefType = "/Script/CoreUObject.Vector, /Script/Engine.Actor", CanRefToArray))
FStateTreePropertyRef RefToLocationLikeTypes;   // 多类型 → 用元组取值 API
```

兼容规则【源码，`ST\Private\StateTreePropertyRefHelpers.cpp`】：struct/object 仅**精确同类型**可引用（L170-175 注释：防"FVector 赋给 FMyVector"）。

### 5.2 可引用源白名单

`IsPropertyAccessibleForPropertyRef`（StateTreePropertyRefHelpers.cpp L232-258）：

| 源类别 | 可否 PropertyRef |
|---|---|
| Parameter / StateParameter / TransitionEvent / StateEvent | 恒可 |
| Context / Condition / Consideration / PropertyFunction | 恒不可 |
| GlobalTask / Evaluator / Task | 仅当 **Output 属性**或源本身是 PropertyRef（链式） |

### 5.3 同步取值链

`PropertyRefHelpers::ResolvePropertyReferenceIndirections`（`ST\Private\StateTreePropertyRef.cpp` L7-59）：

1. `ExecutionFrame.StateTree->GetPropertyBindings().GetPropertyAccess(Ref)` 取 Access；
2. `InstanceData::GetDataViewOrTemporary(Storage, nullptr, Frame, Access->SourceDataHandle)`——**硬编码传空 ContextAndExternalDataViews：PropertyRef 不允许指向 context 或 external 数据**（L16-17）；
3. leaf property 本身是 PropertyRef 时（链式引用，仅源为 Global/Subtree 参数、住父帧）：按 `GlobalParameterDataFrameID`/`StateParameterDataFrameID` 在 ActiveFrames+`TemporaryStorage->GetTemporaryFrames()` 定位父帧，取出引用的 PropertyRef **递归解析**；
4. 否则返回 `{SourceView, PropertyAccess, &PropertyBindings}` → `GetMutablePropertyPtr<T>`（StateTreePropertyBindings.h L388-399：先 `PropertyRefHelpers::Validator<T>::IsValid(*SourceLeafProperty)` 类型校验再按间接链取地址）。

调用约束：`GetMutablePtr<T>(Context)` 依赖 `Context.GetCurrentlyProcessedFrame()`（内部 check）——只能在节点处理栈内（EnterState/ExitState/Tick/条件测试等）调用；`GetPtrFromStrongExecutionContext` 是**非 const** 成员而元组版是 const（L153/177）——按 const 引用持有的 PropertyRef 上不能调用单指针版。

### 5.4 **[5.8 变更]** 异步取值新范式：WeakContext → StrongExecutionContext

**旧模式（5.8 弃用）**：`FStateTreePropertyRefExternalHandle`/`TStateTreePropertyRefExternalHandle`（StateTreePropertyRef.h L294-366）只存 `TWeakPtr<FStateTreeInstanceStorage> + TWeakObjectPtr<const UStateTree> + RootState handle`，取值时按 RootState 在活跃帧数组线性反查，再走已弃用的 ParentFrame 版 helper。

**新模式**：`FStateTreeWeakExecutionContext`（`ST\Public\StateTreeAsyncExecutionContext.h` L262-370）从 `FStateTreeExecutionContext` 构造时捕获 Owner/StateTree/Storage 弱引用 + **当前处理帧三元组 `FrameID/StateID/NodeIndex`** + `TWeakPtr<ITemporaryStorage> TemporaryStorage`；`TStateTreeStrongExecutionContext<bWithWriteAccess>`（L59-242）是栈上强上下文：`TStrongObjectPtr` 钉 Owner/StateTree、`TSharedPtr` 共享 Storage、RAII 获取实例存储 MRSW 访问探测（`bAccessAcquired`）；`GetActivePathInfo()` 把三元组解析回 `FActivePathInfo`（含 TemporaryStorage 的临时帧/临时状态查找，StateTreeAsyncExecutionContext.cpp L360-393）。`bWithWriteAccess=true` 即 `FStateTreeStrongExecutionContext`（写），false 即 `FStateTreeStrongReadOnlyExecutionContext`（只读）（L244-245）。

官方范本 `FStateTreeRunEnvQueryTask::EnterState`（`GST\Private\Tasks\StateTreeRunEnvQueryTask.cpp` L36-70；构造函数显式关 `bShouldCopyBoundPropertiesOnTick/ExitState` L17-18，改由异步直写输出）：

```cpp
// 存：仍持有有效处理帧的节点回调内捕获精确路径
FQueryFinishedSignature::CreateLambda([WeakContext = Context.MakeWeakExecutionContext()](TSharedPtr<FEnvQueryResult> QueryResult) mutable
{
    const FStateTreeStrongExecutionContext StrongContext = WeakContext.MakeStrongExecutionContext();
    if (FInstanceDataType* InstanceDataPtr = StrongContext.GetInstanceDataPtr<FInstanceDataType>())
    {
        auto [VectorPtr, ActorPtr, ArrayOfVector, ArrayOfActor] =
            InstanceDataPtr->Result.GetPtrTupleFromStrongExecutionContext<FVector, AActor*, TArray<FVector>, TArray<AActor*>>(StrongContext);
        // 命中哪个解引用哪个，直写被引用属性
        StrongContext.FinishTask(bSuccess ? EStateTreeFinishTaskType::Succeeded : EStateTreeFinishTaskType::Failed);
    }
}));
```

逐维度差异表：

| 维度 | ExternalHandle（旧，**[仅 <5.x]** 行为） | StrongExecutionContext（新，**[5.8 变更]**） |
|---|---|---|
| 帧定位 | RootState handle 反查 ActiveFrames（仅活跃帧） | 构造时记录 FrameID/StateID/NodeIndex，取值时 `GetActivePathInfo()` 精确解析；**可命中 TemporaryFrames/临时状态** |
| 临时存储 | 无概念 | WeakContext 捕获 `TWeakPtr<ITemporaryStorage>`（Start/状态选择期间的临时帧全局参数可解析） |
| 读写控制 | 仅可变指针 | `TStateTreeStrongExecutionContext<false/true>` 只读/写，RAII MRSW 访问探测 |
| 生命周期 | TWeakPtr 存储悬空即失败 | `TStrongObjectPtr` 钉 Owner/StateTree + `TSharedPtr` Storage；`IsValid()` 校验帧/状态仍活跃 |
| 附带能力 | 无 | `CopyInputBindings()/CopyOutputBindings()`（§3.3） |
| 源类型限制 | — | 仅 `DoesRequireInstanceStorage` 源可解析；PropertyRef 本就禁 context/external，语义自洽 |

**迁移步骤**：①删除 ExternalHandle 成员，节点只留 PropertyRef/TStateTreePropertyRef 字段（序列化不变，`RefAccessIndex` 兼容）；②WeakContext 构造时机提前到仍持有有效处理帧的节点回调内（EnterState/Tick 等）；③异步回调改用 `MakeStrongExecutionContext()`（写）或 `MakeStrongReadOnlyExecutionContext()`（只读）；④输出直写用 `GetPtrTupleFromStrongExecutionContext`，或改 `CopyOutputBindings()` 复用编辑器绑定；⑤弃用的 ParentFrame 版 helper 一并迁移（§9 坑 4）。StateTreeTestSuite 无 StrongContext+PropertyRef 用例（检索零命中）。

### 5.5 ⚠ 编译死代码警告：GetMutablePtrTuple（5.8.0）

> ⚠️ **[5.8 变更]** 疑似编译死代码：`FStateTreePropertyRef::GetMutablePtrTuple` / `TStateTreePropertyRef<T>::GetMutablePtrTuple`
> 调用点 `ST\Public\StateTreePropertyRef.h` L172 以 **5 个实参**调用 `UE::StateTree::PropertyRefHelpers::GetMutablePtrTupleToProperty`，而该函数现行重载（StateTreePropertyRefHelpers.h L85）与 5.8 弃用重载（L71）都只有 **4 参**、且均为函数模板，无第三重载。模板体内的不匹配调用只在**实例化时报错**：引擎内对该模板零实例化（全引擎检索 0 处使用），故 5.8.0 Release 自身可编过；**用户代码一旦调用（含 TStateTreePropertyRef 转发 L269-272）即编译错误**。【源码·本技能已复核 L172/L85/L71；判定【推断】为 5.8 重构（ParentFrame→TemporaryStorage）漏改残骸，未实际编译验证】
> **规避**：单类型用 `GetMutablePtr<T>(Context)`（同文件 L143-150，实参正确）；异步/多类型用 `GetPtrTupleFromStrongExecutionContext<T...>(StrongContext)`。

### 5.6 与 FStateTreeStructRef 的关系

| | `FStateTreePropertyRef`（成员） | `FStateTreeStructRef`（`ST\Public\StateTreeTypes.h` L1199） |
|---|---|---|
| 角色 | **声明式取指针的成员**，用户代码读它 | **被绑定的目标引用槽**，绑定系统写它 |
| 拷贝路由 | 取值走 PropertyAccess 间接链 | 目标 leaf 为 StructRef → `EPropertyCopyType::StructReference`：`Target->Set(FStructView(SourceStruct, SourceAddress))`，拷**指针**不复制数据；重置为空视图 |
| 方向 | — | 仅源→目标（"target may outlive source"，PropertyBindingBindingCollection.cpp L680） |
| 关联机制 | `SerializeFromMismatchedTag` 接受历史 "StateTreeStructRef" tag 并丢弃（StateTreePropertyRef.h L198-212） | 注入：`FStateTreePropertyBindings` 构造时设 `PropertyReferenceStructType = FStateTreeStructRef::StaticStruct()` + 拷贝/重置函数（StateTreePropertyBindings.cpp L161-178） |

## 6. 参数绑定链

### 6.1 全局参数：资产 bag → 宿主注入 → Storage

【源码，`ST\Public\StateTree.h` L525、`ST\Private\StateTreeExecutionContext.cpp` L1508-1511/L3526-3536】

```
UStateTree::Parameters : FInstancedPropertyBag（资产参数，绑定源时 Struct=GetPropertyBagStruct()）
   ↓  Context.Start(FStartParameters)
FStartParameters::InitialGlobalParameters (FConstStructView)
   ↓  有效且 SetGlobalParameters 成功 → 用宿主值；否则回退 GetDefaultParameters().GetValue()
FStateTreeInstanceStorage::GlobalParameters : FInstancedStruct（**Transient**，StateTreeInstanceData.h L424-426）
```

- `SetGlobalParameters(FConstStructView)` **严格校验 bag struct 类型一致**（ensure 失败返回 false）——不匹配时宿主参数被**静默丢弃**（回退资产默认值，仅编辑器日志），升级改参数结构后务必迁移 bag。
- 宿主注入路径：`FStateTreeReference::GetGlobalParameters()`（每引用参数覆盖）→ 组件 `StartTree` 中 `.InitialGlobalParameters = StateTreeRef.GetGlobalParameters()`（`GST\Private\Components\StateTreeComponent.cpp` L197）。
- 存储层同语义接口（StateTreeInstanceData.h L336-351）：`SetGlobalParameters(FConstStructView)` 现行 / `(const FInstancedPropertyBag&)` 弃用（§8）/ `GetGlobalParameters()/GetMutableGlobalParameters()`。
- 状态/子树参数：每状态参数为 `FCompactStateTreeParameters`（内含 FInstancedPropertyBag value，经 `State.ParameterTemplateIndex` 寻址）；Linked/LinkedAsset 校验见 §2.3 步 4；其 `ParameterBindingsBatch` 在进入/Tick 时拷贝（§3.2）。

### 6.2 FExternalGlobalParameters：外部内存 hash 注入

【源码，`ST\Public\StateTreeExecutionContext.h` L364-374、StateTreeExecutionContext.cpp L1297-1320/L3191-3202】

- 源类型声明为 `EStateTreeParameterDataType::ExternalGlobalParameterData`（StateTreeTypes.h L391-396）时，绑定源解析走 `FExternalGlobalParameters`：宿主 `Add(Copy, InParameterMemory)` 以 **`hash(SourceLeafProperty, SourceIndirection)`** 为键注册外部内存，执行期 `GetDataViewOrTemporary(CopyInfo)` `Find` 命中即用。
- 注入：`Context.SetExternalGlobalParameters(const FExternalGlobalParameters*)`（SetContextRequirements 阶段）。
- 映射是裸指针 TMap：宿主需保证绑定集合不变期间内存有效；绑定变更资产后需重建映射；未注册时 ensure 报错（L3196）。
- **限制：linked tree 中不支持（checkf，L2853/L3210）**。

### 6.3 任务完成绑定（简要）

`FStateTreePropertyPathBinding::TaskCompletionCondition`（引入版本未证实，见开放问题 6）：SourcePath.StructID 设为任务节点 ID、Segments 为空（StateTreePropertyBindings.h L223-229）；编辑器编译为 `FTaskCompletionDispatcher`，运行时 `BroadcastTaskCompletionDispatchers` 广播（StateTreeExecutionContext.cpp L2102）。编译细节见 editor.md，委托体系见 events-async.md。

## 7. 编辑器↔运行时类名对照表

两侧类名相近但生命周期与可编辑性完全不同，检索/改代码前先对照：

| 概念 | 编辑器侧（StateTreeEditorModule） | 运行时侧（StateTreeModule） |
|---|---|---|
| 绑定集合 | `FStateTreeEditorPropertyBindings`（StateTreeEditorPropertyBindings.h L23，挂在 `UStateTreeEditorData::EditorBindings`） | `FStateTreePropertyBindings`（UStateTree 序列化产物） |
| 集合 Owner | `IStateTreeEditorPropertyBindingsOwner` / `UStateTreeEditorPropertyBindingsOwner : UPropertyBindingBindingCollectionOwner` | 无 Owner（`SetBindingsOwner` 仅编辑器调用） |
| 编译/解析 | `FStateTreePropertyBindingCompiler`（Init/CompileBatch/CompileReferences/Finalize…） | `UStateTree::Link()` 内 `PatchBindings()` + `ResolvePaths()` |
| 绑定查询 | `FStateTreeBindingLookup : IStateTreeBindingLookup`（编辑器实现，含 `GetPropertyBindingSource/GetPropertyPathDisplayName` 等） | `IStateTreeBindingLookup`（运行时仅声明接口，StateTreePropertyBindings.h L404-419） |

## 8. 弃用 API 列表

| API | 弃用版本 | 替代 |
|---|---|---|
| `FStateTreePropertyRefExternalHandle` / `TStateTreePropertyRefExternalHandle<TRef>` | 5.8 | ExecutionContext/StrongExecutionContext 异步模式（§5.4） |
| `PropertyRefHelpers::GetMutablePtrToProperty/GetMutablePtrTupleToProperty` 的 ParentFrame 版（StateTreePropertyRefHelpers.h L35/L71） | 5.8 | ITemporaryStorage 版本（弃用壳转发时 TemporaryStorage=nullptr，§9 坑 4） |
| `FStateTreeExecutionContext::Start(const FInstancedPropertyBag*, int32 RandomSeed=-1)` | 5.8 | `Start(FStartParameters)`；`FStartParameters::GlobalParameters` → `InitialGlobalParameters` |
| `FStateTreeExecutionContext::SetGlobalParameters` 的 FInstancedPropertyBag 版；`FStateTreeInstanceStorage::SetGlobalParameters(const FInstancedPropertyBag&)` | 5.8 | FConstStructView 版本 |
| `FStateTreePropertyPathBinding` 无 `bIsOutputBinding` 的两个构造（StateTreePropertyBindings.h L141-158） | 5.7 | 带 `bInIsOutputBinding` 的构造 |
| `FPropertyBindingBindingCollection::ResolveCopyType`（静态、空实现） | 5.7 | 虚函数 `ResolveBindingCopyInfo` |
| `PropertyRefHelpers::IsPropertyAccessibleForPropertyRef(TConstArrayView<FStateTreePropertyPathIndirection>, …)` | 5.6 | `FPropertyBindingPathIndirection` 重载 |
| `EPropertyBindingAccessType`（PropertyBindingTypes.h L16-25） | 5.6 | `EPropertyBindingPropertyAccessType` |
| `FStateTreeEditorPropertyPath`（UE_DEPRECATED(all)） | all | `FPropertyBindingPath`（加载期迁移走 `FStateTreePropertyPathBinding::PostSerialize`） |

## 9. 常见坑速查

| # | 坑 | 要点 |
|---|---|---|
| 1 | `GetMutablePtrTuple` 编译死代码 | §5.5 警告框；改 `GetPtrTupleFromStrongExecutionContext` 或逐类型 `GetMutablePtr` |
| 2 | PropertyRef 的上下文依赖 | `GetMutablePtr(Context)` 只能在节点处理栈内调；PropertyRef 不能指向 context/external 数据；不能引用 Condition/Consideration/PropertyFunction 内部（§5.2/§5.3） |
| 3 | 绑定是拷贝语义 | 无自动同步；StructReference 拷指针目标可能悬挂；任务/评估器实例数据测后不自动清 UObject 引用（§4.3） |
| 4 | 5.8 弃用壳的临时帧失效 | ParentFrame 版 helper 转发时 `TemporaryStorage=nullptr`——链式 PropertyRef 需查 TemporaryFrames 父帧时解析失败返回 nullptr；升级应改传当前 TemporaryStorage |
| 5 | uint16 硬限制 | 64KB 偏移外的属性、超 uint16 的数组索引 → ResolvePaths 失败 → Link 失败（§4.4） |
| 6 | `SetGlobalParameters` 静默回退 | bag struct 不匹配 ensure+回退资产默认值，宿主参数被丢弃（§6.1） |
| 7 | soft/weak/lazy 与普通 object | 互拷前者走 `CopyComplex` 不解引用、后者拷指针值——语义不同（§4.1） |
| 8 | `ResolvePaths` 未成功就 `CopyProperty` | ensure（编程错误信号）；`Copy.Type==None` 条目静默跳过并视为成功 |
| 9 | 头注释陈旧 | StateTreeAsyncExecutionContext.h L52 写 `WeakContext.CreateStrongContext()`，实际 API 是 `MakeStrongExecutionContext()/MakeStrongReadOnlyExecutionContext()` |
| 10 | `Super::` 的刻意绕行 | 引擎内 `PropertyBindings.Super::GetBatch/GetBatchCopies/CopyProperty` 刻意用基类非 StateTree 版本，仿写时注意 |

## 10. 交叉文档

| 主题 | 文档 |
|---|---|
| PropertyFunction 节点契约（Execute 时机/单 Output 约束） | nodes-builtin.md（本文 §3.1 步 2 仅绑定侧） |
| 编辑器编译流程 / 绑定 UI | editor.md |
| 声明 PropertyRef、自定义绑定拷贝、宿主注入参数的使用步骤速查 | customization-guide.md |
| 数据源寻址矩阵 / InstanceStorage 布局 | instance-data.md、runtime-execution.md |
| 异步 Weak/Strong 上下文全景 | events-async.md |
| 版本差异汇总 | version-deltas.md |

## 开放问题

1. `FStateTreePropertyRef::GetPtrFromStrongExecutionContext` 非 const 而元组版 const（StateTreePropertyRef.h L153/177）是否有意为之——影响 const PropertyRef 成员上的调用选择（单指针版需非 const this）。
2. §5.5 死代码判定基于 C++ 模板实例化规则+全引擎零调用检索+源码复核，未实际编译验证"用户调用必报错"；若 Epic 在补丁中修复（补第 5 参或删调用），本文档警告框需更新。
3. `FStateTreePropertyRefExternalHandle` 体系的引入版本无本地证据（仅证实 5.8 弃用）；StateTreeAsyncExecutionContext.h 头注释 `CreateStrongContext()` 是否曾为真实 API 名未证实（现行名 MakeStrongExecutionContext）。
4. 引擎树外（Marketplace/项目代码）是否存在会实例化 §5.5 死模板的存量用户代码无法本地验证；本调研仅覆盖 Engine\Source + Engine\Plugins。
5. PropertyBindingUtils 插件由旧名 "PropertyBinding" 更名的确切版本未证实（5.8 中旧目录不存在）。
6. 版本归属存疑（相关行内标记已按"未证实"降级）：`EPropertyBindingPropertyAccessType::SharedStruct`/`StructInstanceContainer`（5.6 改名时引入 vs 5.8 新增，与 version-deltas §3 的表述互为假设）、`TaskCompletionCondition` 与 `bIsOutputBinding` 反向拷贝语义（关联 5.7 体系但无直接弃用/新增宏佐证）——需旧版引擎源码或 GitHub 历史裁决。
