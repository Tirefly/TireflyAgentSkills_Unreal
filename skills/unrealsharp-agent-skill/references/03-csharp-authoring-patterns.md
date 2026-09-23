# CSharp Authoring Patterns

这一篇现在可以作为 UnrealSharp 脚本开发的基础编程指导来使用，但它的边界要说清楚：

- 它适合指导“会被 Unreal 反射系统看见的 C# 代码”怎么写。
- 它适合回答 UnrealSharp 自己的硬性要求、命名规则、生命周期规则、元数据写法。
- 它不替代团队自己的玩法架构规范、目录规划、日志策略和业务抽象规范。

> 路径一律按“相对当前工作区”解析。

## 目录

- UnrealSharp 的反射边界
- C++ 宏与 C# Attribute 的对应关系
- 硬性要求与 Analyzer 规则
- 推荐编码规范
- 类型声明规范：UClass / UStruct / UEnum / UInterface
- 属性声明规范：UProperty
- 函数声明规范：UFunction
- 参数与“UPARAM 等价物”
- 元数据写法与选择策略
- 典型代码形状
- C# 与 Blueprint 的关系
- UObject 构造规则
- 生成层与业务层的边界

## UnrealSharp 的反射边界

UnrealSharp 本质上依赖 UE 反射系统生成 C# API，因此它和 Blueprint 有一个共同限制：

- 只有被 UCLASS / USTRUCT / UFUNCTION / UPROPERTY 暴露到反射的内容，才能稳定出现在 C# 侧。

参考：

- <https://www.unrealsharp.com/faq>
- `Plugins/UnrealSharp/README.md`

如果用户问“为什么这个 C++ API 在 C# 里没有”，第一反应应该是检查反射可见性，而不是先怀疑生成器坏了。

## C++ 宏与 C# Attribute 的对应关系

UnrealSharp 不是把 `UCLASS`、`UPROPERTY`、`UFUNCTION` 这些宏原样搬到 C#，而是换成 Attribute 体系：

- `UCLASS(...)` 对应 `[UClass(...)]`
- `USTRUCT(...)` 对应 `[UStruct]`
- `UENUM(...)` 对应 `[UEnum]`
- `UINTERFACE(...)` 对应 `[UInterface]`
- `UPROPERTY(...)` 对应 `[UProperty(...)]`
- `UFUNCTION(...)` 对应 `[UFunction(...)]`
- `meta = (...)` 对应专用元数据 Attribute，或 `[UMetaData("Key", "Value")]`

### 完整 Attribute 清单

`Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Core/Attributes/` 下共 15 个特性类：

| 文件 | 类 | 构造参数 | 公开成员 |
|---|---|---|---|
| `UClassAttribute.cs` | `UClassAttribute`（sealed） | `(ClassFlags flags = None, string config = "")` | `Flags`, `Config` |
| `UStructAttribute.cs` | `UStructAttribute`（sealed） | 无 | — |
| `UEnumAttribute.cs` | `UEnumAttribute`（sealed） | 无 | — |
| `UInterfaceAttribute.cs` | `UInterfaceAttribute`（sealed） | 无 | `CannotImplementInterfaceInBlueprint` |
| `UPropertyAttribute.cs` | `UPropertyAttribute`（sealed） | `(PropertyFlags flags = None)` | `Flags`, `DefaultComponent`, `RootComponent`, `AttachmentComponent`, `AttachmentSocket`, `ReplicatedUsing`, `LifetimeCondition`, `ArrayDim` |
| `UFunctionAttribute.cs` | `UFunctionAttribute`（sealed） | `(FunctionFlags flags = None)` | `Flags`, `CallInEditor` |
| `UMetaDataAttribute.cs` | `UMetaDataAttribute`（sealed） | `(string key, string value = "")` | `Key`, `Value` |
| `CustomMetaDataAttribute.cs` | `CustomMetaDataAttribute` | 无 | — |
| `BlittableTypeAttribute.cs` | `BlittableTypeAttribute` | 无 | — |
| `OverrideComponentAttribute.cs` | `OverrideComponentAttribute` | `(Type overrideComponentType, string overridePropertyName, string? optionalPropertyName = null)` | 三个对应字段 |
| `UModule.cs` | `UModuleAttribute` | 无 | — |
| `USingleDelegateAttribute.cs` | `USingleDelegateAttribute` | 无 | — |
| `UMultiDelegateAttribute.cs` | `UMultiDelegateAttribute` | 无 | — |
| `GeneratedFunctionAttribute.cs` | `GeneratedFunctionAttribute` | `(string functionEngineName)` | `FunctionEngineName` |
| `WeaverGeneratedAttribute.cs` | `WeaverGeneratedAttribute` | 无 | — |

