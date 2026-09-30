---
name: unreal-gameplay-tags
description: Unreal Engine GameplayTag 治理规范与引擎机制事实（Tirefly 个人规范，跨项目）。规定 tag 的域划分与层级规则、段命名风格、声明位置取舍（原生 FNativeGameplayTag / DefaultGameplayTags.ini / Config/Tags / DataTable / Restricted GameplayTags）、临时验证词的隔离与退役、改名与重定向、治理与校验流程。Use when designing or reviewing a GameplayTag taxonomy, adding, renaming or removing gameplay tags, declaring UE_DEFINE_GAMEPLAY_TAG or FNativeGameplayTag, editing DefaultGameplayTags.ini or Config/Tags, choosing between a native tag and a config tag, using GameplayTagTableList, Restricted GameplayTags or GameplayTagRedirects, resolving FGameplayTag at runtime or caching tag lookups, aligning with GAS or GameplayCue tag conventions, or debugging tag-related LNK2001/LNK2019 and tag availability timing.
---

# unreal-gameplay-tags

> **版本基线**：UE 5.8.0（Release-5.8，CL 55116800）。本文全部引擎结论带本机源码路径（`Engine/Source/Runtime/GameplayTags/`，下文简写 `GT/`；GAS 侧为 `Engine/Plugins/Runtime/GameplayAbilities/`）。与官方文档措辞冲突时以源码为准。
>
> **范围边界**：本技能只承载**跨项目的治理规范与引擎机制事实**，不含任何具体项目的 tag 索引、词表快照或域清单。项目词表住在各项目自己的仓库（项目的 OpenSpec 契约或 `Documents/` 基线文档）。**新建或审查 tag 前，先读项目侧的词表注册表**；本项目没登记过就要求建，不要从代码里猜。

## 三条不变量

其余规则都能从这三条推出来。记不住别的，记住这三条：

1. **域 = 消费角色**——顶层域的判据是"这个词会被哪条代码路径解析/匹配"，不是"它属于哪个业务系统"，也不是"它是什么种类"。
2. **一个 tag 文本，一处声明**——同一 tag 文本被两处声明（原生 / ini / DataTable 任意组合）即违规。**原生侧的重复声明引擎不会报错**（按指针分别注册，见 `engine-facts.md`），所以只能靠规则与校验脚本拦。
3. **可用时机决定声明位置**——谁在什么阶段需要这个词（编译期常量 / 运行期按名解析 / 仅非 Shipping），唯一地决定它放哪儿。

## 参考文档索引（references/）

| 文档 | 内容 |
|---|---|
| [taxonomy.md](references/taxonomy.md) | 域划分判据、段位语义与深度上限、段命名风格、正交维度禁入、临时验证词的 `Probe` 域形态与退役 |
| [authoring.md](references/authoring.md) | 声明位置四分类、`DevComment` 要求、原生 tag 三宏与模块导出宏、ini 与 `Config/Tags`、DataTable 的定位、Restricted GameplayTags、改名与重定向、禁用形态 |
| [engine-facts.md](references/engine-facts.md) | tag 树构建顺序、两段式注册与顺序不确定性、可用时机禁区、查询与缓存、父节点语义、字符约束、跨模块链接、悬空引用捕获 |
| [gas-conventions.md](references/gas-conventions.md) | GAS 是否强制词表、`GameplayCue.` 前缀硬约束、`GameplayCueTranslator` 翻译层、`CategoryRemapping` 共存 |
| [governance.md](references/governance.md) | 审查清单、校验脚本用法与检查项、词表结构性变更流程 |

## 任务路由

| 你要做的事 | 先读 |
|---|---|
| 设计或审查词表层级、决定新词归哪个域、判断 tag 深度与命名 | taxonomy.md |
| 新增一个 tag：决定用原生还是 ini | authoring.md「声明位置四分类」 |
| 写 `UE_DEFINE_GAMEPLAY_TAG` / `FNativeGameplayTag` / 常量名 / 导出宏 | authoring.md「原生 tag 写法」 |
| 编辑 `DefaultGameplayTags.ini` 或引入 `Config/Tags/*.ini` | authoring.md「ini 与多文件」 |
| 改名 / 删除 tag，处理资产里的悬空引用 | authoring.md「改名与重定向」+ engine-facts.md「悬空引用」 |
| 想做"顶层谁能加、子层自由"的审批约束 | authoring.md「Restricted GameplayTags」 |
| 运行期解析不到 tag / 时序不对 / Shipping 行为不同 | engine-facts.md「可用时机」 |
| 跨模块引用原生 tag 报 LNK2001 / LNK2019 | engine-facts.md「跨模块链接」→ 机制本体在 `unreal-development-workflow` |
| 要和 GAS / GameplayCue 的现成机制对齐 | gas-conventions.md |
| 审查一批 tag 是否合规 | governance.md + `scripts/Validate-GameplayTags.ps1` |

## 使用纪律

- 引用引擎行为前先在本机源码 `Engine/Source/Runtime/GameplayTags/` 核对；升级引擎时先走 [engine-facts.md](references/engine-facts.md) 的「升级检查清单」。
- 写 GameplayTag 相关 C++ 前遵循 `unreal-cpp-style`；执行与验证纪律按 `unreal-development-workflow`。
- **本技能规则与项目既有契约冲突时，停下来按项报告冲突**（引用路径、冲突内容、实际影响），不要静默偏袒任一方。用户的直接指令优先于本技能。
- 「跨模块符号导出」的**通用原理**（不止 tag）本体住在 `unreal-development-workflow` 的「引擎机制事实」节；本技能只保留 tag 专属的写法规则并指向它，不复制第二份。
