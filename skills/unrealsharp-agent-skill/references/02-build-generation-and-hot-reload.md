# Build Generation And Hot Reload

## 目录

- 官方前提与通用前提
- 从 C++ 构建到 C# glue 的完整链路
- UnrealSharp.Automation 与 BuildCommand 派发
- BuildEmitLoadOrder 与 LoadOrder.json
- 编辑器创建项目与热重载行为
- 推荐命令
- 不推荐做法

> 路径一律按“相对当前工作区”解析。

## 官方前提与通用前提

官方 Quickstart 和 README 的共同点：

- 需要 UE 5.6 - 5.8
- 需要 .NET 10.0.5 或更新
- 强烈建议使用 C++ 项目

可参考：

- `Plugins/UnrealSharp/README.md`
- <https://www.unrealsharp.com/getting-started/quickstart>
- <https://www.unrealsharp.com/faq>

如果当前工作区 vendored 了插件源码，还应补看：

- `Plugins/UnrealSharp/Managed/global.json`
- `Plugins/UnrealSharp/UnrealSharp.Automation.props`

## 从 C++ 构建到 C# glue 的完整链路

推荐的心智模型是：

```
C++ 构建
  └─ UBT 发现 .ubtplugin.csproj（UnrealSharpManagedGlue）
       └─ UHT 阶段运行 [UhtExporter] Program.Main
            ├─ GlueGenerator.GenerateBindings()      导出 C++ 反射 → *.generated.cs
            ├─ ModuleFactory.SyncModuleProjects()     为每个模块生成/更新 glue csproj
            └─ BuildUtilities.GenerateUserSolution()  刷新用户 sln
编辑器启动
  └─ UnrealSharpCore::StartupModule
       ├─ VerifyCSharpEnvironment()                  检查 SDK 与 bindings 库
       ├─ BuildUserSolution()                        走 UAT 跑 BuildUserSolution 命令
       └─ InitializeManagedRuntime() + UCSManager::Initialize()
```

高价值源码入口如下。

### 1. UBT 插件发现

引擎侧负责发现（不在插件仓里）：

- `.ubtplugin.csproj` 扩展名匹配（`EpicGames.Build/System/Rules.cs`）
- 只递归 `.uplugin` 所在目录的 `Source` 与 `Build` 子目录
- `EnumerateUbtPlugins()` / `BuildUbtPlugins()` 在 `EpicGames.Build/System/EnumeratePlugins.cs`

插件侧声明：

- `Source/UnrealSharpManagedGlue/UnrealSharpManagedGlue.ubtplugin.csproj`
  其中 `BuildAutomation` target 会先构建 `Build/Scripts/UnrealSharp.Automation.csproj` 到自己的 `$(TargetDir)`。

### 2. UHT 导出器入口

`Source/UnrealSharpManagedGlue/Program.cs`

- `[UnrealHeaderTool]` 标记类，`[UhtExporter(Name = "UnrealSharpCore", ...)]` 标记导出方法。
- 导出流程：`CleanOldExportedFiles()` → `BuildBindings()` → `SyncModuleProjects()` → `GenerateUserSolution()`。

### 3. 绑定导出

`Source/UnrealSharpManagedGlue/GlueGenerator.cs`

- 从 UHT 收集到的反射信息生成 `*.generated.cs`。

### 4. 自动创建和更新 glue 工程

`Source/UnrealSharpManagedGlue/ModuleFactory.cs` 与 `Source/UnrealSharpManagedGlue/Utilities/ModuleUtilities.cs`

- 遍历模块，为每个模块创建或更新 `<ModuleName>.csproj`。
- 路径解析：
  ```csharp
  string root = EmitsToProjectDirectory ? GeneratorStatics.Factory.Session.ProjectDirectory! : ModuleRoot;
  GlueOutputDirectory = PathUtilities.GetUhtGeneratedModuleOutputPath(root, GeneratorStatics.TargetType, ModuleName);
  CsProjPath = Path.Combine(GlueOutputDirectory, $"{ModuleName}.csproj");
  ```
