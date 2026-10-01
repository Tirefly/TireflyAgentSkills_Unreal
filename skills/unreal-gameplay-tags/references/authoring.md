# 创建规则：声明位置与写法

行号前缀：`GT/` = `Engine/Source/Runtime/GameplayTags/`。

## 声明位置四分类（核心规则）

**判据 = 可用时机**：谁在什么阶段需要这个词，唯一地决定它放哪儿（MUST）。

| 类别 | 判据 | 声明位置 | 为什么不能换 |
|---|---|---|---|
| **契约词** | 框架对外广播/约定的词（事件名、对外契约键名） | **框架代码原生声明** | 跨模块消费者需要**编译期常量**；且契约词由宿主配置 ⇒ 宿主漏配即静默破坏框架广播面与订阅面的对应关系 |
| **框架默认内容** | 框架自带的内容实例（默认模板等） | **框架代码原生声明** | 漏配不可能发生。ini / DataTable 都可能漏（未 cook、未合并、被覆盖），原生不会 |
| **宿主内容** | 由项目内容规定含义的词（具体 id、属性名等） | **项目侧 ini**（`Config/DefaultGameplayTags.ini`） | 内容归宿主，编辑器可增删、不需重编译 |
| **验证词** | 仅被验证装置消费 | **`Probe.*` 根** + 非 Shipping 消费路径 | 见 [taxonomy.md](taxonomy.md)「临时验证词」 |

> **不是判据的两种说法**（避免踩）：
> - ❌ "框架语义 vs 项目内容"——边界词争不清（"生命值"是框架概念还是项目内容？），最终还得回落到"代码怎么引用它"。
> - ❌ "有没有 C++ 引用它"——`RequestGameplayTag(TEXT("..."))` 也是 C++ 引用，但那只是**运行期按名解析**，不需要编译期常量。

### 唯一声明处

**同一 tag 文本只能有一处声明（MUST）。** 跨声明源（原生 / ini / DataTable）不重名即可，但**一个 tag 文本不得出现在两处**。

注意：**原生侧的重复声明引擎不会报错**——`FNativeGameplayTag` 的注册"按指针分别进行"，两个模块声明同一 tag 文本时，卸载其中一个另一个仍然在（`GT/Public/NativeGameplayTags.h:52-56` 类注释）。即缺陷是**静默**的，只能靠规则与校验脚本拦。

ini / Restricted 侧的冲突则由编辑器标记（`GT/Private/GameplayTagsManager.cpp:1357-1389` 的 `bNodeHasConflict` / `bAncestorHasConflict` / `bDescendantHasConflict`，`#if WITH_EDITORONLY_DATA`）——**编辑器期**机制，运行时无感。

### 域所有权（SHOULD）

同一**域**（段 2）内的词尽量由同一侧声明，便于"这个词去哪儿找"有唯一答案。这是 SHOULD 而非 MUST：跨侧不重名并不致命，可枚举性靠项目侧词表注册表 + 校验脚本补。

## `DevComment` 要求

**每条词都必须有可读的语义说明（MUST）。**

- **ini 侧**：`+GameplayTagList=(Tag="...",DevComment="...")`
- **原生侧**：用 `UE_DEFINE_GAMEPLAY_TAG_COMMENT(TagName, Tag, Comment)` 而非 `UE_DEFINE_GAMEPLAY_TAG`（后者把 comment 写成空串，`GT/Public/NativeGameplayTags.h:36` vs `:41`）。原生 comment 只存在于 `WITH_EDITORONLY_DATA`（`:106-108`、`:77-81`），Shipping 下不占内存

`DevComment` 里写清三件事：**语义**、**谁声明/谁消费**、**退役判据**（验证词必填）。

## 原生 tag 写法

### 三个宏

