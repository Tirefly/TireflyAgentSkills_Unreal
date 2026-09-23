# Debugging And IDE Workflow

这一篇专门讲 UnrealSharp 的 C# 调试：怎么挂调试器、为什么有时断点不好使、以及几个会让人误判"调试坏了"的坑。

> 路径一律按“相对当前工作区”解析。

## 目录

- 先分清两种需求：热重载 vs 断点调试
- 插件已经替你准备了什么
- 三种 IDE 的接法
- 坑一：Development 编辑器 = Release 的 C#
- 坑二：挂调试器的时机
- 坑三：调试器会拖住热重载
- 坑四：你能单步进哪一层
- 工作流便利：合并原生与托管解决方案
- 决策建议

## 先分清两种需求：热重载 vs 断点调试

这是最容易混淆的一点，先分开：

| 需求 | 手段 | 是否需要调试器 |
|---|---|---|
| 改代码看效果 | 热重载（保存即触发，或 `Ctrl+Alt+F5`） | 不需要 |
| 要断点、看局部变量、单步 | 挂调试器 | 需要 |

**日常迭代应该走热重载。** 保存 → 重载 → 看日志这个循环比断点快得多，也是 UnrealSharp 设计的主动线。只有在逻辑真的绕不清时才需要坐下调断点——因为断点调试有下面这些代价。

## 插件已经替你准备了什么

`BuildEmitLoadOrder` 每次运行都会给每个业务工程生成 `Properties/launchSettings.json`（在 `Build/Scripts/BuildCommands/BuildEmitLoadOrder.cs` 的 `AddLaunchSettings` 里，通过 `LaunchSettingsScaffolding.EnsureProjectLaunchSettings` 落盘）。

生成内容形如：

```json
{
  "profiles": {
    "Development": {
      "commandName": "Executable",
      "executablePath": "<EngineRoot>\\Engine\\Binaries\\Win64\\UnrealEditor.exe",
      "commandLineArgs": "\"<ProjectPath>\\<ProjectName>.uproject\""
    },
    "Debug": {
      "commandName": "Executable",
      "executablePath": "<EngineRoot>\\Engine\\Binaries\\Win64\\UnrealEditor-Win64-DebugGame.exe",
      "commandLineArgs": "\"<ProjectPath>\\<ProjectName>.uproject\""
    }
  }
}
```

要点：

- 路径由 `Build/Scripts/Utilities/LaunchSettingsUtilities.cs` 按平台生成（Windows 用 `UnrealEditor.exe` / `UnrealEditor-Win64-DebugGame.exe`，macOS 用 `UnrealEditor` / `UnrealEditor-Mac-DebugGame`）。
- **这个文件是“存在即跳过”**（`if (File.Exists(LaunchSettingsPath)) return;`），所以你手工改过它之后不会被覆盖——反过来说，插件也不会帮你更新已存在的文件。
- 它通常会被业务工程一起入库（不在 UnrealSharp 的 gitignore 里）。如果不想入库，自己往项目 `.gitignore` 加。

## 三种 IDE 的接法

### Rider

**直接认 `launchSettings.json`。** 打开 `Script/<ProjectName>.sln`（或单个业务 csproj），运行配置下拉里就会出现 `Development` / `Debug` 两个 profile，按 F5 即启动编辑器并挂上调试器。

### Visual Studio

同样认 `launchSettings.json`。打开托管 sln 后，调试目标下拉里选择对应 profile 即可。官方文档里那句 “start the project through the C# project by pressing F5” 指的就是这条路径。

### VSCode