**注意命名空间分两处**，写 `using` 时别搞错：

- `UnrealSharp.Attributes`：UClass、UStruct、UEnum、UInterface、UProperty、UFunction、UModule、USingleDelegate、UMultiDelegate、WeaverGenerated
- `UnrealSharp.Core.Attributes`：UMetaData、CustomMetaData、BlittableType、OverrideComponent、GeneratedFunction，以及 MetaTags.cs 里的全部元数据特性

最重要的理解是：

- UnrealSharp 的“可导出接口面”仍然受 UE 反射模型约束。
- C# 里没有一对一的 `UPARAM(...)` 宏；参数相关约束要么通过参数级 Attribute 表达，要么通过函数级元数据按参数名引用。

## 硬性要求与 Analyzer 规则

这些不是“建议最好这样写”，而是 UnrealSharp 自带 Analyzer 会直接报错的约束。

规则表来自 `Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Analyzers/AnalyzerReleases.Unshipped.md`，**全部为 Error 级**：

| ID | Category | 触发者 | 含义 |
|---|---|---|---|
| `PrefixAnalyzer` | Naming | `UnrealTypeAnalyzer` | 暴露给 UE 的类型缺少 Unreal 命名前缀 |
| `US0001` | UnrealSharp | `UStaticLambdaAnalyzer` | `[UFunction]` 标在静态 lambda 上（没有 UObject 实例可承载） |
| `US0002` | Category | `UEnumAnalyzer` | `[UEnum]` 底层类型不是 `byte` |
| `US0003` | Category | `UInterfaceAnalyzer` | `[UProperty]` 的属性类型是接口但接口没带 `[UInterface]` |
| `US0004` | Category | `UInterfaceAnalyzer` | `[UFunction]` 的参数类型是接口但接口没带 `[UInterface]` |
| `US0006` | Category | `UnrealTypeAnalyzer` | **类**里的 `[UProperty]` 写成了 field |
| `US0007` | Category | `UObjectCreationAnalyzer` | `USceneComponent` 不能用 `new` |
| `US0008` | Category | `UObjectCreationAnalyzer` | `UActorComponent` 不能用 `new` |
| `US0009` | Category | `UObjectCreationAnalyzer` | `UUserWidget` 不能用 `new` |
| `US0010` | Category | `UObjectCreationAnalyzer` | `AActor` 不能用 `new` |
| `US0011` | Category | `UObjectCreationAnalyzer` | `UObject` 不能用 `new` |
| `US0012` | Usage | `UFunctionConflictAnalyzer` | 接口与实现类都标了 `[UFunction]`，重复 |
| `US0013` | Category | `DefaultComponentAnalyzer` | `DefaultComponent = true` 但类型不继承 `UActorComponent` |
| `US0014` | Category | `DefaultComponentAnalyzer` | `DefaultComponent = true` 但属性没有 setter |

关键细则：

