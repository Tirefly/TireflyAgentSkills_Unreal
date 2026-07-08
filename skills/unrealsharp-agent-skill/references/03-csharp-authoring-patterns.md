# CSharp Authoring Patterns

这一篇现在可以作为 UnrealSharp 脚本开发的基础编程指导来使用，但它的边界要说清楚：

- 它适合指导“会被 Unreal 反射系统看见的 C# 代码”怎么写。
- 它适合回答 UnrealSharp 自己的硬性要求、命名规则、生命周期规则、元数据写法。
- 它不替代团队自己的玩法架构规范、目录规划、日志策略和业务抽象规范。

## 目录

- UnrealSharp 的反射边界
- C++ 宏与 C# Attribute 的对应关系
- 硬性要求与 Analyzer 规则
- 推荐编码规范
- 最常用的 C# 特性入口
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
- [Plugins/UnrealSharp/README.md](../../../../Plugins/UnrealSharp/README.md)

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

参考入口：

- [UClassAttribute.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Core/Attributes/UClassAttribute.cs)
- [UStructAttribute.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Core/Attributes/UStructAttribute.cs)
- [UEnumAttribute.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Core/Attributes/UEnumAttribute.cs)
- [UInterfaceAttribute.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Core/Attributes/UInterfaceAttribute.cs)
- [UPropertyAttribute.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Core/Attributes/UPropertyAttribute.cs)
- [UFunctionAttribute.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Core/Attributes/UFunctionAttribute.cs)
- [UMetaDataAttribute.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Core/Attributes/UMetaDataAttribute.cs)
- [MetaTags.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Core/Attributes/MetaTags.cs)

最重要的理解是：

- UnrealSharp 的“可导出接口面”仍然受 UE 反射模型约束。
- C# 里没有一对一的 `UPARAM(...)` 宏；参数相关约束要么通过参数级 Attribute 表达，要么通过函数级元数据按参数名引用。

## 硬性要求与 Analyzer 规则

这些不是“建议最好这样写”，而是 UnrealSharp 自带 Analyzer 会直接报错的约束：

- 暴露给 Unreal 的类型必须使用 Unreal 命名前缀：Actor 用 `A`，UObject 用 `U`，Struct 用 `F`，Enum 用 `E`，Interface 用 `I`。
- `[UClass]` 类里的 `[UProperty]` 不能写成 field，必须写成 property。
- `[UEnum]` 的底层类型必须是 `byte`。
- `UObject` 及其子类不能直接 `new`；要按类型使用 `NewObject<T>()`、`SpawnActor<T>()`、`CreateWidget<T>()`、`AddComponentByClass<T>()`。
- 标记为 `DefaultComponent = true` 的 `[UProperty]`，类型必须继承 `UActorComponent`，并且该 property 必须有 setter。
- 如果接口类型出现在 `[UProperty]` 或 `[UFunction]` 参数里，这个接口本身必须带 `[UInterface]`。

规则来源：

- [AnalyzerReleases.Unshipped.md](../../../../Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.SourceGenerators/AnalyzerReleases.Unshipped.md)
- [UnrealTypeAnalyzer.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Analyzers/UnrealTypeAnalyzer.cs)
- [UEnumAnalyzer.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Analyzers/UEnumAnalyzer.cs)
- [UInterfaceAnalyzer.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Analyzers/UInterfaceAnalyzer.cs)
- [UObjectCreationAnalyzer.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Analyzers/UObjectCreationAnalyzer.cs)
- [DefaultComponentAnalyzer.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Analyzers/DefaultComponentAnalyzer.cs)

如果你要把本 Skill 当“开发规范”使用，应该把这部分视为第一优先级，因为它们是会中断编译或生成的真实约束。

## 推荐编码规范

下面这些不一定都有 Analyzer 强制，但它们能显著降低 Glue 生成和 Blueprint 暴露风险：

- 所有 C# 源文件统一使用 UTF-8 无签名（UTF-8 without BOM）编码，换行符统一使用 LF（`\n`），不要使用 BOM 或 CRLF。
- 所有反射类型默认按 Unreal 命名习惯命名，不要在公开类型上混用纯 C# 风格命名。
- 反射类型优先用 `partial`，尤其是会参与 BlueprintEvent、生成器扩展或热重载的类型。
- 业务逻辑只写在业务工程里，不要写进 `*.Glue` 或 `obj/UHT/**/*.generated.cs`。
- 对外暴露给 Blueprint 的 API 要保持签名稳定，避免把编辑器节点技巧和 override 契约耦合在一起。
- 如果某个函数会修改参数内容，不要把它命名成伪属性 setter 风格，避免误触生成器的 getter/setter 规则。
- 如果某个 API 只是为了让 Blueprint 节点更友好，优先用包装函数解决，不要污染核心 override 点。

