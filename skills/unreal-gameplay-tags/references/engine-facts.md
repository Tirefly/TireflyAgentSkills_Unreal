# 引擎机制事实与坑

行号前缀：`GT/` = `Engine/Source/Runtime/GameplayTags/`。全部结论基于本机 UE 5.8.0 源码；与官方文档措辞冲突时以源码为准。

## 构建顺序（最重要的单条事实）

`UGameplayTagsManager::ConstructGameplayTagTree`（`GT/Private/GameplayTagsManager.cpp:610-693`）的装配顺序是固定的：

| 序 | 来源 | 位置 | 说明 |
|---|---|---|---|
| 1 | **Restricted tag 源** | `:620-632` | 受 `ShouldImportTagsFromINI()` 门控；文件列表**排序**后加载（`:626`），以"前缀"身份先入树 |
| 2 | **Native tag** | `:634-647` | 源码注释原文 `"Add native tags before other tags"`；先 `LegacyNativeTags` 再 `FNativeGameplayTag::GetRegisteredNativeTags()` |
| 3 | **DataTable tag** | `:649-658` | `PopulateTreeFromDataTable` |
| 4 | **INI tag** | `:663-692` | 受 `ShouldImportTagsFromINI()` 门控；先 `Default->GameplayTagList`（`:676-679`），再 `Config/Tags/` 搜索路径（`:682-683`） |

**推论（实用判据）**：**原生是唯一"编译期就有符号、且早于 DataTable/ini 进树"的机制。** 凡需要编译期常量、或需要在早期阶段可查的词，只能走原生。

## 两段式注册与顺序不确定性

`FNativeGameplayTag` 的构造是两段式的（`GT/Private/NativeGameplayTags.cpp:71-76`）：

```cpp
GetRegisteredNativeTags().Add(this);                       // 先进待注册表
if (UGameplayTagsManager* Manager = UGameplayTagsManager::GetIfAllocated())
{
	Manager->AddNativeGameplayTag(this);                   // 管理器已存在才立即注册
}
```

即：模块静态构造期若 `UGameplayTagsManager` 尚未创建，只进待注册表；等管理器建树时（构建顺序第 2 步）再补注册。

**引擎自证注册顺序不确定**——`ClearInvalidTags` 的弃用注释（`GT/Classes/GameplayTagsSettings.h:115-117`）：

> `UE_DEPRECATED(5.5, "We never clear invalid tags when reading saved tag references as the loading order of native tags is not guaranteed.")`

⇒ **不得假设"我的原生 tag 一定早于别人的"**。

**注册的生命周期**：每个 `FNativeGameplayTag` 随模块卸载而注销，且"**按指针**分别注册"——两个模块声明同一 tag 文本时，卸载其中一个，另一个仍然注册着（`GT/Public/NativeGameplayTags.h:52-56` 类注释）。这就是"原生侧重复声明不会报错"的机制来源。

## 可用时机禁区

综合构建顺序与两段式注册，以下三处**不得**依赖"tag 已可查"（MUST NOT）：

1. **模块静态初始化期**——管理器可能还没创建
2. **`StartupModule` 期**——ini 可能尚未加载；原生 tag 是否已进树也不保证
3. **任何早于 tag 表加载的时机**

**安全起点**：GameInstance 级（如 `UGameInstanceSubsystem::Initialize`）或更晚。

**规模事实（Shipping 差异）**：`PluginName` / `ModuleName` / `ModulePackageName` / 校验状态只在 `!UE_BUILD_SHIPPING` 下存在（`GT/Public/NativeGameplayTags.h:97-104`），`DeveloperComment` 只在 `WITH_EDITORONLY_DATA` 下存在（`:106-108`），元数据访问器受 `UE_INCLUDE_NATIVE_GAMEPLAYTAG_METADATA`（默认 `WITH_EDITOR && !UE_BUILD_SHIPPING`，`:48-50`）门控，注册校验 `ValidateTagRegistration()` 也只在非 Shipping 跑（`:73-75`）。⇒ **同一份代码在编辑器与 Shipping 下的可诊断性不同**，别把校验当运行时保证。

## 查询与缓存

**`RequestGameplayTag` 内部加锁**（`GT/Private/GameplayTagsManager.cpp:2372` 函数定义，`:2378` `UE::TScopeLock Lock(GameplayTagMapCritical)`）。

⇒ **热路径不得逐次按名解析（MUST）**；按名解析的结果必须缓存。缓存后与直接用原生常量等价——`FGameplayTag` 内部就是一个 `FName`。

**优先级**：原生常量 > 缓存过的解析结果 > 逐次 `RequestGameplayTag`。

**相关**：`RequestGameplayTagContainer`（`:2360`）、`RequestGameplayTagParents`（`:2771`）、`RequestGameplayTagChildren`（`:2847`）等查询同样带锁（各自 `TScopeLock`）。

**"拼错即报错"的真实边界（重要坑）**：`RequestGameplayTag(..., ErrorIfNotFound=true)` 的 ensure **只在词完全不存在时**触发。但**中间节点会被自动补齐**（见下），所以**把叶子词的末段写漏，会成功解析到一个"隐式父节点"**——不报错、静默降级。

```text
已声明:  <Ns>.<域>.Damage.Physical
拼成:    <Ns>.<域>.Damage          ← 解析成功（隐式父节点），零告警
```

⇒ 校验脚本要能区分"显式声明"与"隐式父节点"，否则这个降级面查不出来。

## 父节点语义