| 宏 | 用途 | 可见性 |
|---|---|---|
| `UE_DEFINE_GAMEPLAY_TAG(TagName, Tag)` | 定义，comment 为空 | 本模块 + 显式 extern 声明方 |
| `UE_DEFINE_GAMEPLAY_TAG_COMMENT(TagName, Tag, Comment)` | 定义，带 comment | 同上 |
| `UE_DEFINE_GAMEPLAY_TAG_STATIC(TagName, Tag)` | 文件内私有 | 仅本 `.cpp` |
| `UE_DECLARE_GAMEPLAY_TAG_EXTERN(TagName)` | 声明 | 见下「导出宏」 |

**三个 DEFINE 宏都只能用在 `.cpp` 里**——引擎用 `static_assert(HasFileExtension(__FILE__), "... can only be used in .cpp files")` 强制（`GT/Public/NativeGameplayTags.h:18-25` 的守卫，`:36`/`:41`/`:46` 的断言）。想跨模块共享：在公开头 `UE_DECLARE_...`（或按下面手写导出声明），在私有 `.cpp` `UE_DEFINE_...`。

`FNativeGameplayTag` 有 `operator FGameplayTag()`（`:67`），可直接当 `FGameplayTag` 用。

### 模块导出宏（跨模块必读）

**`UE_DECLARE_GAMEPLAY_TAG_EXTERN` 展开为裸 `extern`，不带 `__declspec(dllexport)`**（`GT/Public/NativeGameplayTags.h:31` 宏本体一字不差）。跨模块引用该变量会 **LNK2001**。

因此：**凡设计意图是供其他模块/宿主使用的原生 tag，声明处必须手写带模块导出宏的声明（MUST）**：

```cpp
// 公开头里（不能用 UE_DECLARE_GAMEPLAY_TAG_EXTERN）
extern TCSXXX_API FNativeGameplayTag Tag_<根>_<子域>_<词>;

// 私有 .cpp 里零改动
UE_DEFINE_GAMEPLAY_TAG(Tag_<根>_<子域>_<词>, "<根>.<子域>.<词>");
```

定义处无需再写导出宏——定义 TU 见到 `dllexport` 声明即导出符号（前提是该 TU include 了声明头）。判据是"**设计意图是否供外部用**"，不是"现在有没有人用"。

> 「跨模块公共调用面符号要不要带导出宏」的**通用原理**（不止 tag）住在 `unreal-development-workflow` 的「引擎机制事实」节。

### 常量名与 tag 文本逐段对应

**常量名 = tag 文本按"点 → 下划线"逐段转换（MUST）**：

```cpp
// tag 文本            <机制>Key.<子域>.<词>
// 常量名              Tag_<机制>Key_<子域>_<词>
UE_DEFINE_GAMEPLAY_TAG(Tag_<机制>Key_<子域>_<词>, "<机制>Key.<子域>.<词>");
```

**宏的第二实参才是 tag 文本**，常量名叫什么都不影响层级——所以常量名可以骗人。这正是"段内禁下划线"（[taxonomy.md](taxonomy.md)）的配套规则：段内一旦有下划线，逐段对应关系就不可反推。引擎先例：`Mover.IsOnGround` ↔ `Mover_IsOnGround`。

## ini 与多文件

### 主词表

项目词表住 `<Project>/Config/DefaultGameplayTags.ini` 的 `[/Script/GameplayTags.GameplayTagsSettings]` 节：

```ini
+GameplayTagList=(Tag="<根>.<子域>.<词>",DevComment="语义 / 归属 / 退役判据")
```

编辑器内可直接改本文件，或用 Project Settings → GameplayTags 面板增删（面板写回本文件）。ini 相对 DataTable 的优势是**文本可合并、无需独占签出**（`GT/Classes/GameplayTagsSettings.h:88-101` 类注释）。

### 附加词表文件：`Config/Tags/`

引擎固定把 `<Project>/Config/Tags/` 作为 tag ini 搜索路径（`GT/Private/GameplayTagsManager.cpp:682-683`），并**递归**扫描该目录下全部 `*.ini`（`:432-448`，`FindFilesRecursive(..., TEXT("*.ini"), true, false)`）。

插件的 `Config` 目录同样参与：传入 `PluginConfigsCache` 时按根目录前缀过滤（`:451-460`），未传缓存时走文件系统递归（`:434-447`）。

