# 治理：审查清单、校验脚本、变更流程

## 审查清单

审一批 tag 时逐项核对。前 6 项是 [taxonomy.md](taxonomy.md) 的可核对化，后 6 项来自 [authoring.md](authoring.md)。

### 词表设计

- [ ] 每个 tag 段数 ≤ 4
- [ ] 段 2（域）能用"**哪个子系统解析它**"一句话回答
- [ ] 每段 PascalCase，无下划线，纯 ASCII
- [ ] 路径里没有生命周期 / 优先级 / 状态 / 开发阶段段
- [ ] 临时验证词全在 `Probe` 域内，且 `DevComment` 写了**退役判据**
- [ ] 新增顶层域了吗？如果新增，理由是"出现了新的消费角色"（不是"内容变多了"）

### 声明与写法

- [ ] **同一 tag 文本只有一处声明**（原生 / ini / DataTable 不重名）
- [ ] 声明位置符合**可用时机四分类**（契约词/框架默认内容→原生；宿主内容→ini；验证词→Probe + 非 Shipping 消费）
- [ ] 每条词都有可读 `DevComment`；原生侧用 `UE_DEFINE_GAMEPLAY_TAG_COMMENT` 而非无注释变体
- [ ] 供跨模块使用的原生 tag，声明处带**模块导出宏**（不是 `UE_DECLARE_GAMEPLAY_TAG_EXTERN`）
- [ ] C++ 常量名与 tag 文本**逐段点→下划线对应**
- [ ] 没有 `config=GameplayTags` 上的自定义 `UDeveloperSettings`
- [ ] 没有用 `UDeveloperSettings` 承载框架契约词

### 变更安全

- [ ] 改名都登记了 `FGameplayTagRedirect`（且先核实了受支持的位置，见 [authoring.md](authoring.md) 的位置警告）
- [ ] 删除后跑过一遍全内容加载，`WarnOnInvalidTags` 零 Warning
- [ ] 消费者未落在"tag 表加载之前"的时机（静态初始化 / `StartupModule`）
- [ ] 热路径没有逐次 `RequestGameplayTag`

## 校验脚本

```powershell
pwsh -File scripts/Validate-GameplayTags.ps1 -ProjectRoot <项目根> -Namespace <根前缀>
```

只读、零副作用。扫描源：`Config/DefaultGameplayTags.ini`、`Config/Tags/**/*.ini`、`Source/**` 与 `Plugins/**/Source/**` 下的 `*.h` / `*.cpp`。

### 检查项

| # | 检查 | 级别 |
|---|---|---|
| 1 | 段数超过 `-MaxDepth`（默认 4） | Error |
| 2 | 段内下划线 | Error |
| 3 | 非 ASCII 字符 | Error |
| 4 | 引擎硬非法字符（`"` `'` `,` 与空白） | Error |
| 5 | 空段（连续点 / 首尾点） | Error |
| 6 | 首段与 `-Namespace` 不符 | Error |
| 7 | 生命周期类段出现在段 3 及之后（`-ForbiddenSegments`） | Error |
| 8 | ini 词缺 `DevComment` | Warning |
| 9 | **同一 tag 文本多处声明** | Error |
| 10 | 原生声明缺模块导出宏（`extern <模块>_API FNativeGameplayTag`） | Warning |
| 11 | 原生常量名与 tag 文本不逐段对应 | Warning |
| 12 | 原生用无注释宏定义（建议 `_COMMENT`） | Info |

退出码：`0` = 无 Error；`1` = 有 Error；`2` = 参数或路径问题。

### 脚本查不出来的（必须人工）

- 域的判据是否成立（"哪个子系统解析它"）——只能人答
- 一个词该归哪个域
- `DevComment` 的内容是否真实有用
- `Probe` 词的退役判据是否合理
- **隐式父节点造成的静默降级**（叶子末段写漏会解析到自动补齐的父节点，见 [engine-facts.md](engine-facts.md)）——需要把"应存在的显式 tag 清单"与解析结果对比，脚本当前不做

## 词表结构性变更流程

以下变更属**结构性**，按项目的契约层流程先提案后实现（本项目主仓以 OpenSpec 为契约层）：

- 新增/删除**顶层域**
- 改变域名、子域名，或改动已有 tag 文本（改名）
- 批量退役 `Probe` 域内容
- 改变声明位置分类的边界（如把某类词从 ini 迁到原生）

以下变更**不需要**提案，直接做：

- 在既有域/子域下新增单个词（符合既定层级与命名）
- 补充 `DevComment`
- 删除单个词（前提：已确认无资产引用）

### 变更实施顺序（改名 / 删除）

1. **先登记重定向**（改名）或**先启用 `WarnOnInvalidTags`**（删除）——**在改词表之前**
2. 改声明处（ini / C++ / 词表注册表 / 项目契约文档）
3. 改代码引用（含集中的解析门面、验证装置、脚本侧）
4. **重生成派生资产**——代码生成的 tag 常量文件（如脚本侧 glue 项目）会自动重生成，但**手写代码若引用了生成常量的旧名字会断**，要一并改
5. 重存受影响的内容资产；重定向生效后旧名仍可解析，故这一步可以延后但不能忘
6. 跑一遍全内容加载，看 `LogGameplayTags` 的 Warning
7. 更新项目侧词表注册表与契约文档

### 删除验证词时

**先查它对应的验证提案是否已归档。** 已归档 = 验证已完成 = 装置与词都可以删。未归档 = 还需要它，不要删。

删的对象不止 tag 条目，还包括：验证装置的代码（C++/脚本侧）、消费它的命令与装置资产、以及文档里的引用。**只删 tag 不删装置，会留下解析失败的一堆空转代码。**