- **前缀规则**：Struct 用 `F`，Enum 用 `E`，Interface 用 `I`，Class 继承 `AActor` 用 `A`、否则继承 `UObject` 用 `U`。只检查**带了对应特性**的类型，没标特性的类型不管。
- **`US0006` 只针对类**：结构体里的 `[UProperty]` **允许**写成 field。这一点与旧版不同——结构体字段规则（旧编号 US0005）已经退役，代码里只剩一个没人用的常量。
- **`US0005` 已退役**：`UnrealTypeAnalyzer.cs` 里还留着 `StructAnalyzerId = "US0005"` 常量，但没有任何 `DiagnosticDescriptor` 使用它。不要把它当作现行规则。
- **容器接口豁免**：`IList`、`IReadOnlyList`、`IDictionary`、`IReadOnlyDictionary`、`ISet`、`IReadOnlySet` 不触发 `US0003`/`US0004`。
- **`US0002` 有豁免口**：带 `GeneratedTypeAttribute` 的类型不受枚举底层类型约束。
- **`US0013`/`US0014` 相互独立**：同一个属性可能同时触发两条。

规则来源：

- `Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Analyzers/AnalyzerReleases.Unshipped.md`
- `Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Analyzers/UnrealTypeAnalyzer.cs`
- `Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Analyzers/UEnumAnalyzer.cs`
- `Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Analyzers/UInterfaceAnalyzer.cs`
- `Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Analyzers/UObjectCreationAnalyzer.cs`
- `Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Analyzers/DefaultComponentAnalyzer.cs`
- `Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Analyzers/StaticLambdaAnalyzer.cs`
- `Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Analyzers/InterfaceImplementationAnalyzer.cs`

> 另有 glue 生成器自身的一组诊断（`USG001`–`USG004`、`USG006`），定义在 `Managed/UnrealSharp/UnrealSharp.GlueGenerator/` 下，与上面的作者侧规则是两套编号。

如果你要把本 Skill 当“开发规范”使用，应该把这部分视为第一优先级，因为它们是会中断编译或生成的真实约束。

## 推荐编码规范

下面这些不一定都有 Analyzer 强制，但它们能显著降低 glue 生成和 Blueprint 暴露风险：

- 所有 C# 源文件统一使用 UTF-8 无签名（UTF-8 without BOM）编码，换行符统一使用 LF（`\n`），不要使用 BOM 或 CRLF。
- **所有 `[UProperty]` 属性必须写 `partial`**。这不是风格建议——生成器会为同一个属性发出 `partial` 声明来合并 getter/setter 实现，不写 `partial` 会直接编译冲突。
- **所有 `[UClass]` / `[UStruct]` / `[UInterface]` 类型必须写 `partial`**。生成器发出的类型声明本身就带 `partial`。
- 反射类型默认按 Unreal 命名习惯命名，不要在公开类型上混用纯 C# 风格命名。
- 业务逻辑只写在业务工程里，不要写进 `Intermediate/UnrealSharp/**` 下的任何文件。
- 对外暴露给 Blueprint 的 API 要保持签名稳定，避免把编辑器节点技巧和 override 契约耦合在一起。
- 如果某个函数会修改参数内容，不要把它命名成伪属性 setter 风格，避免误触生成器的 getter/setter 规则。
- 如果某个 API 只是为了让 Blueprint 节点更友好，优先用包装函数解决，不要污染核心 override 点。

### 为什么 `partial` 是必须的

生成器侧的逻辑（`Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.GlueGenerator/`）：

- 类型声明恒为 `partial`：
  ```csharp
  builder.AppendLine($"{protection}partial {_modifiers}{_typeKeyword} {_declarationName}");
  ```
- 属性默认发 `partial`，只有从 C++ 导入的路径（UHT 生成物）才关掉：
  ```csharp
  public readonly bool IsPartial = true;      // 用户侧默认
  // ...
  string partialDeclaration = IsPartial ? "partial " : string.Empty;
  ```
  UHT 导入的构造分支会显式 `IsPartial = false`，所以引擎类型的 glue 里是普通属性（例如 `FBox` 的 `Min`/`Max` 就是普通 field）——**那是生成物，不是你该模仿的写法**。
- `BlueprintEvent` / RPC 函数会额外发一个 `partial` 声明，由你补 `_Implementation` 体。

枚举是唯一的例外：枚举不带 `partial`。

## 类型声明规范：UClass / UStruct / UEnum / UInterface

### UClass