**受 `ImportTagsFromConfig` 门控**（`GT/Classes/GameplayTagsSettings.h:107-109` 的 "If true, will import tags from ini files in the config/tags folder"；判定入口 `ShouldImportTagsFromINI()`，`GT/Private/GameplayTagsManager.cpp:620`/`:663`；访问器 `:900`）。

**两条硬约束**：

1. **tag source 名 = ini 文件名**（`:443`/`:456` 取 `FPaths::GetCleanFilename`）⇒ **文件名必须全局唯一**（与 UHT「全项目头文件名必须唯一」同一类约束）
2. 加载晚于原生（见 [engine-facts.md](engine-facts.md)「构建顺序」）⇒ 插件 `StartupModule` 期不得依赖这些词

**何时值得开第二个文件**：只有当某组词的数量/生命周期需要独立启停时才划算（例如整组验证词）。**一条词不值得为它引入一个文件**。

## DataTable 的定位

`GameplayTagTableList`（`GT/Classes/GameplayTagsSettings.h:143-145`，`TArray<FSoftObjectPath>` 指向 DataTable）是**合法机制**，`UCompositeDataTable` 也确实能组合子表。但要知道它的代价（`GT/Private/GameplayTagsManager.cpp:361-412`）：

- DataTable tag 是**资产**，cooked 构建里走异步加载（`:385-396` 的 `LoadPackageAsync`）⇒ tag 可用时机变成"资产加载完成与否"，**加剧**时序问题
- `uasset` 是二进制 ⇒ tag 内容的 diff / review 变难
- 它的价值在"**策划批量维护数据** + 热更"，**不在审批**

⇒ **不要为了"审批/驳回"引入 DataTable。** 要治理请看下节。

## Restricted GameplayTags（结构约束机制）

引擎内建了面向"**顶层 tag 由极少数人修改**"的治理机制，官方定位原文：

> Restricted tags are intended to be **top level tags** that are important for your data hierarchy and **modified by very few people**.
> —— `GT/Classes/GameplayTagsSettings.h:165-168`

| 能力 | 出处 |
|---|---|
| 受限 tag 文件清单 `RestrictedConfigFiles` | `GT/Classes/GameplayTagsSettings.h:159-161` |
| 每个受限文件独立，走 `<Project>/Config/Tags/<Name>` | `GT/Private/GameplayTagsManager.cpp:975`；声明处可来自任意已注册 ini（`:469-477`） |
| **每文件带 Owner 名单**，编辑器自动填当前用户名，可查询 | `FRestrictedConfigInfo{RestrictedConfigName, Owners}`（`GT/Classes/GameplayTagsSettings.h:72-86`）、`GT/Private/GameplayTagsSettings.cpp:129`、`GetOwnersForTagSource`（`GT/Private/GameplayTagsManager.cpp:1004-1018`） |
| 受限行 `FRestrictedGameplayTagTableRow` + `bAllowNonRestrictedChildren`（**默认 false**） | `GT/Classes/GameplayTagsManager.h:64-74`；读取 `GT/Private/GameplayTagsManager.cpp:1247`；落到节点 `:1521`/`:1542`；序列化进标志位 `:2218` |
| 不同 source 声明同一显式 tag → 编辑器标记冲突 | `GT/Private/GameplayTagsManager.cpp:1357-1389` |
| 受限源先于其他源进树 | `:620-632` |

**用法**：把一个根做成受限 tag（Owner = 少数人），`bAllowNonRestrictedChildren = true` 让开发者在它下面自由加词 ⇒ **根层受控、子层自由**，且是纯文本 ini、diff 友好。

### 三条硬边界（2026-10-01 实证补记，踩过才知道）

**① 受限行本身就是一次声明——不能用它"标注"别人的词。**
受限行经 `AddRestrictedGameplayTagSource` → `AddTagTableRow(..., true)` 进树，与其他源一样是**显式声明**。若该 tag 文本已被别处显式声明过（例如某个**原生 tag**），就是**重复声明**：引擎侧标冲突（`GT/Private/GameplayTagsManager.cpp:1509` 起，注释原文 *"If the existing tag is restricted we have a conflict. This is explicitly not allowed."*），校验脚本侧报 `A5-重复声明`（Error）。
⇒ 想把"某个词"标为受限，前提是那个词**此前没人显式声明过**。

