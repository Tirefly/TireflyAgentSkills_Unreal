# Official Links And Local Entrypoints

> 路径一律按“相对当前工作区”解析。Skill 本体住在 `~/.agents/skills/` 下，与工程目录没有稳定相对关系，故本文件全部使用工作区相对路径而不是链接。

## 官方文档

- UnrealSharp 官网：<https://www.unrealsharp.com/>
- Quickstart：<https://www.unrealsharp.com/getting-started/quickstart>
- FAQ：<https://www.unrealsharp.com/faq>
- GitHub 仓库：<https://github.com/UnrealSharp/UnrealSharp>
- Roadmap：<https://github.com/orgs/UnrealSharp/projects/3>
- 文档仓库：<https://github.com/UnrealSharp/unrealsharp.github.io>
- Discord：<https://discord.gg/QHb8VjNptE>

## vendored UnrealSharp 项目的本地入口总表

这部分只列“通常在 vendored UnrealSharp 工程里存在”的高价值入口，不列某个具体项目的业务文件。

### UnrealSharp 插件根目录

- `Plugins/UnrealSharp`
- `Plugins/UnrealSharp/README.md`
- `Plugins/UnrealSharp/UnrealSharp.uplugin`
- `Plugins/UnrealSharp/UnrealSharp.Shared.props`
- `Plugins/UnrealSharp/UnrealSharp.Build.props`
- `Plugins/UnrealSharp/UnrealSharp.Automation.props`
- `Plugins/UnrealSharp/UnrealSharp.AOT.props`
- `Plugins/UnrealSharp/Directory.Packages.props`

### UnrealSharp 配置

- `Plugins/UnrealSharp/Config/UnrealSharp.Settings.json`
- `Plugins/UnrealSharp/Config/DefaultUnrealSharp.ini`
- `Plugins/UnrealSharp/Config/Default.UnrealSharpTypes.json`

### 构建侧（Automation 命令）

- `Plugins/UnrealSharp/Build/Scripts/UnrealSharp.Automation.csproj`
- `Plugins/UnrealSharp/Build/Scripts/BuildCommands/GenerateProject.cs`
- `Plugins/UnrealSharp/Build/Scripts/BuildCommands/BuildEmitLoadOrder.cs`
- `Plugins/UnrealSharp/Build/Scripts/BuildCommands/BuildUserGlue.cs`
- `Plugins/UnrealSharp/Build/Scripts/BuildCommands/BuildUserSolution.cs`
- `Plugins/UnrealSharp/Build/Scripts/Utilities/CommandUtilities.cs`
- `Plugins/UnrealSharp/Build/Scripts/Utilities/LoadOrderUtilities.cs`
- `Plugins/UnrealSharp/Build/Scripts/Utilities/PathUtilities.cs`

### Managed 侧入口

- `Plugins/UnrealSharp/Managed/global.json`
- `Plugins/UnrealSharp/Managed/Shared/AssemblyUtilities.cs`（装配加载顺序算法）
- `Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Core/`
- `Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Analyzers/`
- `Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.SourceGenerators/`
- `Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.GlueGenerator/`

### C# 特性定义

- `Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Core/Attributes/UClassAttribute.cs`
- `Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Core/Attributes/UPropertyAttribute.cs`
- `Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Core/Attributes/UFunctionAttribute.cs`
- `Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Core/Attributes/UMetaDataAttribute.cs`
- `Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Core/Attributes/MetaTags.cs`

### UE Source 模块入口

- `Plugins/UnrealSharp/Source/UnrealSharpCore/UnrealSharpCore.Build.cs`
- `Plugins/UnrealSharp/Source/UnrealSharpEditor/UnrealSharpEditor.Build.cs`
- `Plugins/UnrealSharp/Source/UnrealSharpCompiler/UnrealSharpCompiler.Build.cs`
- `Plugins/UnrealSharp/Source/UnrealSharpRuntimeGlue/UnrealSharpRuntimeGlue.Build.cs`
- `Plugins/UnrealSharp/Source/UnrealSharpUtilities/UnrealSharpUtilities.Build.cs`

### 构建与编辑器集成入口

- `Plugins/UnrealSharp/Source/UnrealSharpUtilities/Private/CSBuildUtilties.cpp`
- `Plugins/UnrealSharp/Source/UnrealSharpUtilities/Public/CSBuildActionUtilities.h`
- `Plugins/UnrealSharp/Source/UnrealSharpUtilities/Private/CSDotnetUtilties.cpp`
- `Plugins/UnrealSharp/Source/UnrealSharpCore/Private/UnrealSharpCore.cpp`
- `Plugins/UnrealSharp/Source/UnrealSharpEditor/Private/UnrealSharpEditor.cpp`
- `Plugins/UnrealSharp/Source/UnrealSharpEditor/Private/CSEditorCommands.cpp`

### 热重载入口

- `Plugins/UnrealSharp/Source/UnrealSharpEditor/Public/HotReload/CSHotReloadSubsystem.h`
- `Plugins/UnrealSharp/Source/UnrealSharpEditor/Private/HotReload/CSHotReloadSubsystem.cpp`
- `Plugins/UnrealSharp/Source/UnrealSharpEditor/Private/HotReload/CSHotReloadUtilities.cpp`
- `Plugins/UnrealSharp/Source/UnrealSharpEditor/Public/CSUnrealSharpEditorSettings.h`
- `Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Editor/IncrementalCompilationManager.cs`

### Glue 生成器入口

- `Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/Program.cs`（UHT 导出器入口）
- `Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/UnrealSharpManagedGlue.ubtplugin.csproj`
- `Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/GlueGenerator.cs`
- `Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/ModuleFactory.cs`
- `Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/Utilities/ModuleUtilities.cs`
- `Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/Exporters/FunctionExporter.cs`
- `Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/Utilities/PropertyGetterSetterUtilities.cs`

### 生成产物与脚本入口

- `Script/`（业务 C# 源码）
- `Intermediate/UnrealSharp/UHT/<TargetType>/<Module>/`（glue 工程与 `*.generated.cs`，**生成物，勿提交**）
- `Binaries/Managed/net10.0/`（托管装配与 `*.LoadOrder.json`）

## 快速用法建议

- 只想回答“这个功能归哪一层”：先看本文件。
- 只想回答“为什么启动阶段会调 dotnet”：再看 [02-build-generation-and-hot-reload.md](./02-build-generation-and-hot-reload.md)。
- 只想回答“某个生成错误该先看哪里”：再看 [05-troubleshooting-and-diagnostics.md](./05-troubleshooting-and-diagnostics.md)。