- 生成时带上 `SkipIncludeAnalyzers=true`（glue 工程不挂 Analyzer）。
- 通过 `UnrealSharpAutomationUtilities.InvokeUnrealSharpAutomation(...)` 回调 Automation 命令（`BuildUserGlue` / `GenerateProject` / `UpdateProjectDependencies`）。

### 5. C++ 侧如何调起托管构建

`Source/UnrealSharpUtilities/Private/CSBuildUtilties.cpp`

**关键变化**：不再拼 `dotnet UnrealSharpBuildTool.dll --Action ...`，而是调 **UAT**：

```cpp
bool UnrealSharp::Build::InvokeUnrealSharpAutomation(const FString& BuildAction, const TMap<FString, FString>* ActionArgs, const FCSCommandError& OnError)
{
	FString Arguments;
	BuildArguments(BuildAction, ActionArgs, Arguments);

	int32 ReturnCode = 0;
	FString Output;
	return Process::InvokeCommand(FSerializedUATProcess::GetUATPath(), Arguments, ReturnCode, Output, nullptr, OnError);
}
```

参数构造（`BuildArguments`）只传三样东西：动作名、`-ScriptDir=<插件>/Build/Scripts`、`-Project=<uproject>`，其余走 `-Key=Value`：

```cpp
OutArgs += BuildAction;
OutArgs += FString::Printf(TEXT(" -ScriptDir=\"%s\""), *FPaths::Combine(PluginFolder, TEXT("Build"), TEXT("Scripts")));
OutArgs += FString::Printf(TEXT(" -Project=\"%s\""), *FPaths::ConvertRelativePathToFull(FPaths::GetProjectFilePath()));
```

`-ScriptDir` 是 UAT 的标准选项（额外的 .csproj 搜索目录），UAT 据此编译并发现 `UnrealSharp.Automation` 里的 `BuildCommand`。

C++ 侧可用的动作名在 `Source/UnrealSharpUtilities/Public/CSBuildActionUtilities.h`：

```cpp
inline constexpr const TCHAR* GenerateProject = TEXT("GenerateProject");
inline constexpr const TCHAR* GenerateUserSolution = TEXT("GenerateUserSolution");
inline constexpr const TCHAR* BuildEmitLoadOrder = TEXT("BuildEmitLoadOrder");
inline constexpr const TCHAR* BuildUserSolution = TEXT("BuildUserSolution");
inline constexpr const TCHAR* PackageProject = TEXT("PackageProject");
```

> 旧版的 `GenerateSolution` 已从 C++ 动作表移除（只作为 Automation 内部命令保留）。旧版的 `BuildUserSolution` 曾是 `BuildEmitLoadOrder` 的别名，现在是一个真实命令，内部再链到 `BuildEmitLoadOrder`。

## UnrealSharp.Automation 与 BuildCommand 派发

`Build/Scripts/BuildCommands/` 下全部命令（均继承 `BuildCommand`）：

| 命令 | 职责 |
|---|---|
| `GenerateProject` | 生成新 C# 工程（.csproj + 可选模块类） |
| `GenerateUserSolution` | 生成/刷新用户 sln |
| `GenerateSolution` | 内部命令，被上面两个调用 |
| `UpdateProjectDependencies` | 同步工程引用依赖 |
| `BuildSolution` | 构建指定 sln |
| `BuildUserGlue` | 构建 glue 解决方案，产出 glue 装配 |
| `BuildUserSolution` | 构建用户解决方案，内部链到 `BuildEmitLoadOrder` |
| `BuildEmitLoadOrder` | 构建 + 生成装配加载顺序 + 补 launchSettings |
| `PackageProject` | 打包（含写 `UnrealSharpBuild.flag`） |
| `StageUnrealSharp` | 暂存插件内容 |