- 使用 `[UClass]` 暴露类，通过 `ClassFlags` 和 `config` 参数补充类级语义。
- 必须写成 `partial class`。
- Actor 类名保持 `A` 前缀，非 Actor 的 UObject 类保持 `U` 前缀。

```csharp
[UClass]
public partial class AMyActor : AActor { }

[UClass(ClassFlags.Abstract)]
public partial class UMyBase : UObject { }
```

### UStruct

- 使用 `[UStruct]` 暴露结构体，命名必须使用 `F` 前缀。
- **必须写成 `partial`**（生成器发的是 `public partial record struct F...`，不写会报 CS0260）。
- 结构体里的 `[UProperty]` 允许是 field（`US0006` 只管类）。
- 如果需要自定义 Blueprint 的 Make / Break 节点，可用 `HasNativeMake`、`HasNativeBreak`、`HiddenByDefault` 元数据。

### UEnum

- 使用 `[UEnum]` 暴露枚举。
- **底层类型必须是 `: byte`**，这是 `US0002` 硬要求。
- 命名必须使用 `E` 前缀。
- 枚举不写 `partial`。

```csharp
[UEnum]
public enum EMyState : byte { Idle, Running }
```

### UInterface

- 使用 `[UInterface]` 暴露接口，命名必须使用 `I` 前缀。
- **必须写成 `partial interface`**（生成器发的是 `public partial interface I...`）。
- 如果接口不允许 Blueprint 实现，可设 `CannotImplementInterfaceInBlueprint = true`（该设置既是特性字段，也有同名元数据）。

## 属性声明规范：UProperty

`[UProperty]` 在 UnrealSharp 里承担了大部分 `UPROPERTY(...)` 的职责。

### PropertyFlags 枚举成员（完整）

`PropertyFlags` 是 `[Flags] enum : ulong`，定义在 `UPropertyAttribute.cs` 里。实际成员只有这些：

```
None, Config, Instanced, Export, NoClear, EditFixedSize, SaveGame,
BlueprintReadOnly, BlueprintReadWrite, Replicated,
EditDefaultsOnly, EditInstanceOnly, EditAnywhere,
BlueprintAssignable, BlueprintCallable,
VisibleAnywhere, VisibleDefaultsOnly, VisibleInstanceOnly, Transient
```

> **常见误区**：`DefaultComponent`、`RootComponent`、`AttachmentComponent`、`AttachmentSocket`、`ReplicatedUsing`、`LifetimeCondition` **都不是 `PropertyFlags` 成员**，它们是 `UPropertyAttribute` 上的命名参数/字段。写 `PropertyFlags.DefaultComponent` 是错的。

### UPropertyAttribute 的命名参数

```csharp
public PropertyFlags Flags = flags;
public bool DefaultComponent = false;
public bool RootComponent = false;
public string AttachmentComponent = "";
public string AttachmentSocket = "";
public string ReplicatedUsing = "";
public ELifetimeCondition LifetimeCondition = ELifetimeCondition.None;
public int ArrayDim = 1;
```

- `DefaultComponent`：声明为默认子对象，只对 `UActorComponent` 类型有效，且属性必须有 setter（`US0013`/`US0014`）。
- `RootComponent`：标为根组件；多个都标时只有第一个生效。
- `AttachmentComponent` / `AttachmentSocket`：按**变量名字符串**指定挂载目标与插槽。
- `ReplicatedUsing`：填回调函数名字符串，例如 `ReplicatedUsing = nameof(OnRep_X)`。**声明它本身就会开启复制**，不需要额外加 `Replicated`。回调签名支持 `void OnRep_X()` 或 `void OnRep_X(T oldValue)`。
- `LifetimeCondition`：取值为 `ELifetimeCondition` 枚举（`None`/`InitialOnly`/`OwnerOnly`/…/`Never`），定义在 `UnrealSharp.Core/Flags/LifetimeCondition.cs`。

### 关键规则

- 在 `[UClass]` 里，`[UProperty]` 必须写成 property，不能写 field（`US0006`）。
- 属性必须写 `partial`。
- `DefaultComponent = true` 只能用于 `UActorComponent` 类型，且属性必须可写。

