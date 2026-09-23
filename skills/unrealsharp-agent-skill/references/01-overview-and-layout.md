# Overview And Layout

## 目录

- UnrealSharp 的通用前提
- 插件根目录与关键配置
- Source 模块地图
- Managed 侧目录地图
- Build 侧目录地图（Automation 命令）
- Script / glue / Binaries 的关系
- 高价值本地入口

> 路径一律按“相对当前工作区”解析。Skill 本体住在 `~/.agents/skills/` 下，与工程目录没有稳定相对关系，故不提供相对链接。

## UnrealSharp 的通用前提

官方 README 和 Quickstart 的共识：

- UnrealSharp 面向 UE 5.6 - 5.8
- 需要 .NET 10.0.5 或更新（插件内部按 `10.0.0` 做最低版本比较）
- 强烈建议使用 C++ 项目而不是纯 Blueprint 项目

如果当前工作区 vendored 了插件源码，通常根目录会是 `Plugins/UnrealSharp`。

## 插件根目录与关键配置

如果插件源码存在，最重要的几个入口文件通常是：

- `Plugins/UnrealSharp/UnrealSharp.uplugin`
  作用：定义 UnrealSharp 的模块、类型和加载阶段。

- `Plugins/UnrealSharp/UnrealSharp.Shared.props`
  作用：用户 C# 项目共享的 MSBuild 导入，定义 `TargetFramework=net10.0`、核心程序集引用、Analyzer 和 Source Generator。

- `Plugins/UnrealSharp/UnrealSharp.Build.props`
  作用：从 `UETargetType` / `UEBuildConfig` 推导 `DefineConstants`，并在 `BuildingAOT=true` 时定义 `NATIVE_AOT`。

- `Plugins/UnrealSharp/UnrealSharp.AOT.props`
  作用：AOT 配置的占位挂钩，当前内容为空。真正的开关在 `UnrealSharp.Build.props`。

- `Plugins/UnrealSharp/UnrealSharp.Automation.props`
  作用：**只给构建工具工程用**（`Build/Scripts` 和 `Source/UnrealSharpManagedGlue`），不注入用户代码。它从引擎的 `UE5Rules.csproj` 里正则提取 `DefineConstants`，据此决定工具自身用 `net8.0` 还是 `net10.0`（含 `UE_5_8_OR_LATER` 时为后者）。

- `Plugins/UnrealSharp/Directory.Packages.props`
  作用：集中管理插件内部 NuGet 版本，例如 Roslyn、MSBuild、Newtonsoft.Json。

- `Plugins/UnrealSharp/Config/UnrealSharp.Settings.json`
  作用：定义 `ScriptDirectoryName`，默认值是 `Script`。

- `Plugins/UnrealSharp/Config/DefaultUnrealSharp.ini`
  作用：核心重定向与设置基线。

- `Plugins/UnrealSharp/Config/Default.UnrealSharpTypes.json`
  作用：类型导出侧的默认配置。

> **注意**：`UnrealSharp.GeneratedFiles.props` **已经不存在了**。旧版用它把 `obj/UHT/**/*.cs` 挂进工程；现在改为由 `Managed/UnrealSharp/UnrealSharp/UnrealSharp.csproj` 直接 `<Compile Include="$(UHTGeneratedPath)\**\*.cs"/>`。

## Source 模块地图

Source 目录通常是 `Plugins/UnrealSharp/Source`。

主要模块和职责：

- `Source/UnrealSharpCore/UnrealSharpCore.Build.cs`
  运行时核心模块。启动时驱动 SDK 检查、用户方案构建、托管运行时初始化。

- `Source/UnrealSharpEditor/UnrealSharpEditor.Build.cs`
  编辑器集成模块。UI、项目创建向导、热重载子系统、工具栏。

- `Source/UnrealSharpCompiler/UnrealSharpCompiler.Build.cs`
  编译相关的编辑器模块，依赖 KismetCompiler、BlueprintGraph 等。

- `Source/UnrealSharpBinds/UnrealSharpBinds.Build.cs`
  运行时绑定层模块。

- `Source/UnrealSharpAsync/` 与 `Source/UnrealSharpAsyncBlueprint/`
  异步支持模块（`UnrealSharpAsyncBlueprint` 是 UncookedOnly）。

- `Source/UnrealSharpRuntimeGlue/UnrealSharpRuntimeGlue.Build.cs`
  运行时 glue 模块，负责生成项目侧的基础标识（AssetIds、GameplayTags、TraceChannel 等）。

- `Source/UnrealSharpUtilities/UnrealSharpUtilities.Build.cs`
  提供构建调用（`CSBuildUtilties.cpp`）、路径与流程辅助。

- `Source/UnrealSharpManagedGlue/`
  **不是普通 UE 模块，而是 UBT 插件（UHT 导出器）**。见下节。

### UnrealSharpManagedGlue 是 UBT 插件

这是与旧版本最大的结构差异之一。

- 工程文件是 `Source/UnrealSharpManagedGlue/UnrealSharpManagedGlue.ubtplugin.csproj`，`OutputType=Library`，**没有 `Main()`**。
- UBT 会自动发现它：引擎侧的 `Rules.cs` 识别 `.ubtplugin.csproj` 扩展名，并且只递归 `.uplugin` 所在目录的 `Source` 与 `Build` 子目录。
- 入口在 `Source/UnrealSharpManagedGlue/Program.cs`：
  ```csharp
  [UnrealHeaderTool]
  public static class Program
  {
      [UhtExporter(Name = "UnrealSharpCore", Description = "Exports C++ to C# code", Options = UhtExporterOptions.Default, ModuleName = "UnrealSharpCore")]
      private static void Main(IUhtExportFactory factory)
  ```
