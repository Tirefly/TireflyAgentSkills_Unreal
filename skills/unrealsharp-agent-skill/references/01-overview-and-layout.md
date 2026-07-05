# Overview And Layout

## 目录

- UnrealSharp 的通用前提
- 插件根目录与关键配置
- Source 模块地图
- Managed 侧目录地图
- Script / Glue / Binaries 的关系
- 高价值本地入口

## UnrealSharp 的通用前提

官方 README 和 Quickstart 的共识：

- UnrealSharp 面向 UE 5.5 - 5.7
- 需要 .NET 10 SDK
- 强烈建议使用 C++ 项目而不是纯 Blueprint 项目

如果当前工作区 vendored 了插件源码，通常根目录会是 [Plugins/UnrealSharp](../../../../Plugins/UnrealSharp)。

## 插件根目录与关键配置

如果插件源码存在，最重要的几个入口文件通常是：

- [UnrealSharp.uplugin](../../../../Plugins/UnrealSharp/UnrealSharp.uplugin)
作用：定义 UnrealSharp 的模块、类型和加载阶段。

- [UnrealSharp.Shared.props](../../../../Plugins/UnrealSharp/UnrealSharp.Shared.props)
作用：用户 C# 项目和 Glue 项目共享的 MSBuild 导入，定义 `TargetFramework=net10.0`、核心程序集引用、Analyzer 和 Source Generator。

- [UnrealSharp.GeneratedFiles.props](../../../../Plugins/UnrealSharp/UnrealSharp.GeneratedFiles.props)
作用：把 `obj/UHT/<Target>/**/*.cs` 作为编译项加入项目，因此 `generated.cs` 来自 UHT 输出，而不是人工维护。

- [Directory.Packages.props](../../../../Plugins/UnrealSharp/Directory.Packages.props)
作用：集中管理插件内部 NuGet 版本，例如 Roslyn、MSBuild、Newtonsoft.Json、CommandLineParser。

- [Config/UnrealSharp.Settings.json](../../../../Plugins/UnrealSharp/Config/UnrealSharp.Settings.json)
作用：定义 `ScriptDirectoryName`，默认常见值是 `Script`。

- [Config/DefaultUnrealSharp.ini](../../../../Plugins/UnrealSharp/Config/DefaultUnrealSharp.ini)
作用：核心重定向与设置基线。

## Source 模块地图

Source 目录通常是 [Plugins/UnrealSharp/Source](../../../../Plugins/UnrealSharp/Source)

主要模块和职责：

- [UnrealSharpCore.Build.cs](../../../../Plugins/UnrealSharp/Source/UnrealSharpCore/UnrealSharpCore.Build.cs)
运行时核心模块，负责核心桥接、运行时装配、生成 Glue 路径和基础依赖。

- [UnrealSharpEditor.Build.cs](../../../../Plugins/UnrealSharp/Source/UnrealSharpEditor/UnrealSharpEditor.Build.cs)
编辑器集成模块，负责 UI、项目创建、编辑器功能入口。

- [UnrealSharpCompiler.Build.cs](../../../../Plugins/UnrealSharp/Source/UnrealSharpCompiler/UnrealSharpCompiler.Build.cs)
编译相关的编辑器模块，依赖 KismetCompiler、BlueprintGraph 等。

- [UnrealSharpBinds.Build.cs](../../../../Plugins/UnrealSharp/Source/UnrealSharpBinds/UnrealSharpBinds.Build.cs)
运行时绑定层模块。

- [UnrealSharpRuntimeGlue.Build.cs](../../../../Plugins/UnrealSharp/Source/UnrealSharpRuntimeGlue/UnrealSharpRuntimeGlue.Build.cs)
运行时 Glue 模块，带有 `SkipGlueGeneration=1`。

- [UnrealSharpUtilities.Build.cs](../../../../Plugins/UnrealSharp/Source/UnrealSharpUtilities/UnrealSharpUtilities.Build.cs)
提供 BuildTool 调用、路径与流程辅助。