一个安全的组件示例形状（与官方 README 一致）：

```csharp
[UProperty(DefaultComponent = true, RootComponent = true)]
public partial UStaticMeshComponent Mesh { get; set; }

[UProperty(PropertyFlags.EditDefaultsOnly | PropertyFlags.BlueprintReadOnly)]
protected partial float RespawnTime { get; set; }

[UProperty(PropertyFlags.BlueprintReadOnly, ReplicatedUsing = nameof(OnRep_IsPickedUp))]
protected partial bool bIsPickedUp { get; set; }
```

## 函数声明规范：UFunction

`[UFunction]` 对应 `UFUNCTION(...)`，主要通过 `FunctionFlags` 描述导出行为。

### FunctionFlags 枚举成员（完整）

```
None, BlueprintCallable, BlueprintPure, BlueprintEvent,
Multicast, RunOnServer, RunOnClient, Reliable, Exec,
BlueprintAuthorityOnly, BlueprintCosmetic
```

注意 C# 侧叫 `BlueprintEvent`，对应 C++ 的 `BlueprintNativeEvent`。

### UFunctionAttribute 的字段

```csharp
public FunctionFlags Flags = flags;
public bool CallInEditor = false;
```

- `CallInEditor` 是**布尔字段**，不是元数据字符串。

### 推荐做法

- Blueprint API 先保证签名清晰，再考虑节点体验优化。
- BlueprintEvent 只承担稳定的 override 契约，不要把动态返回类型技巧直接压在它身上。
- `BlueprintEvent` 函数需要拆成两半：`partial` 声明 + `_Implementation` 实现体。
- 如果要做更友好的 Blueprint 节点行为，用包装的 `BlueprintCallable` 函数承接。

```csharp
// Overridable from Blueprints
[UFunction(FunctionFlags.BlueprintEvent)]
public partial void OnIsPickedUpChanged(bool bIsPickedUp);

public partial void OnIsPickedUpChanged_Implementation(bool bIsPickedUp)
{
    SetActorHiddenInGame(bIsPickedUp);
}
```

## 参数与“UPARAM 等价物”

在 UnrealSharp C# 里，没有直接写 `UPARAM(ref)` 这种宏的日常用法。参数相关能力主要分成两类：

- 参数目标上的 Attribute，例如 `AllowAbstract`、`AllowedClasses`、`MustImplement`
- 函数目标上的元数据 Attribute，通过参数名字符串指定某个参数，例如 `WorldContext("WorldContextObject")`

也就是说，C++ 的 `UPARAM(...)` 在 UnrealSharp 里通常不是一个单独宏，而是：

- 参数级元数据 Attribute
- 或函数级元数据中“引用参数名”的那一类规则

最常见的这类函数元数据包括：

- `WorldContext`
- `AutoCreateRefTerm`
- `DeterminesOutputType`
- `ExpandEnumAsExecs`
- `HidePin`
- `InternalUseParam`
- `LatentInfo`

需要特别注意：

- `DeterminesOutputType` 改变的是 Blueprint 节点的动态返回类型体验，不应该随意和 `BlueprintNativeEvent` 的 override 契约耦合。
- `ExpandEnumAsExecs` 依赖枚举参数，并且该枚举本身要是有效的 `[UEnum]`。
- `WorldContext` 只是元数据声明，真正是否能自动处理，还取决于 UnrealSharp 导出器对该参数模式的支持。

## 元数据写法与选择策略

UnrealSharp 提供了两层元数据入口：

- 优先使用强类型 Attribute，例如 `Category`、`DisplayName`、`ToolTip`、`AutoCreateRefTerm`、`DeterminesOutputType`、`WorldContext`
- 如果插件暂时没封装对应元数据，再使用 `[UMetaData("Key", "Value")]`

这个策略很重要：

- 强类型 Attribute 可读性更强，也更不容易写错 key。
- `UMetaData` 是兜底手段，不应该替代所有常见元数据。

