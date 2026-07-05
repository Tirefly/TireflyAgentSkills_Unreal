---
name: ue5-cpp-style
description: UE5 C++ 编码风格指南。用于创建、修改、审查或格式化 Unreal Engine C++ 文件，包括 .h、.cpp、.Build.cs、UCLASS/USTRUCT/UENUM、UPROPERTY/UFUNCTION、Editor-only 代码、Unreal 模块代码、Gameplay 插件 C++ 代码。编辑 UE5 C++ 前使用此 Skill，以匹配 Tirefly 风格的文件组织、注释、空行、region、命名、反射宏和实现文件布局。
---

# UE5 C++ 编码风格

编辑 Unreal Engine C++ 代码时遵循此风格。若本指南与目标文件附近既有风格冲突，优先匹配目标文件附近的实际写法。不要为了套用风格而重排无关代码。

## 核心原则

- 先遵循 Unreal Engine C++ 约定，再遵循本风格。
- 反射类型必须正确使用 `UCLASS`、`USTRUCT`、`UENUM`、`UINTERFACE`、`UPROPERTY`、`UFUNCTION`。
- 头文件使用清晰的 `#pragma region` 组织；`.cpp` 文件保持平铺，不使用 region。
- 类、结构体、枚举、委托、成员变量、成员函数应有必要注释。
- 注释解释意图、约束、编辑器行为和反射 API 语义，不要给每一行代码写机械注释。
- 代码符号默认使用 ASCII；中文主要用于注释、编辑器显示名、Tooltip、数据验证消息等已有中文上下文。

## 文件头

每个 `.h` 和 `.cpp` 文件以版权声明开头，版权声明后空一行。

头文件示例：

```cpp
// Copyright Tirefly. All Rights Reserved.

#pragma once
```

实现文件示例：

```cpp
// Copyright Tirefly. All Rights Reserved.

#include "Attribute/TcsAttributeDefinition.h"
```

## 头文件 Include 顺序

`.h` 文件中，先包含 Unreal 核心头，再包含父类或字段类型依赖，最后包含 `.generated.h`。`.generated.h` 必须是最后一个普通 include。

```cpp
#include "CoreMinimal.h"
#include "Engine/DataAsset.h"
#include "GameplayTagContainer.h"
#include "StructUtils/InstancedStruct.h"
#include "TcsAttributeDefinition.generated.h"
```

错误示例：

```cpp
#include "TcsAttributeDefinition.generated.h"
#include "CoreMinimal.h"
```

如果头文件需要 Editor-only 头文件，也保持 `.cpp` 文件中的分组风格：运行时 include 在前，Editor-only include 使用 `#if WITH_EDITOR` 单独包裹，然后 `.generated.h` 仍然放在最后。

```cpp
#include "CoreMinimal.h"
#include "Engine/DataAsset.h"
#include "GameplayTagContainer.h"

#if WITH_EDITOR
#include "Misc/DataValidation.h"
#endif

#include "TcsAttributeDefinition.generated.h"
```

不要把 Editor-only include 混在普通 include 中：

```cpp
#include "CoreMinimal.h"
#include "Misc/DataValidation.h"
#include "Engine/DataAsset.h"
#include "TcsAttributeDefinition.generated.h"
```

## Cpp Include 顺序

`.cpp` 文件中，先包含自身对应头文件，再包含同模块依赖，再包含其他依赖。Editor-only include 使用 `#if WITH_EDITOR` 单独包裹。

```cpp
#include "Attribute/TcsAttributeDefinition.h"
#include "Attribute/AttrClampStrategy/TcsAttrClampStrategy_Linear.h"
#include "TcsGenericLibrary.h"

#if WITH_EDITOR
#include "Misc/DataValidation.h"
#endif
```

自身头文件必须放第一位，避免隐藏头文件自包含问题。

错误示例：

```cpp
#include "TcsGenericLibrary.h"
#include "Attribute/TcsAttributeDefinition.h"
```

## 空行规则

空行用于表达代码结构层级。保持已有文件中清晰的纵向间隔。