**VSCode 不读 `launchSettings.json`**，需要自己写 `.vscode/launch.json`：

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "UnrealSharp 启动",
      "type": "coreclr",
      "request": "launch",
      "program": "<EngineRoot>\\Engine\\Binaries\\Win64\\UnrealEditor.exe",
      "args": ["<ProjectPath>\\<ProjectName>.uproject"],
      "cwd": "<EngineRoot>\\Engine\\Binaries\\Win64",
      "console": "internalConsole"
    },
    {
      "name": "UnrealSharp 附加",
      "type": "coreclr",
      "request": "attach"
    }
  ]
}
```

需要 C# 扩展（`ms-dotnettools.csharp`）。注意 `.vscode/` 默认**不在** UnrealSharp 的忽略范围内，要自己决定是否入库。

## 坑一：Development 编辑器 = Release 的 C#

**这是最容易踩、也最容易误判的坑。**

`Build/Scripts/Utilities/DotNetSdkUtilities.cs` 里写死了 UE 配置到 .NET 配置的映射：

```csharp
public static string GetDotNetBuildConfiguration(this UnrealTargetConfiguration configuration)
{
    if (configuration == UnrealTargetConfiguration.Debug || configuration == UnrealTargetConfiguration.DebugGame)
    {
        return "Debug";
    }

    if (configuration == UnrealTargetConfiguration.Development || configuration == UnrealTargetConfiguration.Test || configuration == UnrealTargetConfiguration.Shipping)
    {
        return "Release";
    }
    ...
}
```

而编辑器启动时 `BuildUserSolution` 传的是 `FApp::GetBuildConfiguration()`（`CSBuildUtilties.cpp`）。你平时跑的是 Development 编辑器 → **C# 用 `-c Release` 编译**。

后果：断点可能仍然命中，但**局部变量经常看不了、单步会跳、代码被内联**。很容易误判成“UnrealSharp 调试不好使”。

还有个放大因素：托管产物**只有一个目录** `Binaries/Managed/net10.0/`（`DotNetUtilities::GetManagedBinaries()` 只拼 `Binaries/Managed/<netX.Y>`，不带配置名），两种配置会**互相覆盖**。

### 绕法 A（正规）：用 DebugGame 编辑器

`Debug` profile 指向 `UnrealEditor-Win64-DebugGame.exe`。引擎侧这个二进制存在，但**项目模块需要自己先构建出 DebugGame 版本**：

```powershell
& "<EngineRoot>\Engine\Build\BatchFiles\Build.bat" <ProjectName>Editor Win64 DebugGame -Project="<ProjectPath>\<ProjectName>.uproject" -WaitMutex
```

代价是 DebugGame 全量构建慢、占盘大。只在确实要坐下来调一段逻辑时才值得。

### 绕法 B（轻量）：保持 Development 编辑器，手工按 Debug 发一次托管产物

```powershell
dotnet publish "<ProjectPath>\Script\<ProjectName>.sln" -c Debug -p:PublishDir="<ProjectPath>\Binaries\Managed\net10.0\"
```

装配名不变，`*.LoadOrder.json` 照样解析，所以运行时能正常装载，而你会拿到未优化的 C# + 可用局部变量。

**注意这是会话级的**——下次编辑器启动时 `BuildUserSolution` 会把它覆盖回 Release。

## 坑二：挂调试器的时机

插件留了个专用开关，在 `Source/UnrealSharpCore/Private/DotNet/CSDotNetRuntimeHost.cpp`：

```cpp
#if !(UE_BUILD_SHIPPING)
	if (FParse::Param(FCommandLine::Get(), TEXT("-waitformanageddebugger")))
	{
		while (!FPlatformMisc::IsDebuggerPresent());
	}
#endif
```

编辑器启动时会**自旋等待**调试器附着。用法：

```powershell
& "<EngineRoot>\Engine\Binaries\Win64\UnrealEditor.exe" "<ProjectPath>\<ProjectName>.uproject" -waitformanageddebugger
```

然后用 IDE 的 *Attach to Process* 挂上去，它会自己继续跑。

**时序很重要**：这个等待点在 `InitializeUnrealSharp()` 之后、`UCSManager::Initialize()` 之前——也就是说**用户程序集还没加载**。所以在这个窗口期附加，用户装配随后才装载，你设的断点会在装载时绑定。这正是想要的时机，比赌手速在启动瞬间附加可靠得多。

两个限定：

- **只在非 Shipping 构建生效**（`#if !(UE_BUILD_SHIPPING)`），Shipping 包里这个参数是空操作。
- 它只等托管调试器“存在”，不区分挂的是不是正确的进程——别在这期间挂错目标。

## 坑三：调试器会拖住热重载

`Managed/UnrealSharp/UnrealSharp.Plugins/PluginLoader.cs` 里明确写了这个已知问题（引用了 dotnet/runtime#124876）：

> A known Visual Studio/Rider debugger issue may be holding strong references to assembly types, preventing the old assembly from being collected. Hot reload will continue to work with some additional memory overhead. Re-attaching the debugger usually releases these references and allows the assembly to be GC'd on the next hot reload.