派发方式（`Build/Scripts/Utilities/CommandUtilities.cs`）——按类名反射查找，**没有 `Main()`**：

```csharp
foreach (Type Type in Assembly.GetExecutingAssembly().GetTypes())
{
    if (Type.Name != commandName) { continue; }
    BuildCommand CommandInstance = (BuildCommand)Activator.CreateInstance(Type)!;
```

## BuildEmitLoadOrder 与 LoadOrder.json

`Build/Scripts/BuildCommands/BuildEmitLoadOrder.cs`

职责不是单一“编译某个项目”，而是三件事：

1. 以 `publish: true` 构建解决方案（产物直接落到 `OutputPath`）
2. 生成装配加载顺序清单
3. 为每个非 glue 托管工程补 `Properties/launchSettings.json`

输出位置由 `PathUtilities.BuildOutputPath(rootDirectory)` 决定：

```
<root>/Binaries/Managed/net10.0/
```

加载顺序清单有两个（`Build/Scripts/Utilities/LoadOrderUtilities.cs`）：

| 名称 | Priority | Collectible | 产出者 |
|---|---|---|---|
| `GlueCode.LoadOrder.json` | 100 | `false` | `BuildUserGlue` |
| `UserCode.LoadOrder.json` | 0 | `true` | `BuildUserSolution` |

文件结构（`Managed/Shared/AssemblyUtilities.cs`）：

```json
{
  "Priority": 100,
  "Collectible": false,
  "LoadOrder": ["TcsCore", "TcsEffect", "..."]
}
```

`LoadOrder` 是对 PE 元数据引用做**真实拓扑排序**（Kahn 算法，有环会抛异常）得出的顺序。

运行时消费：`Source/UnrealSharpCore/Private/CSManager.cpp` 的 `InitialAssemblyLoad` 扫描 `*.LoadOrder.json`，按 `Priority` **降序**装载（`CSProjectUtilities.cpp` 里排序）。`Collectible` 决定该装配是否参与热重载卸载。

`RuntimeGlue` 后缀有特殊含义：`BuildUserGlue.cs` 在自动补 glue 引用时会排除名字含 `RuntimeGlue` 的工程——它是 C++ 模块 `UnrealSharpRuntimeGlue` 的 C# 对应物，不是模块 glue。

### 一个遗留的失效判断

`BuildEmitLoadOrder.cs` 里还有一个 `.Glue` 后缀过滤器：

```csharp
private const string GlueProjectSuffix = ".Glue";
// ...
if (ProjectDirectory.Name.EndsWith(GlueProjectSuffix, StringComparison.Ordinal))
{
    continue;
}
```

它本意是“给 glue 工程补 launchSettings 时跳过”，但**当前 glue 工程已经不带 `.Glue` 后缀了**，所以这个判断现在恒不成立——它是改名后遗留的死代码，不是现行约定。如果你看到这段代码，不要据此认为 glue 工程仍叫 `*.Glue`。

如果这里失败，常见表现就是：

- C++ 已经成功
- UnrealEditor 启动卡住
- 弹出 `dotnet task failed`
- 日志里出现某个 glue 工程的 C# 编译错误

## 编辑器创建项目与热重载行为

编辑器集成入口在 `Source/UnrealSharpEditor/Private/UnrealSharpEditor.cpp`，UI 在 `Source/UnrealSharpEditor/Private/Slate/`。

### 热重载是真的运行时热重载

不是“编译后重启”，而是进程内 Roslyn 增量编译 + 可卸载 ALC 重载：

- `Source/UnrealSharpEditor/Public/HotReload/CSHotReloadSubsystem.h` / `Private/HotReload/CSHotReloadSubsystem.cpp` —— `UCSHotReloadSubsystem`
- `Source/UnrealSharpEditor/Private/HotReload/CSHotReloadUtilities.cpp`
- `Managed/UnrealSharp/UnrealSharp.Editor/IncrementalCompilationManager.cs`
- `Managed/UnrealSharp/UnrealSharp.Plugins/PluginLoader.cs` —— ALC 装载/卸载

