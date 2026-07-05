# Build Generation And Hot Reload

## 目录

- 官方前提与仓库前提
- 从 C++ 构建到 C# Glue 的完整链路
- BuildEmitLoadOrder 的职责
- 编辑器创建项目与热重载行为
- 推荐命令
- 不推荐做法

## 官方前提与通用前提

官方 Quickstart 和 README 的共同点：

- 需要 UE 5.5 - 5.7
- 需要 .NET 10 SDK
- 强烈建议使用 C++ 项目

可参考：

- [Plugins/UnrealSharp/README.md](../../../../Plugins/UnrealSharp/README.md)
- <https://www.unrealsharp.com/getting-started/quickstart>
- <https://www.unrealsharp.com/faq>

如果当前工作区 vendored 了插件源码，还应补看：

- [Managed/global.json](../../../../Plugins/UnrealSharp/Managed/global.json)
- [Directory.Build.props](../../../../Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/Directory.Build.props)

## 从 C++ 构建到 C# Glue 的完整链路

推荐的心智模型是：

`C++ 编译 / UHT -> UnrealSharpManagedGlue 导出 -> Glue 项目生成与依赖更新 -> UnrealSharpBuildTool 构建 Script -> Binaries/Managed 输出`

高价值源码入口如下。

### 1. C++ 侧调用托管 BuildTool

[CSBuildUtilties.cpp](../../../../Plugins/UnrealSharp/Source/UnrealSharpUtilities/Private/CSBuildUtilties.cpp)

- `InvokeUnrealSharpBuildTool(...)` 会拼出 `dotnet UnrealSharpBuildTool.dll --Action ...` 的调用。
- `BuildUserSolution(...)` 当前使用的动作就是 `BuildEmitLoadOrder`。

### 2. 托管 BuildTool 总入口

[Program.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharpPrograms/UnrealSharpBuildTool/Program.cs)

- 解析参数
- 初始化 UnrealSharp 配置
- 调用对应 Action

### 3. 绑定导出

[GlueGenerator.cs](../../../../Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/GlueGenerator.cs)

- `ExporterValidator.ValidateExporter()`
- `PackageExporter.ExportPackages()`
- `PreprocessorExporter.ExportBuildDefines()`
- `FunctionExporter.BindExtensionMethods()`
- `AutocastExporter.BindAutocasts()`

### 4. 自动创建和更新 Glue 项目

[GlueModuleFactory.cs](../../../../Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/GlueModuleFactory.cs)

- 遍历模块
- 为每个模块创建或更新 `<Module>.Glue` 工程
- 自动追加依赖
- 必要时重新生成 solution

### 5. Glue 编译与装配加载顺序

[BuildEmitLoadOrder.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharpPrograms/UnrealSharpBuildTool/Actions/BuildEmitLoadOrder.cs)

- 对 `Script/` 目录执行 `publish`
- 输出装配加载顺序
- 为非 Glue 项目补 launchSettings

## BuildEmitLoadOrder 的职责

这是编辑器打开项目时最容易在日志中出现的托管动作之一。

职责不是单一“编译某个项目”，而是：

- 构建 `Script/` 下的托管项目
- 生成或刷新 `Binaries/Managed/net10.0*` 输出
- 解析项目引用图并生成装配加载顺序

如果这里失败，常见表现就是：

- C++ 已经成功
- UnrealEditor 启动到 75% 左右
- 弹出 `dotnet task failed`
- 日志里出现某个 `*.Glue.csproj` 的 C# 编译错误

## 编辑器创建项目与热重载行为

[UnrealSharpEditor.cpp](../../../../Plugins/UnrealSharp/Source/UnrealSharpEditor/Private/UnrealSharpEditor.cpp)

高价值函数：

- `AddNewProject(...)`
作用：从编辑器里创建新的 C# 项目。

- `LoadNewProject(...)`
作用：创建完成后构建用户脚本项目、加载装配、暂停并恢复热重载。

对应的托管工程创建逻辑见：

- [GenerateProject.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharpPrograms/UnrealSharpBuildTool/Actions/GenerateProject.cs)

## 推荐命令

### 1. 跑一次 UE Editor 目标构建，让 UHT 与 UnrealSharp 重新导出

```powershell
& "[EngineDir]\\Engine\\Build\\BatchFiles\\Build.bat" [ProjectName]Editor Win64 Development -Project="[ProjectPath]\\[ProjectName].uproject" -WaitMutex -NoHotReloadFromIDE
```

### 2. 单独验证受影响的 Glue 项目

```powershell
dotnet build ".\\Script\\[ProjectName].Glue\\[ProjectName].Glue.csproj" -nologo
dotnet build ".\\Plugins\\[PluginName]\\Script\\[PluginName].Glue\\[PluginName].Glue.csproj" -nologo
```

### 3. 手工复现启动阶段的托管构建动作

```powershell
dotnet ".\Plugins\UnrealSharp\Binaries\Managed\net10.0\UnrealSharpBuildTool.dll" \
  --Action BuildEmitLoadOrder \
  --ProjectDirectory "[ProjectPath]" \
  --PluginDirectory "[ProjectPath]\\Plugins\\UnrealSharp" \
  --EngineDirectory "[EngineDir]\\Engine" \
  --ProjectName [ProjectName] \
  --DotNetPath "dotnet" \
  --ActionArgs OutputPath=[ProjectPath]\\Binaries\\Managed clp=ErrorsOnly
```

## 不推荐做法

官方 Quickstart 明确提醒：

- 不要依赖“直接点 `.uproject` 编译插件”的路径来调试 UnrealSharp 问题。
- 如果你更新了插件源码，但走了容易产生过期二进制的路径，可能需要清理项目和插件的 `Binaries/`、`Intermediate/`。

引用：

- <https://www.unrealsharp.com/getting-started/quickstart>