## 最常用的 C# 特性入口

这些文件定义了 UnrealSharp 的常用声明方式：

- [UClassAttribute.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Core/Attributes/UClassAttribute.cs)
- [UStructAttribute.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Core/Attributes/UStructAttribute.cs)
- [UEnumAttribute.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Core/Attributes/UEnumAttribute.cs)
- [UInterfaceAttribute.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Core/Attributes/UInterfaceAttribute.cs)
- [UPropertyAttribute.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Core/Attributes/UPropertyAttribute.cs)
- [UFunctionAttribute.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Core/Attributes/UFunctionAttribute.cs)
- [MetaTags.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Core/Attributes/MetaTags.cs)
- [UMetaDataAttribute.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Core/Attributes/UMetaDataAttribute.cs)

常见模式：

- `[UClass] public partial class AMyActor : AActor`
- `[UStruct] public partial struct FMyData`
- `[UEnum] public enum EMyState : byte`
- `[UInterface] public interface IMyTargetable`
- `[UProperty(PropertyFlags.EditDefaultsOnly | PropertyFlags.BlueprintReadOnly)] public partial int Count { get; set; }`
- `[UFunction(FunctionFlags.BlueprintCallable)] public void DoSomething()`
- `[UFunction(FunctionFlags.BlueprintEvent)] public partial void OnSomething();`
- `[Category("Combat"), DisplayName("Apply Damage")]`
- `[UMetaData("ClampMin", "0.0")]`

## 类型声明规范：UClass / UStruct / UEnum / UInterface

### UClass

- 使用 `[UClass]` 暴露类，必要时通过 `ClassFlags` 和 `config` 参数补充类级语义。
- Actor 类名保持 `A` 前缀，非 Actor 的 UObject 类保持 `U` 前缀。
- 公开给 Unreal 的类最好写成 `partial class`。

### UStruct

- 使用 `[UStruct]` 暴露结构体。
- 命名必须使用 `F` 前缀。
- 如果需要自定义 Blueprint 的 Make / Break 节点，可优先查找 `HasNativeMake`、`HasNativeBreak`、`HiddenByDefault` 等元数据。

### UEnum

- 使用 `[UEnum]` 暴露枚举。
- 底层类型使用 `: byte`，这是 Analyzer 的硬要求。
- 命名必须使用 `E` 前缀。

### UInterface

- 使用 `[UInterface]` 暴露接口。
- 命名必须使用 `I` 前缀。
- 如果接口不允许 Blueprint 实现，可设置 `CannotImplementInterfaceInBlueprint = true`，或配合对应元数据。

## 属性声明规范：UProperty

`[UProperty]` 在 UnrealSharp 里承担了大部分 `UPROPERTY(...)` 的职责。

应优先记住这几类能力：

- 可见性和编辑性：`EditDefaultsOnly`、`EditInstanceOnly`、`EditAnywhere`、`VisibleDefaultsOnly`、`VisibleInstanceOnly`、`VisibleAnywhere`
- Blueprint 可见性：`BlueprintReadOnly`、`BlueprintReadWrite`、`BlueprintAssignable`
- 生命周期和存储：`Transient`、`SaveGame`、`Config`
- 复制：`Replicated`、`ReplicatedUsing`、`LifetimeCondition`
- 组件声明：`DefaultComponent`、`RootComponent`、`AttachmentComponent`、`AttachmentSocket`

关键规则：

- 在 `[UClass]` 里，`[UProperty]` 必须写成 property，不能写 field。
- `DefaultComponent = true` 只能用于 `UActorComponent` 类型。
- `DefaultComponent = true` 的 property 必须可写，因为默认子组件要被初始化。

一个安全的组件示例形状：

```csharp
[UProperty(PropertyFlags.VisibleDefaultsOnly, DefaultComponent = true, RootComponent = true)]
public partial USceneComponent Root { get; set; }
```

## 函数声明规范：UFunction

`[UFunction]` 对应 `UFUNCTION(...)`，主要通过 `FunctionFlags` 描述导出行为。

常见标记：

- `BlueprintCallable`
- `BlueprintPure`
- `BlueprintEvent`
- `RunOnServer`
- `RunOnClient`
- `Multicast`
- `Reliable`
- `Exec`

额外能力：

- `CallInEditor` 是 `UFunctionAttribute` 的布尔字段，不是元数据字符串。

推荐做法：

- Blueprint API 先保证签名清晰，再考虑节点体验优化。
- BlueprintEvent 只承担稳定的 override 契约，不要把动态返回类型技巧直接压在它身上。
- 如果要做更友好的 Blueprint 节点行为，用包装的 `BlueprintCallable` 函数承接。

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

常见元数据类别可以这样记：