执行体（`PerformHotReload`）做的是：按依赖顺序排序脏装配 → 重新编译 → 依次 `UnloadAssembly()` → 反向 `LoadAssembly()` → 重建受影响的 Blueprint。

触发路径有四条：

1. 目录监视器发现 `.cs` 变化（保存即触发）
2. PIE 退出时
3. 编辑器重新获得焦点时
4. 手动：`Ctrl+Alt+F5`

行为由 `UCSUnrealSharpEditorSettings::AutomaticHotReloading` 控制，枚举 `EAutomaticHotReloadMethod`：`OnScriptSave`（默认）/ `OnEditorFocus` / `Off`。

手动快捷键（`Source/UnrealSharpEditor/Private/CSEditorCommands.cpp`）：

| 命令 | 快捷键 |
|---|---|
| Force Hot Reload | `Ctrl+Alt+F5` |
| Regenerate Solution | `Ctrl+Alt+F9` |

另有 `PauseHotReload` / `ResumeHotReload`，会在屏幕上给通知；编辑器启动时会以 `Waiting for initial C# load...` 为理由先暂停。

## 推荐命令

> 占位符约定：`[EngineRoot]` 指**引擎安装根目录**（例如 `E:\UnrealEngine\UE_5.8`，其下有 `Engine\` 子目录）；`[ProjectPath]` 指工程根目录；`[ProjectName]` 指 `.uproject` 的文件名主干。

### 1. 跑一次 UE Editor 目标构建，让 UHT 与 UnrealSharp 重新导出

glue 生成挂在 UHT 里，所以这条命令同时完成“重新导出 + 重新生成 glue 工程”：

```powershell
& "[EngineRoot]\Engine\Build\BatchFiles\Build.bat" [ProjectName]Editor Win64 Development -Project="[ProjectPath]\[ProjectName].uproject" -WaitMutex -NoHotReloadFromIDE
```

### 2. 单独验证受影响的 glue 工程

```powershell
dotnet build "[ProjectPath]\Intermediate\UnrealSharp\UHT\Editor\[ModuleName]\[ModuleName].csproj" -nologo
```

插件模块的 glue 同理，只是根目录换成插件：

```powershell
dotnet build "[ProjectPath]\Plugins\[PluginName]\Intermediate\UnrealSharp\UHT\Editor\[ModuleName]\[ModuleName].csproj" -nologo
```

### 3. 手工复现启动阶段的托管构建动作

启动时走的是 UAT + `-ScriptDir`：

```powershell
& "[EngineRoot]\Engine\Build\BatchFiles\RunUAT.bat" BuildEmitLoadOrder -ScriptDir="[ProjectPath]\Plugins\UnrealSharp\Build\Scripts" -Project="[ProjectPath]\[ProjectName].uproject" -OutputPath="[ProjectPath]\Binaries\Managed\net10.0" -TargetConfiguration=Development clp=ErrorsOnly
```

> 旧版那种 `dotnet "...\UnrealSharpBuildTool.dll" --Action BuildEmitLoadOrder --ProjectDirectory ... --PluginDirectory ...` 的写法**已经失效**，该 DLL 不再存在。

## 不推荐做法

官方 Quickstart 明确提醒：

- 不要依赖“直接点 `.uproject` 编译插件”的路径来调试 UnrealSharp 问题。
- 如果你更新了插件源码，但走了容易产生过期二进制的路径，可能需要清理项目和插件的 `Binaries/`、`Intermediate/`。

补充（本项目实践）：**不要提交 `Intermediate/UnrealSharp/**`**。它是生成物，且体量巨大（引擎侧单是 glue 就有数万个文件）。团队协作靠“各自构建一次”而不是提交生成结果。
