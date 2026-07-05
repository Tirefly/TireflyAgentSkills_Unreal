---
name: unrealsharp-agent-skill
description: "Use when working with UnrealSharp in a Unreal Engine 5.5-5.7 project, including UnrealSharp plugin architecture, Script/*.csproj, *.Glue projects, UHT-generated C# bindings, UnrealSharpBuildTool, BuildEmitLoadOrder, hot reload, creating C# projects or C# plugins, generated.cs, UClass/UProperty/UFunction, editor startup stuck around 75%, or UnrealSharp troubleshooting."
---

# UnrealSharp Agent Skill

这个 Skill 是面向 Agent 的 UnrealSharp 通用工作流指南，适用于 vendored UnrealSharp 插件的 UE5.5 - 5.7 工程，不绑定某个具体项目。

适用范围：

- UnrealSharp 插件结构与模块职责
- Script 目录、Glue 项目、generated.cs 的关系
- UnrealSharpBuildTool、BuildEmitLoadOrder、启动阶段 dotnet 流程
- C# 项目与 C# 插件创建
- UnrealSharp 脚本的编码规范、硬性要求、命名与生命周期约束
- UClass / UStruct / UEnum / UInterface / UProperty / UFunction / 参数级元数据的常见写法
- 75% 启动卡住、Glue 编译失败、生成器规则异常

如果当前工作区包含 [Plugins/UnrealSharp](../../../Plugins/UnrealSharp)，优先用本地插件源码和配置回答；如果只有二进制插件或没有插件源码，再退回官方文档和通用规则。

## 任务路由

根据问题类型，优先读取下列参考文件：

- 先理解 UnrealSharp 的目录、模块和产物：读 [01-overview-and-layout.md](./references/01-overview-and-layout.md)
- 处理编译、Glue 生成、BuildEmitLoadOrder、热重载、启动流程：读 [02-build-generation-and-hot-reload.md](./references/02-build-generation-and-hot-reload.md)
- 编写或解释 C# UnrealSharp 代码、属性和函数特性、编码规范、硬性规则、元数据写法：读 [03-csharp-authoring-patterns.md](./references/03-csharp-authoring-patterns.md)
- 创建新的 C# 项目、C# 插件项目、理解编辑器里的 New C# Project：读 [04-project-and-plugin-creation.md](./references/04-project-and-plugin-creation.md)
- 排查 75% 启动卡住、dotnet task failed、generated.cs 报错、Glue 项目构建失败：读 [05-troubleshooting-and-diagnostics.md](./references/05-troubleshooting-and-diagnostics.md)
- 需要快速跳转到官方文档或本地高价值入口文件：读 [06-official-links-and-local-entrypoints.md](./references/06-official-links-and-local-entrypoints.md)

## 工作规则

- 不要直接修改 `Script/**/*.Glue` 或 `obj/UHT/**/*.generated.cs`。这些文件是生成物。
- 诊断 UnrealSharp 问题时，优先沿着 `反射声明 -> UHT 输出 -> ManagedGlue / BuildTool -> .Glue.csproj` 的链路定位。
- 如果用户说“C++ 编过了，但打开编辑器卡在 75%”，优先把问题当作 UnrealSharp 的 Glue / dotnet 阶段问题，而不是原生 C++ 链接问题。
- 判断当前项目使用的引擎版本时，优先读 `.uproject` 里的 `EngineAssociation` 或用户明确指定的引擎路径，不要把 `Intermediate/TargetInfo*.json` 这类可能过期的中间文件当作事实来源。
- 如果问题涉及某个函数或属性的生成异常，优先检查原始声明是否使用了 `BlueprintNativeEvent`、`DeterminesOutputType`、非 `const` 引用参数、Blueprint getter/setter 风格命名等高风险组合。
- 如果用户要创建或修改 C# 项目，优先使用 UnrealSharp 的项目创建路径，而不是手工拼装 `.csproj`。
- 如果用户要理解为什么某个 API 在 C# 里不可见，先检查它是否对 UE 反射系统可见。UnrealSharp 只能使用已暴露到反射的 API，这一点和 Blueprint 的限制高度一致。
- 如果用户反馈“我本机能进编辑器，但团队 fresh clone 后打开编辑器失败”，除了检查声明和生成器规则，还要检查仓库里已提交的 `Script/**/obj/UHT/**/*.generated.cs` 是否缺文件、以及 `.gitignore` 是否把必要的 UnrealSharp 生成输入挡在 Git 之外。
- 如果用户把本 Skill 当作“UnrealSharp 编程规范”来使用，默认先读 [03-csharp-authoring-patterns.md](./references/03-csharp-authoring-patterns.md)，其中应优先区分“Analyzer 会报错的硬规则”和“建议遵守的风格规则”。

## 常用诊断顺序

1. 找到原始 C++ 或 C# 声明。
2. 找到对应的生成物路径，例如 `Script/<Module>.Glue/obj/UHT/.../*.generated.cs`。
3. 单独编译受影响的 `.Glue.csproj`，不要一开始就跑全项目。
4. 如果需要验证启动链路，再跑 `UnrealSharpBuildTool --Action BuildEmitLoadOrder` 或一次 Editor 目标构建。
5. 只有当生成器本体有问题时，才去看 [UnrealSharpManagedGlue](../../../Plugins/UnrealSharp/Source/UnrealSharpManagedGlue) 或 [UnrealSharpBuildTool](../../../Plugins/UnrealSharp/Managed/UnrealSharpPrograms/UnrealSharpBuildTool)。

## 你应该记住的通用事实

- UnrealSharp 的业务脚本项目通常位于 `Script/` 下。
- Glue 项目是互操作生成层，不是业务层。
- `BuildEmitLoadOrder` 是编辑器打开项目时常见的托管构建动作入口。
- vendored UnrealSharp 项目通常把插件放在 `Plugins/UnrealSharp`，并通过 `UnrealSharp.Shared.props` 把运行时、Analyzer 和 Source Generator 注入到用户项目中。

## 何时读取更多引用

- 如果只是快速回答“文件在哪”“为什么会生成这个项目”，先读本 Skill 和 [06-official-links-and-local-entrypoints.md](./references/06-official-links-and-local-entrypoints.md)。
- 如果需要给出修复建议或实现方案，至少再读一个对应主题的参考文件。
- 如果用户要求“完整使用指南”或“系统性梳理”，按 01 -> 02 -> 03 -> 04 -> 05 的顺序读取。
