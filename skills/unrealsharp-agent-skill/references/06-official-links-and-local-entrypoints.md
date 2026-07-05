# Official Links And Local Entrypoints

## 官方文档

- UnrealSharp 官网：<https://www.unrealsharp.com/>
- Quickstart：<https://www.unrealsharp.com/getting-started/quickstart>
- FAQ：<https://www.unrealsharp.com/faq>
- GitHub 仓库：<https://github.com/UnrealSharp/UnrealSharp>
- Roadmap：<https://github.com/orgs/UnrealSharp/projects/3>
- 文档仓库：<https://github.com/UnrealSharp/unrealsharp.github.io>

## vendored UnrealSharp 项目的本地入口总表

这部分只列“通常在 vendored UnrealSharp 工程里存在”的高价值入口，不列某个具体项目的业务文件。

### UnrealSharp 插件根目录

- [Plugins/UnrealSharp](../../../../Plugins/UnrealSharp)
- [Plugins/UnrealSharp/README.md](../../../../Plugins/UnrealSharp/README.md)
- [Plugins/UnrealSharp/UnrealSharp.uplugin](../../../../Plugins/UnrealSharp/UnrealSharp.uplugin)
- [Plugins/UnrealSharp/UnrealSharp.Shared.props](../../../../Plugins/UnrealSharp/UnrealSharp.Shared.props)
- [Plugins/UnrealSharp/UnrealSharp.GeneratedFiles.props](../../../../Plugins/UnrealSharp/UnrealSharp.GeneratedFiles.props)
- [Plugins/UnrealSharp/Directory.Packages.props](../../../../Plugins/UnrealSharp/Directory.Packages.props)

### UnrealSharp 配置

- [Plugins/UnrealSharp/Config/UnrealSharp.Settings.json](../../../../Plugins/UnrealSharp/Config/UnrealSharp.Settings.json)
- [Plugins/UnrealSharp/Config/DefaultUnrealSharp.ini](../../../../Plugins/UnrealSharp/Config/DefaultUnrealSharp.ini)

### Managed 侧入口

- [Plugins/UnrealSharp/Managed/global.json](../../../../Plugins/UnrealSharp/Managed/global.json)
- [Plugins/UnrealSharp/Managed/UnrealSharpPrograms/UnrealSharpBuildTool/Program.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharpPrograms/UnrealSharpBuildTool/Program.cs)
- [Plugins/UnrealSharp/Managed/UnrealSharpPrograms/UnrealSharpBuildTool/BuildToolOptions.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharpPrograms/UnrealSharpBuildTool/BuildToolOptions.cs)
- [Plugins/UnrealSharp/Managed/UnrealSharpPrograms/UnrealSharpBuildTool/Actions/GenerateProject.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharpPrograms/UnrealSharpBuildTool/Actions/GenerateProject.cs)
- [Plugins/UnrealSharp/Managed/UnrealSharpPrograms/UnrealSharpBuildTool/Actions/BuildEmitLoadOrder.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharpPrograms/UnrealSharpBuildTool/Actions/BuildEmitLoadOrder.cs)

### C# 特性定义

- [Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Core/Attributes/UClassAttribute.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Core/Attributes/UClassAttribute.cs)
- [Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Core/Attributes/UPropertyAttribute.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Core/Attributes/UPropertyAttribute.cs)
- [Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Core/Attributes/UFunctionAttribute.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Core/Attributes/UFunctionAttribute.cs)
- [Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Core/Attributes/UMetaDataAttribute.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Core/Attributes/UMetaDataAttribute.cs)

### UE Source 模块入口

- [Plugins/UnrealSharp/Source/UnrealSharpCore/UnrealSharpCore.Build.cs](../../../../Plugins/UnrealSharp/Source/UnrealSharpCore/UnrealSharpCore.Build.cs)
- [Plugins/UnrealSharp/Source/UnrealSharpEditor/UnrealSharpEditor.Build.cs](../../../../Plugins/UnrealSharp/Source/UnrealSharpEditor/UnrealSharpEditor.Build.cs)
- [Plugins/UnrealSharp/Source/UnrealSharpCompiler/UnrealSharpCompiler.Build.cs](../../../../Plugins/UnrealSharp/Source/UnrealSharpCompiler/UnrealSharpCompiler.Build.cs)
- [Plugins/UnrealSharp/Source/UnrealSharpRuntimeGlue/UnrealSharpRuntimeGlue.Build.cs](../../../../Plugins/UnrealSharp/Source/UnrealSharpRuntimeGlue/UnrealSharpRuntimeGlue.Build.cs)
- [Plugins/UnrealSharp/Source/UnrealSharpUtilities/UnrealSharpUtilities.Build.cs](../../../../Plugins/UnrealSharp/Source/UnrealSharpUtilities/UnrealSharpUtilities.Build.cs)

### 构建与编辑器集成入口

- [Plugins/UnrealSharp/Source/UnrealSharpUtilities/Private/CSBuildUtilties.cpp](../../../../Plugins/UnrealSharp/Source/UnrealSharpUtilities/Private/CSBuildUtilties.cpp)
- [Plugins/UnrealSharp/Source/UnrealSharpEditor/Private/UnrealSharpEditor.cpp](../../../../Plugins/UnrealSharp/Source/UnrealSharpEditor/Private/UnrealSharpEditor.cpp)

### Glue 生成器入口

- [Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/GlueGenerator.cs](../../../../Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/GlueGenerator.cs)
- [Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/GlueModuleFactory.cs](../../../../Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/GlueModuleFactory.cs)
- [Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/Exporters/FunctionExporter.cs](../../../../Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/Exporters/FunctionExporter.cs)
- [Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/Utilities/PropertyGetterSetterUtilities.cs](../../../../Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/Utilities/PropertyGetterSetterUtilities.cs)
- [Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/Directory.Build.props](../../../../Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/Directory.Build.props)

### 生成产物与脚本入口

- [Script](../../../../Script)
- [Binaries/Managed](../../../../Binaries/Managed)

## 快速用法建议

- 只想回答“这个功能归哪一层”：先看本文件。
- 只想回答“为什么启动阶段会调 dotnet”：再看 [02-build-generation-and-hot-reload.md](./02-build-generation-and-hot-reload.md)。
- 只想回答“某个生成错误该先看哪里”：再看 [05-troubleshooting-and-diagnostics.md](./05-troubleshooting-and-diagnostics.md)。