### MetaTags.cs 的实际覆盖范围

`Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Core/Attributes/MetaTags.cs` 定义了 **90 个**元数据特性，按文件自身的 region 分组：

- **Shared**：`DisplayName`、`Category`、`ToolTip`、`ShortToolTip`、`ScriptName`
- **Class**：`BlueprintSpawnableComponent`、`BlueprintThreadSafe`、`ChildCannotTick`、`ChildCanTick`、`DeprecatedNode`、`DeprecationMessage`、`DontUseGenericSpawnObject`、`ExposedAsyncProxy`、`IgnoreCategoryKeywordsInSubclasses`、`IsBlueprintBase`、`KismetHideOverrides`、`ProhibitedInterfaces`、`RestrictedToClasses`、`ShowWorldContextPin`、`UsesHierarchy`
- **Enum**：`Bitflags`、`Experimental`
- **Interface**：`CannotImplementInterfaceInBlueprint`
- **Struct**：`HasNativeBreak`、`HasNativeMake`、`HiddenByDefault`
- **Function (Method)**：`AdvancedDisplay`、`ArrayParm`、`ArrayTypeDependentParams`、`AutoCreateRefTerm`、`BlueprintAutocast`、`BlueprintInternalUseOnly`、`BlueprintProtected`、`CallableWithoutWorldContext`、`CommutativeAssociativeBinaryOperator`、`CompactNodeTitle`、`CustomStructureParam`、`DefaultToSelf`、`DeprecatedFunction`、`DeterminesOutputType`、`DevelopmentOnly`、`ExpandEnumAsExecs`、`ForceAsFunction`、`HidePin`、`HideSelfPin`、`InternalUseParam`、`KeyWords`、`Latent`、`LatentInfo`、`MaterialParameterCollectionFunction`、`NativeBreakFunc`、`NotBlueprintThreadSafe`、`UnsafeDuringActorConstruction`、`WorldContext`
- **Property**：`AllowAbstract`、`AllowedClasses`、`MustImplement`、`AllowPreserveRatio`、`ArrayClamp`、`AssetBundles`、`BlueprintBaseOnly`、`BlueprintCompilerGeneratedDefaults`、`ClampMin`、`ClampMax`、`UiMin`、`UiMax`、`ConfigHierarchyEditable`、`ContentDir`、`DisplayAfter`、`DisplayPriority`、`DisplayThumbnail`、`EditCondition`、`EditConditionHides`、`EditFixedOrder`、`ExactClass`、`ExposeFunctionCategories`、`ExposeOnSpawn`、`FilePathFilter`、`GetByRef`、`HideAlphaChannel`、`HideViewOptions`、`InlineEditConditionToggle`、`LongPackageName`、`MakeEditWidget`、`NoGetter`、`BindWidget`、`BindWidgetOptional`、`BindWidgetAnim`、`Categories`、`FieldNotify`

用法上类名带 `Attribute` 后缀，但书写时省略：`[Category("Combat")]`、`[DisplayName("Apply Damage")]`、`[ClampMin("0.0")]`。

> `Categories` 与 `Category` 是**两个不同的特性**，别混用。

如果用户问“这个元数据 UnrealSharp 支不支持”，优先顺序应该是：

1. 查 `MetaTags.cs` 有没有现成 Attribute
2. 没有就用 `UMetaDataAttribute`
3. 如果用了仍然没效果，再去查导出器、glue 生成器或 UE 原生反射是否支持该组合

## 典型代码形状

官方 README 提供了一个高价值样例（`Plugins/UnrealSharp/README.md`）。这个样例值得记住的点：

- 类和属性都是 `partial`
- `[UProperty]` 用命名参数表达组件语义：`UProperty(DefaultComponent = true, RootComponent = true)`
- `[UProperty]` 用 `PropertyFlags` 表达可见性/复制
- BlueprintEvent 通过 `partial` 声明和 `_Implementation` 配对
- 委托属性用 `TMulticastDelegate<T>` 配 `PropertyFlags.BlueprintAssignable`
- 软引用用 `TSoftObjectPtr<T>?`

