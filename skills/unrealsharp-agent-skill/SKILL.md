---
name: unrealsharp-agent-skill
description: "Use when working with UnrealSharp in a Unreal Engine 5.6-5.8 project, including UnrealSharp plugin architecture, Script/*.csproj, glue projects under Intermediate/UnrealSharp/UHT, UHT-generated C# bindings, UnrealSharp.Automation build commands, UBT plugin (ubtplugin) glue generation, LoadOrder.json, hot reload, creating C# projects or C# plugins, *.generated.cs, UClass/UProperty/UFunction partial declarations, editor startup hang, or UnrealSharp troubleshooting."
---

# UnrealSharp Agent Skill

这个 Skill 是面向 Agent 的 UnrealSharp 通用工作流指南，适用于 vendored UnrealSharp 插件的 UE 5.6 - 5.8 工程，不绑定某个具体项目。

> **本文档中的路径一律写成“工作区相对路径”**（例如 `Plugins/UnrealSharp/Source/...`）。
> Skill 本体住在 `~/.agents/skills/` 下，与你的工程目录没有稳定的相对关系，所以这里不提供相对链接——请把路径当作相对当前工作区来解析。

适用范围：

- UnrealSharp 插件结构与模块职责
- Script 目录、glue 工程、`*.generated.cs` 的关系
- UnrealSharp.Automation 构建命令、LoadOrder.json、启动阶段 dotnet 流程
- C# 项目与 C# 插件创建
- UnrealSharp 脚本的编码规范、硬性要求、命名与生命周期约束
- UClass / UStruct / UEnum / UInterface / UProperty / UFunction / 参数级元数据的常见写法
- 启动卡住、glue 编译失败、生成器规则异常

如果当前工作区包含 `Plugins/UnrealSharp`，优先用本地插件源码和配置回答；如果只有二进制插件或没有插件源码，再退回官方文档和通用规则。

## 任务路由

根据问题类型，优先读取下列参考文件：

- 先理解 UnrealSharp 的目录、模块和产物：读 [01-overview-and-layout.md](./references/01-overview-and-layout.md)
- 处理编译、glue 生成、LoadOrder.json、热重载、启动流程：读 [02-build-generation-and-hot-reload.md](./references/02-build-generation-and-hot-reload.md)
- 编写或解释 C# UnrealSharp 代码、属性和函数特性、编码规范、硬性规则、元数据写法：读 [03-csharp-authoring-patterns.md](./references/03-csharp-authoring-patterns.md)
- 创建新的 C# 项目、C# 插件项目、理解编辑器里的 New C# Project：读 [04-project-and-plugin-creation.md](./references/04-project-and-plugin-creation.md)
- 排查启动卡住、dotnet task failed、`*.generated.cs` 报错、glue 工程构建失败：读 [05-troubleshooting-and-diagnostics.md](./references/05-troubleshooting-and-diagnostics.md)
- 需要快速跳转到官方文档或本地高价值入口文件：读 [06-official-links-and-local-entrypoints.md](./references/06-official-links-and-local-entrypoints.md)

## 工作规则

- 不要直接修改 `Intermediate/UnrealSharp/**` 下任何内容。整个目录都是生成物（glue 工程、`*.generated.cs`、`*.sln`）。
- 诊断 UnrealSharp 问题时，优先沿着 `反射声明 -> UHT 导出（ubtplugin）-> ModuleFactory -> 生成 csproj -> UnrealSharp.Automation 构建 -> Binaries/Managed` 的链路定位。
- 如果用户说“C++ 编过了，但打开编辑器卡住”，优先把问题当作 UnrealSharp 的 glue / dotnet 阶段问题，而不是原生 C++ 链接问题。
- 判断当前项目使用的引擎版本时，优先读 `.uproject` 里的 `EngineAssociation` 或用户明确指定的引擎路径，不要把 `Intermediate/TargetInfo*.json` 这类可能过期的中间文件当作事实来源。
- 如果问题涉及某个函数或属性的生成异常，优先检查原始声明是否使用了 `BlueprintNativeEvent`、`DeterminesOutputType`、非 `const` 引用参数、Blueprint getter/setter 风格命名等高风险组合。
- 如果用户要创建或修改 C# 项目，优先使用 UnrealSharp 的项目创建路径（编辑器向导或 `GenerateProject` 命令），而不是手工拼装 `.csproj`。
- 如果用户要理解为什么某个 API 在 C# 里不可见，先检查它是否对 UE 反射系统可见。UnrealSharp 只能使用已暴露到反射的 API，这一点和 Blueprint 的限制高度一致。
- 如果用户反馈“我本机能进编辑器，但团队 fresh clone 后打开编辑器失败”，注意 glue **不进 Git**（它在 `Intermediate/` 下），所以问题几乎不可能出在“已提交的 glue 不完整”，而更可能是 SDK 缺失、C++ 未编译过、或 `.gitignore` 误伤了 `Script/`。
- 如果用户把本 Skill 当作“UnrealSharp 编程规范”来使用，默认先读 [03-csharp-authoring-patterns.md](./references/03-csharp-authoring-patterns.md)，其中应优先区分“Analyzer 会报错的硬规则”和“建议遵守的风格规则”。
- 编写 C# 代码文件时，文件编码统一使用 UTF-8 无签名（UTF-8 without BOM），换行符统一使用 LF（Unix 风格，`\n`），不要使用 BOM 或 CRLF。

## 常用诊断顺序

1. 找到原始 C++ 或 C# 声明。
2. 找到对应的生成物路径，例如 `Intermediate/UnrealSharp/UHT/<TargetType>/<Module>/*.generated.cs`。
3. 单独编译受影响的 glue 工程，不要一开始就跑全项目。
4. 如果需要验证启动链路，再跑一次 Editor 目标构建（glue 生成挂在 UHT 里），或手工触发 `BuildEmitLoadOrder`。
5. 只有当生成器本体有问题时，才去看 `Plugins/UnrealSharp/Source/UnrealSharpManagedGlue`（UHT 导出插件）或 `Plugins/UnrealSharp/Build/Scripts`（Automation 构建命令）。

## 你应该记住的通用事实

- UnrealSharp 的业务脚本项目通常位于 `Script/<ModuleName>/` 下。
- **glue 工程不是业务层，也不再叫 `*.Glue`**：它现在是 `<ModuleName>.csproj`，落在 `Intermediate/UnrealSharp/UHT/<TargetType>/<ModuleName>/`。
- **UnrealSharp 没有独立的 `UnrealSharpBuildTool` 可执行文件了**。构建命令是一组 UBT `BuildCommand`，程序集名 `UnrealSharp.Automation`，住在 `Plugins/UnrealSharp/Build/Scripts/`，由 UAT 加载执行。
- **glue 生成挂在 UHT 里**：`UnrealSharpManagedGlue` 是一个 UBT 插件（`.ubtplugin.csproj`），在 C++ 构建的 UHT 阶段导出绑定。
- 用户 C# 项目通过 `UnrealSharp.Shared.props` 拿到运行时、Analyzer 和 Source Generator 注入。
- **业务侧的 `[UProperty]` 必须写 `partial`**，`[UClass]` 类型也必须 `partial`——这是生成器合并声明的前提。