**② UE 5.8 里原生 tag 物理上无法受限。**
`AddTagTableRow` 的第三参默认 `false`（`GT/Classes/GameplayTagsManager.h:903`），全库**唯一**传 `true` 的调用点是 `GameplayTagsManager.cpp:554`（受限 ini 加载路径）；四条原生路径 `:639` / `:645` / `:2621` / `:2634` **全部走 2 参**。`FNativeGameplayTag` / `UE_DEFINE_GAMEPLAY_TAG` 也没有任何受限入口。
⇒ **受限机制只能施加于 ini 声明的词。** 面对一批原生 tag，你唯一能设限的是它们**共同走过的隐式父节点**（例如 `Ns.Event` / `Ns.Flow.Key`——这些层级段没被任何人显式声明过，写上不算重复）。

**③ 拦截只在"显式声明过的祖先"上生效。**
编辑器的向上查找条件是 `IsDictionaryTag(AncestorTag)`（`GameplayTagsEditorModule.cpp:473`），而该 API 对**隐式父段返回 false**（`GameplayTagsManager.h:725` 原文：*"false for implicitly added parent tags"*）。
⇒ 设限时**必须把那个节点本身写成显式受限行**，否则 `bAllowNonRestrictedChildren=false` 写了也不生效（查找会直接跳过它）。

**推论（选型前先问）**：若一个命名空间里的词全部是原生声明的，且宿主/其他模块**有正当理由往它下面加自己的词**，那么受限机制在这里**无适用面**——节点档挡的是正当扩展，叶档物理不可用。此时对症的强制层是"归属规则（契约）+ 重复声明校验（脚本）"，而不是受限 tag。

**注意实施边界**：约束与冲突标记主要在**编辑器期**（`#if WITH_EDITORONLY_DATA`），标志位序列化供查询——它是**作者期治理**，不是运行时硬阻断。**审批本身走版本控制 + Code Review（+ 项目的契约层提案流程），不要在引擎里造第二套审批。**

**`bAllowNonRestrictedChildren` 的默认值是 `false`**（`GT/Classes/GameplayTagsManager.h:73`）——不显式打开就会禁止所有子 tag，这是最容易踩的一点。

## 改名与重定向

**改名一律登记 `FGameplayTagRedirect`（MUST）。**

```ini
+GameplayTagRedirects=(OldTagName="<根>.<子域>.<旧词>",NewTagName="<根>.<子域>.<新词>")
```

结构体 `FGameplayTagRedirect{OldTagName, NewTagName}`（`GT/Public/GameplayTagRedirectors.h:19`/`:27`/`:30`）；ini 键解析在 `GT/Private/GameplayTagRedirectors.cpp:32-45`。

### 写到哪里（2026-10-01 取证定论，取代此前的"位置警告"）

引擎自己的改名流程给出的规则在 `GameplayTagsEditorModule.cpp:925`：

```cpp
UGameplayTagsList* ListToUpdate = (OldTagSource && OldTagSource->SourceTagList)
    ? OldTagSource->SourceTagList.Get()
    : GetMutableDefault<UGameplayTagsSettings>();
ListToUpdate->GameplayTagRedirects.AddUnique(Redirect);
```

> **规则：redirect 写进"该 tag 所属列表所在的那个配置文件"。**

| 词的来源 | 写到哪 | ini 节名 |
|---|---|---|
| **原生 tag**（没有 TagList 源 → 走回落分支） | 项目 `Config/DefaultGameplayTags.ini` | `[/Script/GameplayTags.GameplayTagsSettings]` |
| `DefaultGameplayTags.ini` 里 `+GameplayTagList` 声明的词 | 同文件 | `[/Script/GameplayTags.GameplayTagsSettings]` |
| `Config/Tags/*.ini` 里声明的词 | **声明它的那个文件** | `[/Script/GameplayTags.GameplayTagsList]` |