- 版权声明后使用 1 个空行。
- 同一函数或同一 region 内，相关但独立的小块之间使用 1 个空行。
- 函数定义之间、region 之间通常使用 2 个空行。
- 文件顶级大段之间，如 include、枚举、结构体、类、静态变量、匿名 namespace 之间，通常使用 3 个空行。

顶级结构示例：

```cpp
#include "TcsAttributeDefinition.generated.h"



// 属性范围类型
UENUM(BlueprintType)
enum class ETcsAttributeRangeType : uint8
{
    ART_None = 0 UMETA(DisplayName = "无"),
};



// 属性范围
USTRUCT(BlueprintType)
struct TIREFLYCOMBATSYSTEM_API FTcsAttributeRange
{
    GENERATED_BODY()
};
```

函数间隔示例：

```cpp
UTcsAttributeDefinition::UTcsAttributeDefinition()
{
    ClampStrategyClass = UTcsAttrClampStrategy_Linear::StaticClass();
}


FPrimaryAssetId UTcsAttributeDefinition::GetPrimaryAssetId() const
{
    return FPrimaryAssetId(PrimaryAssetType, AttributeDefId);
}
```

## 头文件 Region

`#pragma region` 只用于 `.h` 文件。每个 region 前使用中文单行注释说明该区域的语义。

```cpp
// 属性定义的核心内容
#pragma region Identity

public:
    /**
     * 属性的唯一标识符
     * 对应原 DataTable 的 RowName
     */
    UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Identity")
    FName AttributeDefId;

#pragma endregion
```

相邻 region 之间使用两个空行。

```cpp
#pragma endregion


// 属性定义的标签设置
#pragma region Meta
```

## Cpp 文件不使用 Region

`.cpp` 文件按函数顺序直接组织，不使用 `#pragma region`。

正确示例：

```cpp
void UTcsAttributeDefinition::PostEditChangeProperty(FPropertyChangedEvent& PropertyChangedEvent)
{
    Super::PostEditChangeProperty(PropertyChangedEvent);
}


EDataValidationResult UTcsAttributeDefinition::IsDataValid(FDataValidationContext& Context) const
{
    return Super::IsDataValid(Context);
}
```

错误示例：

```cpp
#pragma region Editor
void UTcsAttributeDefinition::PostEditChangeProperty(FPropertyChangedEvent& PropertyChangedEvent)
{
}
#pragma endregion
```

## 注释风格

使用中文注释。简单标题、短逻辑说明使用 `//`。

```cpp
// 定义 PrimaryAssetType 静态变量
const FPrimaryAssetType UTcsAttributeDefinition::PrimaryAssetType = FPrimaryAssetType("TcsAttributeDef");
```

反射类型、重要属性、公开函数、多行说明使用 `/** */`。

```cpp
/**
 * 属性定义资产
 *
 * 用途: 定义单个属性的所有配置信息
 * 继承: UPrimaryDataAsset（支持 Asset Manager）
 * 命名约定: DA_Attr_<AttributeName> (例如: DA_Attr_Health)
 */
UCLASS(BlueprintType, Const)
class TIREFLYCOMBATSYSTEM_API UTcsAttributeDefinition : public UPrimaryDataAsset
{
    GENERATED_BODY()
};
```

超过两个参数的函数必须说明每个参数。有返回值的函数必须说明返回值含义。

```cpp
/**
 * 应用属性值约束。
 *
 * @param SourceValue 原始属性值。
 * @param MinValue 当前允许的最小值。
 * @param MaxValue 当前允许的最大值。
 * @return 返回约束后的属性值。
 */
UFUNCTION(BlueprintCallable, Category = "TireflyCombatSystem|Attribute")
float ClampAttributeValue(float SourceValue, float MinValue, float MaxValue) const;
```

## 枚举风格

反射枚举使用 `UENUM(BlueprintType)`、`enum class`、显式 `uint8`、带前缀枚举值、显式整数值、同一行 `UMETA`。

