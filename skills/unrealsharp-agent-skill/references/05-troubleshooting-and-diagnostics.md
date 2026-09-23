# Troubleshooting And Diagnostics

## 目录

- 第一层判断：环境还是声明/生成问题
- 启动卡住的标准排查法
- 先看哪些文件
- 先跑哪些命令
- 常见案例
- 哪些日志是非阻塞的

> 路径一律按“相对当前工作区”解析。

## 第一层判断：环境还是声明/生成问题

如果现象是：

- C++ 编译成功
- UnrealEditor 启动过程中卡住
- 弹出 `dotnet task failed`，或弹出 UnrealSharp 自己的错误对话框

优先怀疑：

- UnrealSharp 的 glue 生成或 glue 工程编译失败
- **或者 SDK 环境没被识别到**

而不是：

- 原生 C++ 链接器错误
- 缺少 Visual Studio workload 本身

原因是编辑器在这个阶段会额外执行托管链路。启动路径在 `Plugins/UnrealSharp/Source/UnrealSharpCore/Private/UnrealSharpCore.cpp`：

```cpp
void FUnrealSharpCoreModule::StartupModule()
{
#if WITH_EDITOR
	if (!UnrealSharp::DotNetUtilities::VerifyCSharpEnvironment() || !UnrealSharp::DotNetUtilities::BuildUserSolution())
	{
		StartupModule();
		return;
	}
#endif

	if (!DotNetRuntimeHost.InitializeManagedRuntime())
	{
		return;
	}

	UCSManager::Get().Initialize();
}
```

关键入口：

- `Plugins/UnrealSharp/Source/UnrealSharpUtilities/Private/CSBuildUtilties.cpp`
- `Plugins/UnrealSharp/Build/Scripts/BuildCommands/BuildEmitLoadOrder.cs`

## 启动卡住的标准排查法

推荐顺序：

1. 先看**有没有错误对话框**，读它的原文。UnrealSharp 的 SDK 检测失败与 bindings 缺失都有明确文案（见下文“案例 3”）。
2. 从报错里提取具体 `*.generated.cs` 文件和行号。
3. 反查对应的原始 C++ 声明。
4. 单独编译受影响的 glue 工程。
5. 如有必要，再手工执行 `BuildEmitLoadOrder`。

不要一开始就：

- 全量清库
- 重装整个 IDE
- 修改生成物本身

### 一个已知的放大器：启动失败会递归

`UnrealSharpCore::StartupModule` 在失败分支里**再次调用自己**且没有重入保护：

```cpp
if (!UnrealSharp::DotNetUtilities::VerifyCSharpEnvironment() || !UnrealSharp::DotNetUtilities::BuildUserSolution())
{
    StartupModule();
    return;
}
```

`UCSManager::bHasInitialized` 存在但在这个路径上没被检查。所以“SDK 未找到 → 弹框 → 递归”会让启动看起来像卡死或刷屏，而不是干脆报错退出。排查时先看日志里同一段是否在重复出现。

## 先看哪些文件

对于生成错误，最常见的三类文件：

- 原始反射声明：`Source/.../*.h`
- 生成结果：`Intermediate/UnrealSharp/UHT/<TargetType>/<ModuleName>/*.generated.cs`
- 生成器本体：`Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/`

如果当前工作区 vendored 了插件源码，优先看这些：

- `Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/Exporters/FunctionExporter.cs`
- `Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/Utilities/PropertyGetterSetterUtilities.cs`
- `Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/GlueGenerator.cs`
- `Plugins/UnrealSharp/Build/Scripts/BuildCommands/BuildEmitLoadOrder.cs`

## 先跑哪些命令

### 单独编译某个 glue 工程

```powershell
dotnet build "[ProjectPath]\Intermediate\UnrealSharp\UHT\Editor\[ModuleName]\[ModuleName].csproj" -nologo
```

插件模块的 glue：

```powershell
dotnet build "[ProjectPath]\Plugins\[PluginName]\Intermediate\UnrealSharp\UHT\Editor\[ModuleName]\[ModuleName].csproj" -nologo
```

### 重新触发 UHT + UnrealSharp 导出

glue 生成挂在 UHT 里，所以 Editor 目标构建就是重新导出的入口：

