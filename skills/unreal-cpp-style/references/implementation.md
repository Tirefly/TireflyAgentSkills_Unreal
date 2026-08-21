# 实现文件模式

本文件覆盖 `.cpp` 实现细节：Editor-only 代码、静态成员、匿名 namespace、函数实现、条件换行、数据验证、Build.cs。

## 目录

- [Cpp 文件拆分](#cpp-文件拆分)
- [Editor-only 代码](#editor-only-代码)
- [静态成员](#静态成员)
- [匿名 Namespace Helper](#匿名-namespace-helper)
- [函数实现风格](#函数实现风格)
- [条件换行](#条件换行)
- [数据验证风格](#数据验证风格)
- [Build.cs 风格](#buildcs-风格)

---

## Cpp 文件拆分

单个 `.cpp` 文件**最好保持在 300 行以内**；当功能特别集中、难以干净拆分时可适当放宽，但应及时审视是否出现了职责膨胀。

拆分以**功能内聚**为首要原则，不必严格对照头文件 `.h` 中的 `#pragma region`。region 划分可作为参考，但当一个 region 跨多个功能、或多个 region 同属一个功能时，应以实际功能边界为准。

命名约定：`<OriginalName>_<Feature>.cpp`，例如 `TcsAttributeDefinition_Meta.cpp`、`TcsAttributeDefinition_Editor.cpp`。主实现文件保持 `<OriginalName>.cpp`。

拆分后每个 `.cpp` 文件仍遵循自身头文件 include 第一位、版权声明、Editor-only 包裹等所有 `.cpp` 规则。`#pragma region` 仍然只出现在 `.h` 中，拆分出的 `.cpp` 文件同样不使用 region。

拆分示例（假设 `TcsAttributeDefinition.cpp` 已超出目标行数，按功能拆分）：

```
TcsAttributeDefinition.cpp          // 核心实现（构造、主数据访问等）
TcsAttributeDefinition_Meta.cpp     // 元数据相关实现
TcsAttributeDefinition_Editor.cpp   // 编辑器相关实现（含 WITH_EDITOR 块）
```

---

## Editor-only 代码

Editor-only include、声明和实现都使用 `#if WITH_EDITOR` 包裹。

`.cpp` 中 `#if WITH_EDITOR` 实现块前面留 1 个空行，`#endif` 紧贴最后一个函数的 `}`，不留空行。

头文件声明示例：

```cpp
#if WITH_EDITOR
	// 编辑器验证：属性值变更时的验证
	virtual void PostEditChangeProperty(FPropertyChangedEvent& PropertyChangedEvent) override;

	// 编辑器验证：数据有效性检查
	virtual EDataValidationResult IsDataValid(FDataValidationContext& Context) const override;
#endif
```

头文件 include 示例：

```cpp
#include "CoreMinimal.h"
#include "Engine/DataAsset.h"

#if WITH_EDITOR
#include "Misc/DataValidation.h"
#endif

#include "TcsAttributeDefinition.generated.h"
```

实现文件函数示例：

```cpp
}

#if WITH_EDITOR
void UTcsAttributeDefinition::PostEditChangeProperty(
	FPropertyChangedEvent& PropertyChangedEvent)
{
	Super::PostEditChangeProperty(PropertyChangedEvent);
}

EDataValidationResult UTcsAttributeDefinition::IsDataValid(
	FDataValidationContext& Context) const
{
	return Super::IsDataValid(Context);
}
#endif
```

## 静态成员

静态类常量在头文件声明，在 `.cpp` 文件 include 之后的顶部区域定义。

头文件示例：

```cpp
/**
 * PrimaryAssetType 标识符
 * 注意：虽然 FPrimaryAssetType 是 FName 的 typedef，但使用 FPrimaryAssetType 更语义化
 */
static const FPrimaryAssetType PrimaryAssetType;
```

实现文件示例：

```cpp
// 定义 PrimaryAssetType 静态变量
const FPrimaryAssetType UTcsAttributeDefinition::PrimaryAssetType = FPrimaryAssetType("TcsAttributeDef");
```

## 匿名 Namespace Helper

`.cpp` 内部辅助函数放在匿名 namespace 中。匿名 namespace 通常放在静态变量定义之后、正式成员函数实现之前。namespace 内函数之间使用 1 个空行。

```cpp
// 内部函数：如果 SelfAttributeDefId 不为空，则检查 AttributeRange 是否有 SelfAttributeDefId 的引用，如果有，则清空引用
namespace
{
	bool IsAbstractClampStrategyClass(
		const UClass* StrategyClass)
	{
		return StrategyClass && StrategyClass->HasAnyClassFlags(CLASS_Abstract);
	}

	void SanitizeSelfReferencedRange(
		FTcsAttributeRange& AttributeRange, 
		const FName SelfAttributeDefId)
	{
		if (SelfAttributeDefId.IsNone())
		{
			return;
		}
	}
}
```

## 函数实现风格

使用 Allman 大括号。短函数保持紧凑。复杂验证或会修改数据的逻辑块前添加意图注释。

**参数换行规则**：无参数或单参数且较短时，参数与函数名同行；有参数且参数较长、或多参数时，参数全部换到下一行，缩进 +1 Tab。换行后每个参数之间用 `, ` 分隔，末尾参数后无逗号。

无参数或短参数，保持单行：

```cpp
UTcsAttributeDefinition::UTcsAttributeDefinition()
{
	// 设置默认 Clamp 策略
	ClampStrategyClass = UTcsAttrClampStrategy_Linear::StaticClass();
}
```

```cpp
TArray<FName> UTcsAttributeDefinition::GetOtherAttributeDefIds() const
{
	TArray<FName> AttributeDefIds = UTcsGenericLibrary::GetAttributeNames();
	return AttributeDefIds;
}
```

多参数函数，参数全部换行：

```cpp
void UTcsAttributeDefinition::PostEditChangeProperty(
	FPropertyChangedEvent& PropertyChangedEvent)
{
	Super::PostEditChangeProperty(PropertyChangedEvent);

	const FName PropertyName = PropertyChangedEvent.GetPropertyName();

	// 验证 AttributeRange（静态类型时，确保 MinValue <= MaxValue）
	if (PropertyName == GET_MEMBER_NAME_CHECKED(UTcsAttributeDefinition, AttributeRange))
	{
		// ...
	}
}
```

```cpp
EDataValidationResult UTcsAttributeDefinition::IsDataValid(
	FDataValidationContext& Context) const
{
	EDataValidationResult Result = Super::IsDataValid(Context);
	return Result;
}
```

错误写法（参数挤在第一行）：

```cpp
// 错误
void UTcsAttributeDefinition::PostEditChangeProperty(FPropertyChangedEvent& PropertyChangedEvent)
{
}
```

## 条件换行

多行条件在 `&&` 或 `||` 后换行，续行与附近条件风格保持一致。

```cpp
if (AttributeRange.MinValueType == ETcsAttributeRangeType::ART_Dynamic &&
	AttributeRange.MinValueAttribute == SelfAttributeDefId)
{
	AttributeRange.MinValueAttribute = NAME_None;
}
```

## 数据验证风格

实现 `IsDataValid` 时，先接收 `Super::IsDataValid` 结果，再添加错误或警告。只有当前仍是 `Valid` 时，警告才把结果降级为 `NotValidated`。

```cpp
EDataValidationResult UTcsAttributeDefinition::IsDataValid(
	FDataValidationContext& Context) const
{
	EDataValidationResult Result = Super::IsDataValid(Context);

	// 验证 AttributeDefId
	if (AttributeDefId.IsNone())
	{
		Context.AddError(FText::FromString(TEXT("AttributeDefId cannot be empty")));
		Result = EDataValidationResult::Invalid;
	}

	// 验证 AttributeName（如果显示在UI中，必须有名称）
	if (bShowInUI && AttributeName.IsEmpty())
	{
		Context.AddWarning(FText::FromString(TEXT("bShowInUI is true, but AttributeName is empty")));
		if (Result == EDataValidationResult::Valid)
		{
			Result = EDataValidationResult::NotValidated;
		}
	}

	return Result;
}
```

## Build.cs 风格

`.Build.cs` 优先遵循目标模块附近风格。依赖声明保持明确，不使用绝对 include 路径。

```csharp
PublicDependencyModuleNames.AddRange(new string[]
{
	"Core",
	"CoreUObject",
	"Engine",
	"GameplayTags"
});
```