机制：热重载靠**可卸载 AssemblyLoadContext** 换装配（`PluginLoader.UnloadPlugin` 会做最多 8 轮 `GC.Collect()` + `WaitForPendingFinalizers()` 尝试回收）。调试器挂着时旧装配可能回收不掉。

影响：**功能不受影响**，只是每次热重载多留一份内存。遇到就重新附加一次调试器，下次热重载会回收。

## 坑四：你能单步进哪一层

托管解决方案（`Script/<ProjectName>.sln`）里**只有你的业务工程**，不含 glue 工程——glue 有独立的解决方案，在 `Intermediate/UnrealSharp/Build/Editor/UnrealSharpGlue.sln`。

这意味着：

- 单步进**你自己的代码**：没问题。
- 单步进 **UnrealSharp 自身的运行时**（`UnrealSharp.dll`、`UnrealSharp.Core.dll` 等）：需要 `Binaries/Managed/net10.0/` 下有对应 `.pdb`。正常构建会生成，但如果做过清理或发布式部署就可能缺。
- 单步进 **glue 生成的 wrapper**：需要打开 glue 解决方案，且那些 `*.generated.cs` 是生成物——**别在里面下断点调试业务逻辑**，它们会随 UHT 重新生成而失效。

另外，业务 csproj 本身很薄（只 import `UnrealSharp.Shared.props`），对模块装配的引用是 `BuildUserGlue` 的 `AddUserProjectReferences` 自动追加的（它读 `GlueCode.LoadOrder.json`，把其中的 dll 作为引用写进 csproj，并**排除**名字含 `RuntimeGlue` 的工程）。所以如果某个模块的类型在 C# 里引用不到，先看那个 load order 文件里有没有它。

## 工作流便利：合并原生与托管解决方案

UnrealSharp 工具栏里有个 **Merge Managed and Native Solution**（`Source/UnrealSharpEditor/Private/UnrealSharpEditor.cpp` 的 `OnMergeManagedSlnAndNativeSln`），作用是把：

- 原生解决方案 `<ProjectPath>\<ProjectName>.sln`
- 托管解决方案 `<ProjectPath>\Script\<ProjectName>.sln`

合并成项目根目录的 **`<ProjectName>.Mixed.sln`**，让你在一个 IDE 实例里同时编 C++ 和 C#。

它会重写 C# 工程的相对路径（`MakePathRelativeTo` 项目根）并合并 `SolutionConfigurationPlatforms` / `NestedProjects` 段。两个源 sln 都必须存在，否则会弹框报错。

## 决策建议

1. **日常迭代不开调试器**——保存 → 热重载 → 看日志。
2. **要断点，先确认优化级别**。如果只是偶尔调一次、不想付 DebugGame 构建的代价，用绕法 B（`dotnet publish -c Debug`）把托管产物刷成 Debug。
3. **要长时间调、且要单步进 C++**，才构建 DebugGame 编辑器走正规路径。
4. **附加困难时用 `-waitformanageddebugger`**，别赌手速。
5. **热重载变慢或内存涨**，重新附加一次调试器释放旧装配引用。

## 相关源码入口

- `Plugins/UnrealSharp/Build/Scripts/Utilities/LaunchSettingsUtilities.cs` —— launchSettings 生成
- `Plugins/UnrealSharp/Build/Scripts/Utilities/DotNetSdkUtilities.cs` —— UE 配置 → .NET 配置映射（坑一根源）
- `Plugins/UnrealSharp/Build/Scripts/Utilities/LaunchSettingsScaffolding.cs` —— 存在即跳过逻辑
- `Plugins/UnrealSharp/Source/UnrealSharpCore/Private/DotNet/CSDotNetRuntimeHost.cpp` —— `-waitformanageddebugger`
- `Plugins/UnrealSharp/Source/UnrealSharpUtilities/Private/CSBuildUtilties.cpp` —— 启动时传的 TargetConfiguration
- `Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Plugins/PluginLoader.cs` —— ALC 卸载与调试器引用问题
- `Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Editor/SolutionManager.cs` —— 热重载用 MSBuildWorkspace 载入解决方案
- `Plugins/UnrealSharp/Managed/UnrealSharp/UnrealSharp.Editor/IncrementalCompilationManager.cs` —— 增量编译与 emit

## 官方参考

- <https://www.unrealsharp.com/getting-started-and-fundamentals/debugging>

> 官方该页只有一句“按 F5 启动并附加调试器”，没有覆盖 IDE 差异与上面这些坑。