```powershell
& "[EngineRoot]\Engine\Build\BatchFiles\Build.bat" [ProjectName]Editor Win64 Development -Project="[ProjectPath]\[ProjectName].uproject" -WaitMutex -NoHotReloadFromIDE
```

### 复现启动阶段托管构建

> 占位符：`[EngineRoot]` 指引擎安装根目录（其下有 `Engine\` 子目录）。

```powershell
& "[EngineRoot]\Engine\Build\BatchFiles\RunUAT.bat" BuildEmitLoadOrder -ScriptDir="[ProjectPath]\Plugins\UnrealSharp\Build\Scripts" -Project="[ProjectPath]\[ProjectName].uproject" -OutputPath="[ProjectPath]\Binaries\Managed\net10.0" -TargetConfiguration=Development clp=ErrorsOnly
```

> 旧版的 `dotnet "...\UnrealSharpBuildTool.dll" --Action ...` 写法已失效——该 DLL 不再存在。现在由 UAT 通过 `-ScriptDir` 找到 `UnrealSharp.Automation`。

## 常见案例

### 案例 0：本机能进编辑器，但团队 fresh clone 打开就失败

**注意本代结构与旧版不同**：glue 落在 `Intermediate/` 下，而 `Intermediate/` 通常被 `.gitignore` 排除。所以“仓库里已提交的 glue 不完整”这个旧版经典原因**在当前结构下基本不成立**。

先区分这几类原因：

- 队友没有 .NET 10 SDK，或 SDK 装在非 `Program Files` 路径（见案例 3）
- 队友只打开了 `.uproject` 没编译过 C++，所以 UHT 没跑、glue 从未生成
- `.gitignore` 误伤了 `Script/`（业务源码被排除，导致没有 C# 工程可构建）
- 真的声明或生成器规则有问题，重新导出后仍然报同样的错误

推荐检查：

1. 先按项目实际引擎版本跑一次 Editor 目标构建，优先以 `.uproject` 的 `EngineAssociation` 为准。
2. 单独编译出错的 glue 工程，确认具体缺的是哪个类型。
3. 检查缺失类型对应的原始反射声明是否存在，以及同模块的 UHT 目录里是否真的没有对应的 `*.generated.cs`。
4. 确认 `.gitignore` 放行的是 `Script/**`（业务源码），排除的是 `Intermediate/**` 与 `Script/**/bin|obj`。
5. 确认队友机器上 `dotnet --list-sdks` 能列出 10.x。

不要做的事：

- 不要先手改缺失的 `*.generated.cs`
- 不要先假定是成员机器环境问题
- **不要把 `Intermediate/UnrealSharp/**` 放开到 Git**——引擎侧 glue 有数万个文件

### 案例 1：BlueprintNativeEvent + DeterminesOutputType

问题组合：

- `BlueprintNativeEvent`
- 返回值依赖 `DeterminesOutputType`

这类问题要先区分两层：

- 设计层面：这通常是项目 API 设计本身的高风险组合，因为 override 契约和节点的动态类型推导被混在了一起。
- 生成器层面：如果 UnrealSharp 对这种组合处理不够稳健，生成器也可能需要做降级或保护性导出。

常见表现：

- 某些桥接辅助方法里出现未正确绑定的泛型类型
- 最终导致 `*.generated.cs` 编译错误

设计建议：

- 优先把 `DeterminesOutputType` 放到对外 wrapper 上
- 保持 `BlueprintNativeEvent` 的返回类型和 override 契约稳定

如果当前工作区 vendored 了插件源码，可优先看：

- `Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/Exporters/FunctionExporter.cs`

### 案例 2：SetX(NonConstRefParam) 被当成属性 setter

问题组合：

- 单参数函数
- 名字匹配 `SetX(...)`
- 参数是非 `const` 引用或带 `OutParm` 语义

这类问题更偏生成器规则缺陷，而不是纯设计问题。

常见表现：

- 函数被误生成为 C# 属性 setter
- 生成代码在 `set` 访问器内部处理 out/ref 返回，最终触发类似 `CS0127` 的错误

设计建议：

- 非 `const` 引用参数不要使用典型属性 setter 命名
- 更清晰的动词命名通常更稳

如果当前工作区 vendored 了插件源码，可优先看：

- `Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/Utilities/PropertyGetterSetterUtilities.cs`

### 案例 3：编辑器弹出“找不到 .NET SDK”，但机器上明明装了

现象：编辑器启动时弹出对话框，原文是：

```
UnrealSharp can't be initialized. An installation of .NET 10.0.0 SDK can't be found on your system.
```

检测逻辑在 `Plugins/UnrealSharp/Source/UnrealSharpUtilities/Private/CSDotnetUtilties.cpp` 的 `GetDotNetDirectory()`：

- 读取 `PATH` 环境变量，按分隔符切分
- Windows 下用**字面子串**匹配 `Program Files\dotnet\`（**带结尾反斜杠**）
- 命中后还要确认该目录真实存在
- 版本比较用 `IsVersionGreaterOrEqual(HighestVersion, "10.0.0")`，作用对象是 `<DotNetRoot>/host/fxr/*` 目录名

因此有三种典型的“装了但检测不到”：

1. **SDK 装在用户级路径**（例如 `%LOCALAPPDATA%\Microsoft\dotnet`）——Windows 分支只认 `Program Files` 下的安装。
2. **`PATH` 被改写/规范化过**，结尾反斜杠被剥掉（`C:\Program Files\dotnet\` → `C:\Program Files\dotnet`），`Contains` 匹配失败。在 Git Bash / MSYS 这类会转换 `PATH` 的环境里从命令行启动编辑器时很容易踩到。
3. **只有运行时没有 SDK**——注意 `IsDotNetSdkInstalled()` 实际上只判断“dotnet 目录有没有找到”，并不真的校验 SDK 存在。所以工具栏可能出现，但托管构建会失败。

排查手法：

- 用系统原生环境启动编辑器（不要从会改写 `PATH` 的 shell 里直接起），例如在 PowerShell 里重建 `PATH` 后再 `Start-Process`：
  ```powershell
  $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
  Start-Process -FilePath '[EngineRoot]\Engine\Binaries\Win64\UnrealEditor.exe' -ArgumentList '[ProjectPath]\[ProjectName].uproject','-log'
  ```
- `dotnet --list-sdks` 应列出 10.x。
- 插件内置了一个测试 CVar `UnrealSharp.SimulateNoDotNetSDK`，可以强制走“未找到”分支来验证这条链路。

另一个对话框是 bindings 库缺失：

```
The bindings library could not be found at the following location:
<path>

Most likely, the bindings library failed to build due to invalid generated glue.
```

这个才是真正的“glue 编译失败”信号，指向案例 1/2 的排查路径。

## 哪些日志是非阻塞的

下面这些信息不一定等于失败：

- `Could not find assembly for project ... Skipping.`
- 一些 `CS0169`、`CS0414` 级别的 glue warning
- 某些 editor-only 或 developer-only glue 缺失但 Action 最终返回 0
- `LogGameProjectGeneration: ... requires update` —— `.uproject` 未声明 `SupportedTargetPlatforms` 时的信息级提示

真正决定成败的是：

- `UnrealSharp.Automation` 构建命令的退出码
- 具体 glue 工程是否报 error
- `BuildEmitLoadOrder` 是否最终完成

另外要注意：托管运行时初始化失败走的是 `UE_LOGFMT(LogUnrealSharp, Fatal, ...)`（见 `Plugins/UnrealSharp/Source/UnrealSharpCore/Private/DotNet/CSDotNetRuntimeHost.cpp`），Fatal 会直接中止启动——这类日志不是警告，不要当噪声忽略。

## 如果插件源码刚更新过

官方 Quickstart 提醒：

- 如果你是通过比较容易产生过期二进制的路径编译的插件，更新 Git 后可能需要清理项目或插件的 `Binaries/`、`Intermediate/`。

在本代结构下还要额外注意两点：

- **glue 生成挂在 UHT 上**，所以改了 C++ 反射声明后必须重新跑一次 Editor 目标构建，光改 C# 是刷不出新 glue 的。
- 插件自身有两个程序集产物要一起刷新：`Build/Scripts/bin/Development/UnrealSharp.Automation.dll` 与 `Source/UnrealSharpManagedGlue/bin/**/UnrealSharpManagedGlue.dll`。它们由 UBT 在构建期自动重建，不要手工拷贝。