## C# 与 Blueprint 的关系

官方 FAQ 强调：

- Blueprint 不是只有“可视化脚本”，也是资产接口层。
- 推荐像使用 C++ 一样，为 C# 类创建 Blueprint 子类，让设计师和内容制作者配置资产与可编辑属性。

参考：<https://www.unrealsharp.com/faq>

因此，回答“是否还需要 Blueprint”时，不要给出“完全不需要”的误导性回答。更准确的说法是：

- 纯逻辑可以更多放在 C#
- 资产装配、设计师可配置入口、蓝图事件覆盖仍然很有价值

## UObject 构造规则

官方 FAQ 明确指出：

- `new T()` 不适用于继承自 `UObject` 的类型
- 对 `UObject` 及其子类应使用 `NewObject<T>()`

而 UnrealSharp 自带 Analyzer 又把这条规则细化成了五条硬约束（按**最派生优先**分派，所以 `USceneComponent` 报 `US0007` 而不是 `US0008`）：

| 基类 | 要求的构造方式 | 诊断 ID |
|---|---|---|
| `USceneComponent` | `AddComponentByClass<T>()` | `US0007` |
| `UActorComponent` | `AddComponentByClass<T>()` | `US0008` |
| `UUserWidget` | `CreateWidget<T>()` | `US0009` |
| `AActor` | `SpawnActor<T>()` | `US0010` |
| `UObject` | `NewObject<T>()` | `US0011` |

对应的真实 API 在 `Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp/Extensions/`：

- `CoreUObject/Object.cs` —— `NewObject<T>()`、`SpawnActor<T>()`（含 `SpawnActorDeferred<T>()`）、`CreateWidget<T>()`
- `Engine/Actor.cs` —— 多个 `AddComponentByClass<T>()` 重载

参考：

- <https://www.unrealsharp.com/faq>
- `Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Analyzers/UObjectCreationAnalyzer.cs`

这类问题在回答时要非常直接，不要让用户误以为普通 C# 对象构造方式可以替代 UObject 生命周期。

## 生成层与业务层的边界

必须明确区分：

- 业务层：用户自己写的 `Script/<ModuleName>/` 项目
- 生成层：`Intermediate/UnrealSharp/UHT/<TargetType>/<ModuleName>/` 下的全部内容（glue 工程 + `*.generated.cs`）

不要建议用户：

- 直接修改 glue 工程里的源码
- 在 `*.generated.cs` 里打补丁作为长期方案

如果需要修复生成结果，正确方向通常是：

1. 改 C++ 反射声明
2. 或改 UnrealSharp 生成器（`Source/UnrealSharpManagedGlue/` 或 `UnrealSharp.GlueGenerator`）
3. 然后重新触发生成（跑一次 Editor 目标构建）

## 常见高风险设计模式

这两类模式值得优先警惕：

- `BlueprintNativeEvent + DeterminesOutputType`
- `SetX(NonConstRefParam)` 或 `SetX(OutParm)` 风格命名

如果用户问“从设计上是否合理”，优先建议：

- 把 `DeterminesOutputType` 放在对外的 `BlueprintCallable` wrapper 上
- 保持 `BlueprintNativeEvent` 的 override 契约稳定、返回类型固定
- 对会修改入参的函数使用更明确的动词命名，而不是伪装成属性 setter

如果当前工作区 vendored 了插件源码，还应参考：

- `Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/Exporters/FunctionExporter.cs`
- `Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/Utilities/PropertyGetterSetterUtilities.cs`

## 能否把本 Skill 当作编程指导

可以，但要按下面的方式使用：

- 把本篇当作 UnrealSharp 反射面 C# 开发规范。
- 把 Analyzer 规则当作硬性要求。
- 把 `MetaTags.cs` 和 `UMetaDataAttribute.cs` 当作元数据字典和兜底入口。
- 把项目自己的架构设计、业务分层、目录约定放在仓库级文档里补充，不要强行让 UnrealSharp Skill 代替全部项目规范。