类继承支撑：`UGameplayTagsSettings : public UGameplayTagsList`（`GT/Classes/GameplayTagsSettings.h:102-103`），而 `GameplayTagRedirects` 定义在基类 `UGameplayTagsList` 上（`:33-34`、`:44`）——所以两个节名都有这个数组。

读取侧共三处（`GT/Private/GameplayTagRedirectors.cpp:76-94`）：① `GetDefault<UGameplayTagsSettings>()->GameplayTagRedirects`；② 所有 `EGameplayTagSourceType::TagList` 源各自的 `GameplayTagRedirects`；③ 下面那条已弃用路径。

**已弃用位置（会打 Error 级日志，MUST NOT 使用）**：`DefaultEngine.ini` 的 `[/Script/Engine.Engine]` → `+GameplayTagRedirects=(...)`，命中即报

> `"GameplayTagRedirects is in a deprecated location, after editing GameplayTags developer settings you must remove these manually"` —— `:56`

引擎自己还在 `GameplayTagsEditorModule.cpp:271` 主动删这个位置的键（`GConfig->RemoveKeyFromSection(TEXT("/Script/Engine.Engine"), "+GameplayTagRedirects", ...)`）——即把"迁移到 settings"当成清理动作。

### 两条行为约束（`AddRedirects` 内，`:107-156`）

1. **同一 `OldTagName` 不得重定向到多个 `NewTagName`**——命中即 `ensureMsgf`（`:153`，原文 *"Old tag is being redirected to more than one tag"*）⇒ 批量改名时 `OldTagName` 必须唯一，且**同一批 redirect 不要同时出现在两个位置**（那会直接触发这条 ensure）
2. **多跳会被压平成单跳**——`:117-146` 循环跟随 `NewTagName`（10 次迭代保护），A→B→C 最终只登记 A→C ⇒ **直接写终态目标，不要链式重定向**（链式只增加维护面，不增加能力）

**为什么必须重定向**：改名后，**已经序列化进资产/蓝图/DataTable 的旧 tag 引用**不会自动跟着改。重定向让旧名在加载时解析到新名。不登记的话，这些引用靠 `WarnOnInvalidTags`（见 [engine-facts.md](engine-facts.md)）告警暴露，但已经丢失。

**删除**：删除不需要重定向（没有新名），但要靠 `WarnOnInvalidTags` 扫出残留引用后再清资产。

## 禁用形态

### 不要在 GameplayTags config 上挂自定义 `UDeveloperSettings`（MUST NOT）

`UGameplayTagsManager` 构建完 tag 树会**卸载** GameplayTags ini，并在非 Shipping / 非 Test / `DO_ENSURE` 构建里对任何"使用同一 config 文件的 UClass"报 `ensure`：

> `Class %s is using the GameplayTags config file which UGameplayTagsManager will attempt to unload after building the gameplay tag tree. This may cause the GameplayTags config file to be reloaded, consuming additional memory.`
> —— `GT/Private/GameplayTagsManager.cpp:373-383`；卸载动作 `:697` `GConfig->SafeUnloadBranch(*GGameplayTagsIni)`

即：**别把 tag 塞进一个 `config=GameplayTags` 的 Settings 类**。

### 不要用 DeveloperSettings 承载框架契约词（MUST NOT）

除了上一条的机制问题，`UDeveloperSettings` 是**运行期对象**——拿不到编译期常量，且让宿主可配框架契约词 = 宿主漏配即静默破坏框架行为（见「声明位置四分类」）。

**要给宿主决定权的正确做法**：框架声明**契约词**（不可配）+ 宿主在项目侧声明**自己的内容词**（可配）。扩展面是"多一个域"，不是"把契约词变成配置项"。

### 不要用裸字符串散落解析

`RequestGameplayTag(TEXT("..."))` 散落在各处会重复加锁（见 [engine-facts.md](engine-facts.md)）。项目应有一个**集中的 tag 解析门面**（按名解析 + 首次缓存），调用方只走门面。
