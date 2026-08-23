# 反射类型与声明规则

本文件覆盖 UENUM、USTRUCT、UCLASS、UPROPERTY、UFUNCTION 的声明风格、注释选择、命名约定、Category 与 region 的关系、反射声明换行规则。

## 目录

- [注释选择规则](#注释选择规则)
- [枚举风格](#枚举风格)
- [结构体风格](#结构体风格)
- [类风格](#类风格)
- [命名规则](#命名规则)
- [策略族命名](#策略族命名)
- [Category 与 Region 的关系](#category-与-region-的关系)
- [反射声明换行风格](#反射声明换行风格)
- [UFUNCTION 风格](#ufunction-风格)
- [反射可见性](#反射可见性)

---

## 注释选择规则

使用中文注释。按注释复杂度选择形式，不按 struct/class 选择。

**一句话能说清** → 用 `//`：

```cpp
// 最小值类型
UPROPERTY(...)
ETcsAttributeRangeType MinValueType = ETcsAttributeRangeType::ART_None;
```

**需要多行展开用途、约束、示例、语义** → 用 `/** */`：

```cpp
/**
 * 属性的唯一标识符
 * 对应原 DataTable 的 RowName
 */
UPROPERTY(...)
FName AttributeDefId;
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

枚举值前缀规则：取枚举名的缩写，全大写 + 下划线结尾。例如 `ETcsAttributeRangeType` → `ART_`、`ETcsCombatMode` → `CM_`。

`UMETA` 必须同时带 `DisplayName` 和 `ToolTip`，`DisplayName` 是编辑器显示的友好名，`ToolTip` 是悬停说明。两者都不能省略。

```cpp
// 属性范围类型
UENUM(BlueprintType)
enum class ETcsAttributeRangeType : uint8
{
	// 前缀 ART_ 是 AttributeRangeType 的缩写
	ART_None  = 0		UMETA(DisplayName = "无", ToolTip = "属性值范围的一侧（最小值或最大值）没有限制"),
	ART_Static = 1		UMETA(DisplayName = "静态", ToolTip = "属性值范围的一侧（最小值或最大值）是一个恒定的数值"),
	ART_Dynamic = 2		UMETA(DisplayName = "动态", ToolTip = "属性值范围的一侧（最小值或最大值）是动态的，受另一个属性值的影响"),
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

public:
	/**
	 * PrimaryAssetType 标识符
	 */
	static const FPrimaryAssetType PrimaryAssetType;

#pragma endregion
};
```

覆写虚函数时，`virtual` 和 `override` 都保留：

```cpp
virtual FPrimaryAssetId GetPrimaryAssetId() const override;
virtual void PostEditChangeProperty(FPropertyChangedEvent& PropertyChangedEvent) override;
```

## 命名规则

遵循 Unreal 命名约定和模块前缀。

```cpp
ETcsAttributeRangeType RangeType;       // E 前缀：枚举类型
FTcsAttributeRange AttributeRange;      // F 前缀：结构体类型
UTcsAttributeDefinition* Definition;    // U 前缀：UObject 类型
bool bShowInUI = true;                  // bool 使用 b 前缀
```

属性和函数使用 PascalCase。`FName` 默认值使用 `NAME_None`，浮点默认值使用 `.f`。

```cpp
FName MinValueAttribute = NAME_None;
float MinValue = 0.f;
```

## 策略族命名

一个职责族由「族基类 + 多个具体策略」组成时（如 Clamp 策略、Modifier 合并器、Operand Evaluator），遵循以下模式：

- **族基类**使用描述性全名：`TcsAttribute<族名>`（如 `TcsAttributeModifierOperandEvaluator`、`TcsAttributeModifierMerger`、`TcsAttributeClampStrategy`）。
- **具体策略文件与类型**使用 `TcsAttr<族缩写>_<策略名>`：族缩写取族职责的短缩写（如 `ModOpEvaluator`、`ModMerger`、`ClampStrategy`），全族一致，避免每个具体文件复制完整基类长名。
- **具体策略类型名与文件基名一致**：`TcsAttrModOpEvaluator_Constant.h` 声明 `UTcsAttrModOpEvaluator_Constant`。
- **同族附属数据类型**（Payload、Context、枚举）可使用更短的域级缩写，前后缀位置统一：如 Payload 用 `FTcsAttrOpPayload_<类型>`（`FTcsAttrOpPayload_Constant`），来源枚举用 `ETcsAttrOp<域>_<子域>`（`ETcsAttrOpSource_StateParam`，值前缀 `AOSSP_` 按枚举缩写规则）。

```cpp
// 族基类：描述性全名
// Attribute/AttrModOperand/TcsAttributeModifierOperandEvaluator.h
class UTcsAttributeModifierNumericEvaluator : public UObject { ... };

// 具体策略：族缩写 + 策略名，类型名与文件基名一致
// Attribute/AttrModOperand/TcsAttrModOpEvaluator_Constant.h
class UTcsAttrModOpEvaluator_Constant : public UTcsAttributeModifierNumericEvaluator { ... };

// 同族附属数据类型：更短的域级缩写，前后缀位置统一
struct FTcsAttrOpPayload_Constant : public FTcsAttributeOperandPayload { ... };
```

族缩写选择要点：短、可读、能区分职责；同一族内的文件与主策略类型保持一致缩写，附属类型可用更短缩写但前缀语义要可辨。该模式与 TCS OpenSpec 的 `runtime-module-file-layout` 文件布局约定一致。

## Category 与 Region 的关系

同一个 region 内的 UPROPERTY Category 应与该 region 的语义对齐。可以是字面对应、语义别名、或带空格的友好名。若需细分，可使用子 Category。API 函数可使用模块路径式 Category（`Module|Sub|Feature`）。

```cpp
// region 名是 MinValue，Category 与语义对齐
#pragma region MinValue

public:
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Min Value")
	ETcsAttributeRangeType MinValueType = ETcsAttributeRangeType::ART_None;

#pragma endregion
```

```cpp
// region 名是 Editor，UFUNCTION 用模块路径式 Category
#pragma region Editor

public:
	UFUNCTION(BlueprintCallable, CallInEditor, Category = "TireflyCombatSystem|Attribute|Editor")
	TArray<FName> GetOtherAttributeDefIds() const;

#pragma endregion
```

## 反射声明换行风格

以下规则同时适用于 `UPROPERTY` 和 `UFUNCTION`。

注释紧贴反射声明前方，然后是反射声明，再是变量或函数声明。

**Specifier 顺序规则**：非 Meta specifier 放在前面，Meta 相关内容放在后面。非 Meta specifier 包括 `EditAnywhere`、`BlueprintReadOnly`、`BlueprintCallable`、`Category`、`CallInEditor`、`GetOptions` 等。Meta 相关内容指 `Meta = (...)` 及其内部子项。

**换行规则**：优先让非 Meta specifier 在同一行；如果单行太长，则换行，续行缩进 +1 Tab。Meta 相关内容放在非 Meta 之后；如果 Meta 太长，`Meta = (...)` 整体换行，缩进 +1 Tab；如果 `Meta` 内部子项仍然太长，子项继续换行，缩进 +2 Tab。

短声明保持单行：

```cpp
UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Range")
FTcsAttributeRange AttributeRange;
```

```cpp
UFUNCTION(BlueprintCallable, Category = "TireflyCombatSystem|Attribute")
float GetCurrentValue() const;
```

中等长度，`Meta` 整体换行，缩进 +1 Tab：

```cpp
UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "UI Display", 
	Meta = (EditCondition = "bShowInUI", EditConditionHides))
FText AttributeName;
```

`Meta` 内含多个子项且较长时，子项继续换行，缩进 +2 Tab：

```cpp
UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Min Value", 
	Meta = (EditCondition = "MinValueType == ETcsAttributeRangeType::ART_Dynamic", EditConditionHides, 
		GetOptions = "GetOtherAttributeDefIds"))
FName MinValueAttribute = NAME_None;
```

错误写法（`Meta` 放第一行，非 Meta 放后面）：

```cpp
// 错误
UPROPERTY(Meta = (EditCondition = "bShowInUI", EditConditionHides),
	EditAnywhere, BlueprintReadOnly, Category = "UI Display")
FText AttributeName;
```

## UFUNCTION 风格

Blueprint 可调用 API 使用明确的模块路径式 Category。

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