- [UnrealSharpManagedGlue](../../../../Plugins/UnrealSharp/Source/UnrealSharpManagedGlue)
不是普通 UE 模块，而是 UHT/导出侧的托管生成器实现，负责从反射信息导出 Glue 代码。

## Managed 侧目录地图

Managed 根目录通常是 [Plugins/UnrealSharp/Managed](../../../../Plugins/UnrealSharp/Managed)

关键子目录：

- [Managed/global.json](../../../../Plugins/UnrealSharp/Managed/global.json)
固定 SDK 版本。

- [Managed/UnrealSharp](../../../../Plugins/UnrealSharp/Managed/UnrealSharp)
UnrealSharp 的托管运行时、Source Generator、Core 特性定义等。

- [Managed/UnrealSharpPrograms/UnrealSharpBuildTool](../../../../Plugins/UnrealSharp/Managed/UnrealSharpPrograms/UnrealSharpBuildTool)
命令行构建工具，负责 `GenerateProject`、`GenerateSolution`、`BuildEmitLoadOrder`、`PackageProject` 等动作。

- [Managed/Shared](../../../../Plugins/UnrealSharp/Managed/Shared)
托管侧共享工具和模型定义。

- [Managed/DotNetRuntime](../../../../Plugins/UnrealSharp/Managed/DotNetRuntime)
嵌入式运行时相关资源。

## Script / Glue / Binaries 的关系

这是 UnrealSharp 最容易混淆的一层。

业务脚本项目：

- 项目自己的 C# 项目通常位于 `Script/<ProjectName>/` 或其子目录。
- 插件自己的 C# 项目可位于对应插件根目录下的 `Script/<PluginProjectName>/`。

生成的 Glue 项目：

- 项目主模块 Glue 通常类似 `Script/<ProjectName>.Glue/`
- 插件 Glue 通常类似 `Plugins/<Plugin>/Script/<Plugin>.Glue/`

UHT 生成物：

- 每个 Glue 项目的 `obj/UHT/<Target>/.../*.generated.cs`
- 编译入口由 [UnrealSharp.GeneratedFiles.props](../../../../Plugins/UnrealSharp/UnrealSharp.GeneratedFiles.props) 自动引入。

托管输出：

- 运行期输出通常落在 `Binaries/Managed/net10.0/` 或 `Binaries/Managed/net10.0publish/`
- `BuildEmitLoadOrder` 会根据 `Program.GetOutputPath()` 生成装配加载顺序文件。

## 高价值本地入口

如果只允许看少量文件，优先看这些：

- [Plugins/UnrealSharp/README.md](../../../../Plugins/UnrealSharp/README.md)
- [Plugins/UnrealSharp/UnrealSharp.uplugin](../../../../Plugins/UnrealSharp/UnrealSharp.uplugin)
- [Plugins/UnrealSharp/UnrealSharp.Shared.props](../../../../Plugins/UnrealSharp/UnrealSharp.Shared.props)
- [Plugins/UnrealSharp/UnrealSharp.GeneratedFiles.props](../../../../Plugins/UnrealSharp/UnrealSharp.GeneratedFiles.props)
- [Plugins/UnrealSharp/Managed/global.json](../../../../Plugins/UnrealSharp/Managed/global.json)
- [Plugins/UnrealSharp/Managed/UnrealSharpPrograms/UnrealSharpBuildTool/Program.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharpPrograms/UnrealSharpBuildTool/Program.cs)
- [Plugins/UnrealSharp/Source/UnrealSharpUtilities/Private/CSBuildUtilties.cpp](../../../../Plugins/UnrealSharp/Source/UnrealSharpUtilities/Private/CSBuildUtilties.cpp)
- [Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/GlueGenerator.cs](../../../../Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/GlueGenerator.cs)
- [Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/GlueModuleFactory.cs](../../../../Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/GlueModuleFactory.cs)