tag 文本按 `.` 切分建树（`GT/Private/GameplayTagsManager.cpp:1250` 注释原文 "Split the tag text on the '.' delimiter to establish tag depth and then insert each tag into the gameplay tag tree"）。装配时逐段 push 父节点：

- `:1317` `const bool bIsExplicitTag = CurrentFullTag.Len() == FullTagView.Len();`——**只有完整路径那一段是"显式"的**，中间段 `bIsExplicitTag = false`
- `:1334-1341` 把 `{ShortTagName, FullTagName, bIsExplicitTag}` 压入 `RequiredTags`
- 非编辑构建有一条提前退出优化（`:1321-1332`，`#if !WITH_EDITOR`）：已存在的非显式节点直接 break

**后果**：一个 tag 可以"存在"却从未被声明过。因此：

- 按父 tag 做的**容器包含判断**（`HasTag`）会命中子 tag——层级匹配语义
- 按父 tag 做的**精确判断**（`HasTagExact`）不会命中
- 按父 tag **订阅/注册**时，要先明确要的是"精确等于"还是"包含"——**这是订阅面最常出错的地方**

## 字符约束

引擎硬黑名单 `InvalidTagCharacters` 默认值 = `"` `'` `,`（`GT/Private/GameplayTagsSettings.cpp:70`：`InvalidTagCharacters = ("\"',");`），管理器另追加 `\r\n\t`（`GT/Private/GameplayTagsManager.cpp:617`）。

校验函数 `UE::GameplayTags::Private::IsValidGameplayTagString`（`:2433`），内部走 `FName::IsValidXName`（`:2508`）。

**编辑器期行为**（`:1255-1279`，`#if WITH_EDITOR`）：非法 tag 会**尝试修复**并打 Error 级日志——能修则替换，不能修则**直接丢弃该 tag**：

- `:1267` `"Invalid tag %ls from source %ls: %ls!"`（无法修复，丢弃）
- `:1272` `"Invalid tag %ls from source %ls: %ls! Replacing with %ls, you may need to modify InvalidTagCharacters"`（修复后替换）

⇒ **点与下划线引擎并不禁止**——本规范禁下划线是**约定**，不是引擎限制（见 [taxonomy.md](taxonomy.md)）。反过来，含 `"` `'` `,` 的 tag 在编辑器里会被静默改写或丢弃，这才是硬线。

## 跨模块链接

`UE_DECLARE_GAMEPLAY_TAG_EXTERN` 展开为裸 `extern`，**无 `dllexport`**（`GT/Public/NativeGameplayTags.h:31`），跨模块引用该变量报 **LNK2001**。

tag 专属的写法规则（手写模块导出宏）在 [authoring.md](authoring.md)「模块导出宏」。**通用原理**（"公共调用面符号要不要带导出宏"，适用于任何非内联符号）本体住在 `unreal-development-workflow` 的「引擎机制事实」节，本文不复制。

## 悬空引用捕获

`WarnOnInvalidTags`（`GT/Classes/GameplayTagsSettings.h:111-113`）：

> "If true, will give load warnings when reading in saved tag references that are not in the dictionary"

⇒ 这是**删除/改名 tag 之后，资产里残留的旧引用**的官方捕获机制。启用它，然后在**加载一遍全部内容资产**之后看 `LogGameplayTags` 的 Warning。

配套：`AllowEditorTagUnloading` / `AllowGameTagUnloading`（`:119-125`）控制"插件被移除时是否允许卸载 tag"——与"验证模块不进 Shipping"这类场景相关（**tag 条目本身不会因为 Shipping 而被裁掉**，见下）。

**易误解的一点**：引擎**没有**"让 ini 里的 tag 不进 Shipping 构建"的开关。`Allow*TagUnloading` 管的是**插件卸载时的 tag 注销**，不是构建裁剪。所以"验证词只用于非 Shipping"的正确抓手是**消费代码所在的模块**（验证装置放不进 Shipping 的模块，或 `#if !UE_BUILD_SHIPPING`），不是 tag 的存放位置。

## 升级检查清单（引擎升级时按此核对）

1. `ConstructGameplayTagTree` 的**四段构建顺序**是否变化（`GameplayTagsManager.cpp` 约 `:610-693`）
2. `FNativeGameplayTag` 的**两段式注册**与"按指针注册"语义是否变化（`NativeGameplayTags.cpp` / `NativeGameplayTags.h:52-56`）
3. `UE_DECLARE_GAMEPLAY_TAG_EXTERN` 是否**补上了 `dllexport`**（`NativeGameplayTags.h:31`）——补上了则 [authoring.md](authoring.md) 的手写导出宏规则可简化
4. 中间节点是否仍 `bIsExplicitTag = false`（`GameplayTagsManager.cpp:1317`）
5. `InvalidTagCharacters` 默认值（`GameplayTagsSettings.cpp:70`）
6. `RequestGameplayTag` 是否仍加锁（`GameplayTagsManager.cpp:2378`）
7. `FGameplayTagRedirect` 的"已弃用位置"警告是否变化（`GameplayTagRedirectors.cpp:56`）
8. `FRestrictedGameplayTagTableRow::bAllowNonRestrictedChildren` 默认值是否仍为 `false`（`GameplayTagsManager.h:73`）
9. `GameplayTagTableList` 的异步加载分支（`GameplayTagsManager.cpp:385-396`）
10. 各类配置键是否改名：`ImportTagsFromConfig` / `WarnOnInvalidTags` / `RestrictedConfigFiles` / `GameplayTagTableList` / `CategoryRemapping` / `GameplayTagRedirects`
