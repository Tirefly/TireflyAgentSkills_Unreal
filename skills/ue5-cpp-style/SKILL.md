---
name: ue5-cpp-style
description: UE5 C++ 编码风格指南。用于创建、修改、审查或格式化 Unreal Engine C++ 文件，包括 .h、.cpp、.Build.cs、UCLASS/USTRUCT/UENUM、UPROPERTY/UFUNCTION、Editor-only 代码、Unreal 模块代码、Gameplay 插件 C++ 代码。编辑 UE5 C++ 前使用此 Skill，以匹配 Tirefly 风格的文件组织、注释、空行、region、访问域、命名、反射宏和实现文件布局。
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
- 统一使用 Tab 缩进，不使用空格缩进。
- 文件编码统一使用 UTF-8 无签名（UTF-8 without BOM），换行符统一使用 LF（Unix 风格，`\n`）。

## 按任务类型加载参考文档

根据当前编辑任务，读取对应的 reference 文件获取详细规则和代码示例。如果任务涉及多个方面，全部读取。

| 任务场景 | 读取文件 | 覆盖内容 |
|----------|----------|----------|
| 新建或编辑 `.h` / `.cpp` 文件 | [references/structure.md](references/structure.md) | 缩进、文件头、include 顺序、空行规则、region、访问域、GENERATED_BODY 模板 |
| 声明或修改反射类型（UENUM/USTRUCT/UCLASS/UPROPERTY/UFUNCTION） | [references/reflection.md](references/reflection.md) | 注释选择、枚举/结构体/类风格、命名、Category 与 region、反射声明换行、反射可见性 |
| 编写函数实现、Editor-only 代码、数据验证、Build.cs | [references/implementation.md](references/implementation.md) | Editor-only、静态成员、匿名 namespace、函数实现参数换行、条件换行、数据验证、Build.cs |

### 何时读哪个文件

- **创建新文件**：三个文件全部读取，因为涉及结构、反射声明、实现布局。
- **只改 `.h` 声明**：读 structure.md + reflection.md。
- **只改 `.cpp` 实现**：读 structure.md（空行和 include 规则）+ implementation.md。
- **只改 `.Build.cs`**：读 implementation.md 的 Build.cs 章节。
- **审查代码风格**：三个文件全部读取。

## 快速检查清单

完成 UE5 C++ 编辑前，确认以下事项：

**结构层面**（详见 structure.md）

- [ ] 文件编码为 UTF-8 无签名（无 BOM）。
- [ ] 换行符为 LF。
- [ ] 统一使用 Tab 缩进，不使用空格缩进。
- [ ] `.h` 文件 include 顺序正确，`.generated.h` 位于最后。
- [ ] `.h` 和 `.cpp` 中的 Editor-only include 都用 `#if WITH_EDITOR` 单独包裹。
- [ ] `#pragma region` 只出现在 `.h` 文件中。
- [ ] 每个 region 都重新声明了自己的访问域。
- [ ] 同一 region 内函数组和变量组用各自的访问域声明分隔。
- [ ] region 前有中文注释标题。
- [ ] 空行规则：版权/include 间 1 空行、region 间 2 空行、顶级段落间 3 空行、`.cpp` 函数间 1 空行。

**反射层面**（详见 reflection.md）

- [ ] 新增反射类、结构体、枚举、委托、属性、函数有必要注释。
- [ ] 枚举值前缀是枚举名缩写全大写（如 `ETcsAttributeRangeType` → `ART_`）。
- [ ] `UMETA` 同时带 `DisplayName` 和 `ToolTip`。
- [ ] UPROPERTY/UFUNCTION 非 Meta specifier 在前、`Meta` 在后，续行用 Tab 缩进。
- [ ] 覆写虚函数同时保留 `virtual` 和 `override`。
- [ ] Blueprint 或 UnrealSharp 需要访问的 API 使用了正确的 `UFUNCTION` / `UPROPERTY`。

**实现层面**（详见 implementation.md）

- [ ] `.cpp` 文件按函数顺序平铺组织，函数间 1 空行，不使用 region。
- [ ] 多参数函数实现时参数全部换行，缩进 +1 Tab。
- [ ] Editor-only 声明和实现被 `#if WITH_EDITOR` 包裹，`#endif` 紧贴最后的 `}`。
- [ ] 改动保持局部，不重排无关代码。