- 也就是说：**glue 生成发生在 C++ 构建的 UHT 阶段**，不是编辑器启动时。
- 该 csproj 里有一个 `BuildAutomation` target，会在自身构建前先把 `Build/Scripts/UnrealSharp.Automation.csproj` 编译到自己的输出目录，形成依赖倒置。

## Managed 侧目录地图

Managed 根目录通常是 `Plugins/UnrealSharp/Managed`。

关键子目录：

- `Managed/global.json`
  固定 SDK 版本（`10.0.201`，`rollForward: latestFeature`）。

- `Managed/UnrealSharp/`
  托管侧的多个工程集合，包括：
  - `UnrealSharp/` —— 运行时门面（Array/Map/Set/Delegate 等包装、扩展方法）
  - `UnrealSharp.Core/` —— 核心特性定义、Marshaller、Interop
  - `UnrealSharp.Analyzers/` —— Roslyn 分析器（US0001 起的一系列硬规则）
  - `UnrealSharp.SourceGenerators/` —— 自定义日志、NativeCallbacks 包装生成
  - `UnrealSharp.ExtensionSourceGenerators/` —— Actor/ActorComponent 扩展生成（只注入插件自身，用户项目拿不到）
  - `UnrealSharp.GlueGenerator/` —— 从 C# 侧反射声明导出 glue 的分析器
  - `UnrealSharp.Binds/`、`UnrealSharp.Log/`、`UnrealSharp.Plugins/`、`UnrealSharp.StaticVars/`、`UnrealSharp.Editor/`

- `Managed/Shared/`
  托管侧共享工具和模型定义（含装配加载顺序算法）。

- `Managed/DotNetRuntime/`
  嵌入式运行时相关资源。

## Build 侧目录地图（Automation 命令）

**旧版的 `Managed/UnrealSharpPrograms/UnrealSharpBuildTool/` 已经整体不存在了**（没有 `Program.cs`、没有 `Actions/`）。现在构建工具是 `Plugins/UnrealSharp/Build/Scripts/`：

- `Build/Scripts/UnrealSharp.Automation.csproj`
  程序集名 `UnrealSharp.Automation`，`OutputType=Library`。每个命令继承 UBT 的 `BuildCommand`，由反射按类名派发（`Build/Scripts/Utilities/CommandUtilities.cs`）。
- `Build/Scripts/BuildCommands/`
  全部构建命令，见 `02-build-generation-and-hot-reload.md`。
- `Build/Scripts/Processes/`
  进程封装（`DotnetProcess`、`BuildToolProcess`）。
- `Build/Scripts/Utilities/`
  路径、XML、模板、加载顺序、启动设置等工具。

编译产物落在 `Build/Scripts/bin/Development/UnrealSharp.Automation.dll`，同时会被复制一份到 `Source/UnrealSharpManagedGlue/bin/Development/win-x64/`。

## Script / glue / Binaries 的关系

这是 UnrealSharp 最容易混淆的一层。

业务脚本项目：

- 项目自己的 C# 项目位于 `Script/<ModuleName>/`。
- 插件自己的 C# 项目可位于对应插件根目录下的 `Script/<ModuleName>/`（由编辑器向导创建）。

生成的 glue 工程：

- 路径是 `Intermediate/UnrealSharp/UHT/<TargetType>/<ModuleName>/<ModuleName>.csproj`。
- **没有 `.Glue` 后缀了**，工程名就是模块名。
- **没有 `obj/UHT/` 这一段了**，`obj/` 只是普通 MSBuild 中间目录。
- 落盘根目录取决于模块归属：
  - 引擎模块且带扩展（`EmitsToProjectDirectory`）→ 落到**项目**的 `Intermediate/`，并沿依赖传播
  - 其他模块（含项目模块、插件模块）→ 落到**该模块自己的** `Intermediate/`

实测分布（一个接了 UnrealSharp 的项目）：

| 位置 | 内容 |
|---|---|
| `Plugins/UnrealSharp/Intermediate/UnrealSharp/UHT/Editor/` | 引擎与引擎插件的 glue（约 620 个模块、2 万余个 `*.generated.cs`） |
| `Plugins/<插件>/Intermediate/UnrealSharp/UHT/Editor/<Module>/` | 各插件模块的 glue |
| `Intermediate/UnrealSharp/UHT/Editor/<Module>/` | 项目自有模块（如 `TcsDev`）的 glue |

UHT 生成物：

- 每个 glue 目录下的 `*.generated.cs`，文件名形如 `<EngineName>.generated.cs`。

托管输出：

- 运行期输出落在 `Binaries/Managed/net10.0/`
- 装配加载顺序文件为 `GlueCode.LoadOrder.json` 与 `UserCode.LoadOrder.json`（见 `02`）。

## 高价值本地入口

如果只允许看少量文件，优先看这些：

- `Plugins/UnrealSharp/README.md`
- `Plugins/UnrealSharp/UnrealSharp.uplugin`
- `Plugins/UnrealSharp/UnrealSharp.Shared.props`
- `Plugins/UnrealSharp/Managed/global.json`
- `Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/Program.cs`（UHT 导出器入口）
- `Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/ModuleFactory.cs`（模块与 glue 工程同步）
- `Plugins/UnrealSharp/Build/Scripts/BuildCommands/`（构建命令集合）
- `Plugins/UnrealSharp/Source/UnrealSharpUtilities/Private/CSBuildUtilties.cpp`（C++ 侧如何调起构建）
- `Plugins/UnrealSharp/Source/UnrealSharpCore/Private/UnrealSharpCore.cpp`（启动链路）