```cpp
// 属性范围类型
UENUM(BlueprintType)
enum class ETcsAttributeRangeType : uint8
{
    ART_None = 0 UMETA(DisplayName = "无", ToolTip = "属性值范围的一侧（最小值或最大值）没有限制"),
    ART_Static = 1 UMETA(DisplayName = "静态", ToolTip = "属性值范围的一侧（最小值或最大值）是一个恒定的数值"),
    ART_Dynamic = 2 UMETA(DisplayName = "动态", ToolTip = "属性值范围的一侧（最小值或最大值）是动态的，受另一个属性值的影响"),
};
```

如果附近已有枚举值对齐方式，保留附近风格，不要只为了对齐重排整段代码。

## 结构体风格

反射结构体使用 `USTRUCT(BlueprintType)`。需要跨模块导出时，在结构体名前使用模块 API 宏。

```cpp
// 属性范围
USTRUCT(BlueprintType)
struct TIREFLYCOMBATSYSTEM_API FTcsAttributeRange
{
    GENERATED_BODY()

// 属性的最小值范围设置
#pragma region MinValue

public:
    // 最小值类型
    UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Min Value")
    ETcsAttributeRangeType MinValueType = ETcsAttributeRangeType::ART_None;

#pragma endregion
};
```

## 类风格

类名遵循 Unreal 前缀。`GENERATED_BODY()` 放在左大括号后的第一段内容。

```cpp
/**
 * 属性定义资产
 */
UCLASS(BlueprintType, Const)
class TIREFLYCOMBATSYSTEM_API UTcsAttributeDefinition : public UPrimaryDataAsset
{
    GENERATED_BODY()

// PrimaryDataAsset 相关内容
#pragma region PrimaryDataAsset

public:
    // 构造函数：设置默认 Clamp 策略
    UTcsAttributeDefinition();

    // 覆写 GetPrimaryAssetId
    virtual FPrimaryAssetId GetPrimaryAssetId() const override;

#pragma endregion
};
```

## 命名规则

遵循 Unreal 命名约定和模块前缀。

```cpp
ETcsAttributeRangeType RangeType;       // E 前缀：枚举类型
FTcsAttributeRange AttributeRange;      // F 前缀：结构体类型
UTcsAttributeDefinition* Definition;    // U 前缀：UObject 类型
bool bShowInUI = true;                  // bool 使用 b 前缀
```

属性和函数使用 PascalCase。

```cpp
FName AttributeDefId;
FGameplayTag AttributeTag;
TArray<FName> GetOtherAttributeDefIds() const;
```

`FName` 默认值使用 `NAME_None`，浮点默认值使用 `.f`。

```cpp
FName MinValueAttribute = NAME_None;
float MinValue = 0.f;
```

## UPROPERTY 风格

注释紧贴 `UPROPERTY` 前方，然后是反射声明，再是变量声明。

```cpp
/**
 * 属性类别
 */
UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Gameplay Tags")
FString AttributeCategory;
```

短 metadata 保持单行。

```cpp
UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Range")
FTcsAttributeRange AttributeRange;
```

较长 metadata 中，`Meta = (...)` 放第一行，其余 specifier 换到下一行。

```cpp
/**
 * 属性名（最好使用 StringTable）
 */
UPROPERTY(Meta = (EditCondition = "bShowInUI", EditConditionHides),
    EditAnywhere, BlueprintReadOnly, Category = "Display")
FText AttributeName;
```

很长的 Tooltip 可以让 `Meta` 单独换行，并匹配附近续行缩进。

```cpp
/**
 * Clamp 策略类（默认使用线性 Clamp 策略）
 */
UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Range",
          Meta = (ToolTip = "属性值的约束策略。默认使用线性约束（FMath::Clamp）。可以选择其他内置策略或自定义策略（C++ 或蓝图）。"))
TSubclassOf<class UTcsAttributeClampStrategy> ClampStrategyClass;
```

## UFUNCTION 风格

Blueprint 可调用 API 使用明确的模块路径 Category。

```cpp
/**
 * 获取可供动态范围引用的其他属性 ID 列表。
 *
 * 用途：为编辑器 `GetOptions` 提供上下文化选项源，自动排除当前资产自己的 `AttributeDefId`。
 * @return 返回可引用的其他属性定义 ID 列表。
 */
UFUNCTION(BlueprintCallable, CallInEditor, Category = "TireflyCombatSystem|Attribute|Editor")
TArray<FName> GetOtherAttributeDefIds() const;
```

