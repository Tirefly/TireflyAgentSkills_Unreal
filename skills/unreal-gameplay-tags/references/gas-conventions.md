# 与 GAS / GameplayCue 的对照与共存

行号前缀：`GAS/` = `Engine/Plugins/Runtime/GameplayAbilities/`；`GT/` = `Engine/Source/Runtime/GameplayTags/`。

## 先说结论：GAS 不强制任何 tag 词表

网络上流传的 `Ability.*` / `Status.*` / `GameplayEvent.*` / `Input.*` 等"GAS 惯用域"，**不是引擎强制**。本机核实：整个 GameplayAbilities 插件里原生定义的 tag 只有测试用的三条——

- `GAS/Source/GameplayAbilities/Private/Tests/GameplayTagCountContainerTests.cpp:12-14`：`Tests.GenericTag` / `.One` / `.Two`
- `GAS/Source/GameplayAbilities/Private/Tests/GameplayEffectTests.cpp:32`：`GameplayCue.Test`

GAS 的 tag 使用方式是**约定驱动**：引擎提供匹配/容器/cue 机制，**词表由项目自己定**。

⇒ **不要因为"GAS 惯例"就引入一批自己用不到的空域。** 需要对齐时按下面的机制做，而不是照搬词表。

> ⚠️ **未核实声明**：Lyra 样例在本机引擎安装中**不存在**（`Samples/` 目录未安装），因此本文**不引用 Lyra 的具体词表**。若需对齐 Lyra 的域组织，先取得其内容或官方文档再定论，不要凭记忆写进项目契约。

## `GameplayCue.` 前缀：唯一有硬编码语义的前缀

GAS 会**用 `GameplayCue.` 前缀拼出 Notify 资产名**（`GAS/Source/GameplayAbilities/Private/AbilitySystemGlobals.cpp:145`）：

```cpp
AssetName = FString(TEXT("GameplayCue.")) + AssetName;
```

⇒ 若使用 GAS 的 GameplayCue 体系，**`GameplayCue.*` 这一段的文本与层级受引擎约束，不得随意改**。这是整个 GAS tag 体系里少数真正硬性的地方。

## `GameplayCueTranslator`：设计 tag → cue tag 的翻译层

如果你**不想把设计侧的命名绑死在 `GameplayCue.` 前缀上**，引擎提供了官方翻译机制（`GAS/Source/GameplayAbilities/Public/GameplayCueTranslator.h`）：

> This system facilitates translating a GameplayCue event from one tag to another at runtime. This can be useful for customization or override type of systems that want to handle GameplayCues in different ways for different things or in different contexts.
> —— `:19-23`

文档给的两个典型用途（`:25-30`）：

1. 发出通用事件 `GameplayCue.Hero.Victory`，按英雄翻译成 `GameplayCue.<HeroName>.Victory`
2. 把 `GameplayCue.Impact.Material` 按命中面的物理材质翻译成 `GameplayCue.Impact.<Stone/Wood/Water/...>`

**扩展方式**：继承 `UGameplayCueTranslator`（`:260`，`UCLASS(Abstract)`），实现两个虚函数——

| 虚函数 | 作用 | 注意 |
|---|---|---|
| `GetTranslationNameSpawns(TArray<FGameplayCueTranslationNameSwap>&)` | 返回全部可能的 tag 交换规则，**启动时调用一次** | 头注释明写 "This should be **deterministic/order matters** for later"（`:267`）——返回顺序即索引契约 |
| `GameplayCueToTranslationIndex(const FName&, AActor*, const FGameplayCueParameters&)` | 运行期按 tag/actor/参数返回**上一步数组里的索引** | 返回 `INDEX_NONE` 表示不翻译（`:271`） |
| `GetPriority()` | 排序优先级，**数值越大越先有机会翻译**（`:274`） |
| `IsEnabled()` | 关闭某个 translator（`:277`），WIP 时有用 |

Translation LUT 由 `FGameplayCueTranslationManager` 构建并挂在 `UGameplayCueManager` 上（`:180-196`）。

**调试命令**（`:49-53`）：

```text
Log LogGameplayCueTranslator Verbose      ; 打开翻译日志
GameplayCue.PrintGameplayCueTranslator    ; 打印 translationLUT
GameplayCue.BuildGameplayCueTranslator    ; 重建 translationLUT
```

**为什么用翻译层而不是多加词**（`:32-35` 原文论点）：可以维持**单一原子的 GC Notify**，而不必写"知道所有变体"的巨型 Notify，也不必把 override 资产挂到每个角色蓝图/数据资产上。

⇒ 对本规范的含义：**翻译层是"自有命名空间"与"引擎强制前缀"之间的官方缓冲**。设计侧可以按自己的域规则命名，在边界处翻译成 `GameplayCue.*`。这比"为了迁就引擎前缀而污染自己的域划分"要干净。

## `CategoryRemapping`：展示层共存

`CategoryRemapping`（`GT/Classes/GameplayTagsSettings.h:139-141`）原文：

> Category remapping. This allows **base engine tag category meta data to remap to multiple project-specific categories**.

⇒ 引擎/插件自带的 tag 类目可以在**编辑器展示层**重映射到项目自己的类目，从而在 Project Settings → GameplayTags 面板里把"引擎词"与"项目词"分开呈现。这是**展示与归类**机制，不改 tag 文本本身。

## 共存建议

1. **先确认真的需要 GAS**。未上 GAS 时不要预留 `Ability.*` / `Status.*` 等空域——空域会膨胀成"以后可能用得上"的垃圾场。
2. **引擎强制前缀（`GameplayCue.`）单独成域，不与自有词汇混编排**。
3. **自有命名空间保持独立根前缀**，通过 `GameplayCueTranslator` 在边界翻译，而不是把 `GameplayCue` 嵌进自己的层级。
4. **面板观感用 `CategoryRemapping` 解决**，不要为了"看起来整齐"而改 tag 文本。
5. 真要引入 GAS 惯用域时，**先按 [taxonomy.md](taxonomy.md) 的"消费角色"判据逐条验证**：那个域在**你的项目里**由哪条代码路径解析？答不出来就不该建。

## 升级检查清单

1. `GameplayCue.` 前缀拼接是否仍在（`AbilitySystemGlobals.cpp`，5.8 在 `:145`）
2. `UGameplayCueTranslator` 的四个虚函数签名与语义（`GameplayCueTranslator.h:260-280`）
3. `GetTranslationNameSpawns` 的"顺序即契约"约定是否变化
4. 三个 `GameplayCue.*` 控制台命令是否仍在
5. `CategoryRemapping` 配置键是否改名