- 共享元数据：`DisplayName`、`Category`、`ToolTip`、`ShortToolTip`、`ScriptName`
- 类元数据：`BlueprintSpawnableComponent`、`BlueprintThreadSafe`、`ShowWorldContextPin`
- 结构体元数据：`HasNativeMake`、`HasNativeBreak`、`HiddenByDefault`
- 函数元数据：`AdvancedDisplay`、`AutoCreateRefTerm`、`CompactNodeTitle`、`DeterminesOutputType`、`ExpandEnumAsExecs`、`WorldContext`
- 属性或参数元数据：`AllowAbstract`、`AllowedClasses`、`MustImplement`

如果用户问“这个元数据 UnrealSharp 支不支持”，优先顺序应该是：

1. 查 [MetaTags.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Core/Attributes/MetaTags.cs) 有没有现成 Attribute
2. 没有就用 [UMetaDataAttribute.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Core/Attributes/UMetaDataAttribute.cs)
3. 如果用了仍然没效果，再去查导出器、Glue 生成器或 UE 原生反射是否支持该组合

## 典型代码形状

官方 README 提供了一个高价值样例：

- [Plugins/UnrealSharp/README.md](../../../../Plugins/UnrealSharp/README.md)

这个样例值得记住的点：

- C# 类通常是 `partial`
- BlueprintEvent 通过 `partial` 声明和 `_Implementation` 配对
- 组件可通过 `UProperty(DefaultComponent = true, RootComponent = true)` 声明
- 委托和复制属性都可以通过特性和包装类型来表达

## C# 与 Blueprint 的关系

官方 FAQ 强调：

- Blueprint 不是只有“可视化脚本”，也是资产接口层。
- 推荐像使用 C++ 一样，为 C# 类创建 Blueprint 子类，让设计师和内容制作者配置资产与可编辑属性。

参考：

- <https://www.unrealsharp.com/faq>

因此，回答“是否还需要 Blueprint”时，不要给出“完全不需要”的误导性回答。更准确的说法是：

- 纯逻辑可以更多放在 C#
- 资产装配、设计师可配置入口、蓝图事件覆盖仍然很有价值

## UObject 构造规则

官方 FAQ 明确指出：

- `new T()` 不适用于继承自 `UObject` 的类型
- 对 `UObject` 及其子类应使用 `NewObject<T>()`

而 UnrealSharp 自带 Analyzer 又把这条规则细化成了几条硬约束：

- `UObject` 用 `NewObject<T>()`
- `AActor` 用 `SpawnActor<T>()`
- `UUserWidget` 用 `CreateWidget<T>()`
- `UActorComponent` / `USceneComponent` 用 `AddComponentByClass<T>()`

参考：

- <https://www.unrealsharp.com/faq>
- [UObjectCreationAnalyzer.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Analyzers/UObjectCreationAnalyzer.cs)

这类问题在回答时要非常直接，不要让用户误以为普通 C# 对象构造方式可以替代 UObject 生命周期。

## 生成层与业务层的边界

必须明确区分：

- 业务层：用户自己写的 `Script/<ProjectName>/` 项目和插件 C# 项目
- 生成层：`*.Glue` 工程和 `obj/UHT/**/*.generated.cs`

不要建议用户：

- 直接修改 `*.Glue` 项目源码
- 在 `generated.cs` 里打补丁作为长期方案

如果需要修复生成结果，正确方向通常是：

1. 改 C++ 反射声明
2. 或改 UnrealSharp 生成器
3. 然后重新触发生成

## 常见高风险设计模式

这两类模式值得优先警惕：

- `BlueprintNativeEvent + DeterminesOutputType`
- `SetX(NonConstRefParam)` 或 `SetX(OutParm)` 风格命名

如果用户问“从设计上是否合理”，优先建议：

- 把 `DeterminesOutputType` 放在对外的 `BlueprintCallable` wrapper 上
- 保持 `BlueprintNativeEvent` 的 override 契约稳定、返回类型固定
- 对会修改入参的函数使用更明确的动词命名，而不是伪装成属性 setter

如果当前工作区 vendored 了插件源码，还应参考：

- [FunctionExporter.cs](../../../../Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/Exporters/FunctionExporter.cs)
- [PropertyGetterSetterUtilities.cs](../../../../Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/Utilities/PropertyGetterSetterUtilities.cs)

## 能否把本 Skill 当作编程指导

可以，但要按下面的方式使用：

- 把本篇当作 UnrealSharp 反射面 C# 开发规范。
- 把 Analyzer 规则当作硬性要求。
- 把 `MetaTags.cs` 和 `UMetaDataAttribute.cs` 当作元数据字典和兜底入口。
- 把项目自己的架构设计、业务分层、目录约定放在仓库级文档里补充，不要强行让 UnrealSharp Skill 代替全部项目规范。