## Editor-only 代码

Editor-only include、声明和实现都使用 `#if WITH_EDITOR` 包裹。

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

实现文件 include 示例：

```cpp
#if WITH_EDITOR
#include "Misc/DataValidation.h"
#endif
```

实现文件函数示例：

```cpp
#if WITH_EDITOR
void UTcsAttributeDefinition::PostEditChangeProperty(FPropertyChangedEvent& PropertyChangedEvent)
{
    Super::PostEditChangeProperty(PropertyChangedEvent);
}


EDataValidationResult UTcsAttributeDefinition::IsDataValid(FDataValidationContext& Context) const
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

`.cpp` 内部辅助函数放在匿名 namespace 中。匿名 namespace 通常放在静态变量定义之后、正式成员函数实现之前。

```cpp
// 内部函数：如果 SelfAttributeDefId 不为空，则检查 AttributeRange 是否有 SelfAttributeDefId 的引用，如果有，则清空引用
namespace
{
    bool IsAbstractClampStrategyClass(const UClass* StrategyClass)
    {
        return StrategyClass && StrategyClass->HasAnyClassFlags(CLASS_Abstract);
    }


    void SanitizeSelfReferencedRange(FTcsAttributeRange& AttributeRange, const FName SelfAttributeDefId)
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

```cpp
UTcsAttributeDefinition::UTcsAttributeDefinition()
{
    // 设置默认 Clamp 策略
    ClampStrategyClass = UTcsAttrClampStrategy_Linear::StaticClass();
}
```

验证逻辑示例：

```cpp
void UTcsAttributeDefinition::PostEditChangeProperty(FPropertyChangedEvent& PropertyChangedEvent)
{
    Super::PostEditChangeProperty(PropertyChangedEvent);

    const FName PropertyName = PropertyChangedEvent.GetPropertyName();

    // 验证 AttributeRange（静态类型时，确保 MinValue <= MaxValue）
    if (PropertyName == GET_MEMBER_NAME_CHECKED(UTcsAttributeDefinition, AttributeRange))
    {
        if (AttributeRange.MinValueType == ETcsAttributeRangeType::ART_Static &&
            AttributeRange.MaxValueType == ETcsAttributeRangeType::ART_Static)
        {
            if (AttributeRange.MinValue > AttributeRange.MaxValue)
            {
                const float Temp = AttributeRange.MinValue;
                AttributeRange.MinValue = AttributeRange.MaxValue;
                AttributeRange.MaxValue = Temp;
            }
        }
    }
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
EDataValidationResult UTcsAttributeDefinition::IsDataValid(FDataValidationContext& Context) const
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

## 反射可见性

如果 API 要给 Blueprint 或 UnrealSharp 使用，必须确认它对 Unreal 反射可见。

可见示例：

```cpp
UFUNCTION(BlueprintCallable, Category = "TireflyCombatSystem|Attribute")
float GetCurrentValue() const;
```

不可见示例：

```cpp
float GetCurrentValue() const;
```

如果涉及 UnrealSharp C# 使用，必须先加载 UnrealSharp 工作流 Skill，并确认目标 API 已经通过反射生成到 Glue。

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

## 编辑完成前检查

完成 UE5 C++ 编辑前检查以下事项：

- `.h` 文件 include 顺序正确，`.generated.h` 位于最后。
- `.h` 和 `.cpp` 中的 Editor-only include 都用 `#if WITH_EDITOR` 单独包裹。
- 新增反射类、结构体、枚举、委托、属性、函数有必要注释。
- `#pragma region` 只出现在 `.h` 文件中。
- `.cpp` 文件按函数顺序平铺组织，不使用 region。
- Editor-only 声明和实现被 `#if WITH_EDITOR` 包裹。
- Blueprint 或 UnrealSharp 需要访问的 API 使用了正确的 `UFUNCTION` / `UPROPERTY`。
- 改动保持局部，不重排无关代码。
