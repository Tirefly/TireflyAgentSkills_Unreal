# 文件组织与排版规则

本文件覆盖 `.h` 和 `.cpp` 的物理组织规则：缩进、文件头、include 顺序、空行、region、访问域。

## 目录

- [缩进](#缩进)
- [文件头](#文件头)
- [头文件 Include 顺序](#头文件-include-顺序)
- [Cpp Include 顺序](#cpp-include-顺序)
- [空行规则](#空行规则)
- [头文件 Region](#头文件-region)
- [GENERATED_BODY 后模板](#generated_body-后模板)
- [Cpp 文件不使用 Region](#cpp-文件不使用-region)
- [访问域规则](#访问域规则)

---

## 缩进

统一使用 **Tab** 缩进，不使用空格缩进。所有层级（类成员、函数体、`public:`、region 内部、续行）都使用 Tab。

```cpp
class UTcsAttributeDefinition : public UPrimaryDataAsset
{
	GENERATED_BODY()

public:
	// 构造函数
	UTcsAttributeDefinition();
};
```

续行缩进相对上一行再 +1 个 Tab：

```cpp
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "UI Display", 
		Meta = (EditCondition = "bShowInUI", EditConditionHides))
	FText AttributeName;
```

不要用空格对齐括号或续行：

```cpp
// 错误：用空格对齐到 (
UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Range",
          Meta = (ToolTip = "..."))
```

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

`#pragma once` 后也空一行，再开始 include：

```cpp
// Copyright Tirefly. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
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

不要把 Editor-only include 混在普通 include 中。

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

## 空行规则

空行用于表达代码结构层级。保持已有文件中清晰的纵向间隔。

- 版权声明、`#pragma once`、include 之间使用 1 个空行。
- 同一函数或同一 region 内，相关但独立的小块之间使用 1 个空行。
- `.cpp` 中函数定义之间使用 1 个空行。
- 匿名 namespace 内函数之间使用 1 个空行。
- 头文件 region 之间使用 2 个空行（struct 和 class 一致，无差异）。
- 文件顶级大段之间使用 3 个空行。

文件顶级段落包括：include、枚举、结构体、类、`.cpp` 中的静态变量定义、匿名 namespace、成员函数实现开始。

顶级结构示例（`.h`）：

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

顶级结构示例（`.cpp`）：

```cpp
#if WITH_EDITOR
#include "Misc/DataValidation.h"
#endif



// 定义 PrimaryAssetType 静态变量
const FPrimaryAssetType UTcsAttributeDefinition::PrimaryAssetType = FPrimaryAssetType("TcsAttributeDef");



// 内部函数
namespace
{
	bool IsAbstractClampStrategyClass(const UClass* StrategyClass)
	{
		return StrategyClass && StrategyClass->HasAnyClassFlags(CLASS_Abstract);
	}
}
```

`.cpp` 函数定义之间使用 1 个空行。匿名 namespace 内函数之间也使用 1 个空行。

## 头文件 Region

`#pragma region` 只用于 `.h` 文件。每个 region 前必须有中文注释说明该区域的语义，默认使用单行注释，如有必要可使用多行注释块。

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

相邻 region 之间使用 2 个空行。struct 和 class 一致，无差异。

## GENERATED_BODY 后模板

`GENERATED_BODY()` 后到第一个 region 之间遵循固定结构：

```
GENERATED_BODY()
(1 空行)
// 中文注释
#pragma region XXX
(1 空行，带缩进)
public:
```

```cpp
struct TIREFLYCOMBATSYSTEM_API FTcsAttributeRange
{
	GENERATED_BODY()

// 属性的最小值范围设置
#pragma region MinValue
	
public:
	// 最小值类型
	UPROPERTY(...)
	ETcsAttributeRangeType MinValueType = ETcsAttributeRangeType::ART_None;

#pragma endregion
};
```

## Cpp 文件不使用 Region

`.cpp` 文件按函数顺序直接组织，不使用 `#pragma region`。

## 访问域规则

访问域声明（`public:`、`protected:`、`private:`）遵循两条规则。

**规则一：不同 region 之间访问域不继承。每个 region 必须重新声明自己的访问域。**

```cpp
// 正确：每个 region 都有自己的 public:
#pragma region Identity

public:
	UPROPERTY(...)
	FName AttributeDefId;

#pragma endregion


#pragma region Meta

public:                          // 重新声明，不继承上一个 region 的 public:
	UPROPERTY(...)
	FGameplayTag AttributeTag;

#pragma endregion
```

```cpp
// 错误：第二个 region 没有重新声明访问域
#pragma region Meta

	UPROPERTY(...)                   // 访问域不继承，这里会变成 private:
	FGameplayTag AttributeTag;

#pragma endregion
```

**规则二：同一 region 内，成员函数组和成员变量组即使访问域相同，也要各自单独声明访问域来分隔。**

```cpp
#pragma region PrimaryDataAsset

public:
	// 构造函数
	UTcsAttributeDefinition();

	// 覆写虚函数
	virtual FPrimaryAssetId GetPrimaryAssetId() const override;

public:                          // 同样是 public，但重新声明以分隔变量组
	static const FPrimaryAssetType PrimaryAssetType;

#pragma endregion
```
