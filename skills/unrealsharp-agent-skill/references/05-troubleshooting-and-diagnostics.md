# Troubleshooting And Diagnostics

## 目录

- 第一层判断：环境还是声明/生成问题
- 75% 启动卡住的标准排查法
- 先看哪些文件
- 先跑哪些命令
- 常见案例
- 哪些日志是非阻塞的

## 第一层判断：环境还是声明/生成问题

如果现象是：

- C++ 编译成功
- UnrealEditor 打开到 75% 左右
- 弹出 `dotnet task failed`

优先怀疑：

- UnrealSharp Glue 生成或 Glue 项目编译失败

而不是：

- 原生 C++ 链接器错误
- 缺少 Visual Studio workload 本身

原因是编辑器在这个阶段经常会额外执行托管链路，例如 `BuildEmitLoadOrder`。

关键入口：

- [CSBuildUtilties.cpp](../../../../Plugins/UnrealSharp/Source/UnrealSharpUtilities/Private/CSBuildUtilties.cpp)
- [BuildEmitLoadOrder.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharpPrograms/UnrealSharpBuildTool/Actions/BuildEmitLoadOrder.cs)

## 75% 启动卡住的标准排查法

推荐顺序：

1. 从报错里提取具体 `*.generated.cs` 文件和行号。
2. 反查对应的原始 C++ 声明。
3. 单独编译受影响的 `.Glue.csproj`。
4. 如有必要，再手工执行 `BuildEmitLoadOrder`。

不要一开始就：

- 全量清库
- 重装整个 IDE
- 修改生成物本身

## 先看哪些文件

对于生成错误，最常见的三类文件：

- 原始反射声明：`Source/.../*.h`
- 生成结果：`Script/.../obj/UHT/.../*.generated.cs`
- 生成器本体：`Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/...`

如果当前工作区 vendored 了插件源码，优先看这些：

- [FunctionExporter.cs](../../../../Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/Exporters/FunctionExporter.cs)
- [PropertyGetterSetterUtilities.cs](../../../../Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/Utilities/PropertyGetterSetterUtilities.cs)
- [GlueGenerator.cs](../../../../Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/GlueGenerator.cs)
- [BuildEmitLoadOrder.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharpPrograms/UnrealSharpBuildTool/Actions/BuildEmitLoadOrder.cs)

## 先跑哪些命令

### 单独编译某个 Glue 工程

```powershell
dotnet build ".\\Script\\[ProjectName].Glue\\[ProjectName].Glue.csproj" -nologo
dotnet build ".\\Plugins\\[PluginName]\\Script\\[PluginName].Glue\\[PluginName].Glue.csproj" -nologo
```

### 重新触发 UHT + UnrealSharp 导出

```powershell
& "[EngineDir]\\Engine\\Build\\BatchFiles\\Build.bat" [ProjectName]Editor Win64 Development -Project="[ProjectPath]\\[ProjectName].uproject" -WaitMutex -NoHotReloadFromIDE
```

### 复现启动阶段托管构建

```powershell
dotnet ".\\Plugins\\UnrealSharp\\Binaries\\Managed\\net10.0\\UnrealSharpBuildTool.dll" --Action BuildEmitLoadOrder --ProjectDirectory "[ProjectPath]" --PluginDirectory "[ProjectPath]\\Plugins\\UnrealSharp" --EngineDirectory "[EngineDir]\\Engine" --ProjectName [ProjectName] --DotNetPath "dotnet" --ActionArgs OutputPath=[ProjectPath]\\Binaries\\Managed clp=ErrorsOnly
```

## 常见案例

### 案例 0：本机能进编辑器，但 fresh clone 打开就报 Glue 错误

现象组合：

- 某个开发机本地已经能正常打开编辑器
- 团队成员 fresh clone 后第一次打开编辑器就在 `BuildEmitLoadOrder` 或某个 `*.Glue.csproj` 处失败
- 报错通常落在 `Script/.../obj/UHT/.../*.generated.cs`
- 某个已生成的 wrapper 或函数库引用了另一个 UnrealSharp 类型，但仓库里缺少对应的 `*.generated.cs`

先区分两类原因：

- 声明或生成器规则本身真的有问题，重新导出后仍然报同样的错误
- 仓库里提交的 UnrealSharp 生成结果不完整，导致 fresh clone 拿到的是一套“能互相引用但缺文件”的已跟踪 glue

推荐检查：

1. 先按项目实际引擎版本跑一次官方 UBT 或 Editor 目标构建，优先以 `.uproject` 的 `EngineAssociation` 为准，不要依赖可能过期的 `Intermediate/TargetInfo*.json`。
2. 单独编译出错的 `.Glue.csproj`，确认具体缺的是哪个类型。
3. 检查缺失类型对应的原始反射声明是否存在，以及同模块 `obj/UHT` 目录里是否真的没有对应的 `*.generated.cs`。
4. 如果重新导出后缺失文件出现，而且 `.Glue.csproj` 编译恢复成功，就把问题归类为“仓库里的已提交 glue 不完整”，而不是声明不可导出。
5. 如果仓库策略是提交 UnrealSharp 的 `obj/UHT` 生成结果，就检查 `.gitignore` 是否至少放行 `Script/**/obj/UHT/**/*.generated.cs`，同时继续忽略其他 `obj` 内容，例如 `project.assets.json`、NuGet 还原产物等。

不要做的事：

- 不要先手改缺失的 `*.generated.cs`
- 不要先假定是成员机器环境问题
- 不要把整个 `obj/` 全量放开到 Git，这会把大量无关中间产物一并纳入版本控制

更稳的结论方式：

- 用官方 UBT 重新导出一次
- 再跑一次出错的 `.Glue.csproj`
- 最后比对“磁盘上存在的 `obj/UHT/**/*.generated.cs`”和“Git 已跟踪的 `obj/UHT/**/*.generated.cs`”是否有差集

### 案例 1：BlueprintNativeEvent + DeterminesOutputType

问题组合：

- `BlueprintNativeEvent`
- 返回值依赖 `DeterminesOutputType`

这类问题要先区分两层：

- 设计层面：这通常是项目 API 设计本身的高风险组合，因为 override 契约和节点的动态类型推导被混在了一起。
- 生成器层面：如果 UnrealSharp 对这种组合处理不够稳健，生成器也可能需要做降级或保护性导出。

常见表现：

- 某些桥接辅助方法里出现未正确绑定的泛型类型
- 最终导致 `generated.cs` 编译错误

设计建议：

- 优先把 `DeterminesOutputType` 放到对外 wrapper 上
- 保持 `BlueprintNativeEvent` 的返回类型和 override 契约稳定

如果当前工作区 vendored 了插件源码，可优先看：

- [FunctionExporter.cs](../../../../Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/Exporters/FunctionExporter.cs)

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

- [PropertyGetterSetterUtilities.cs](../../../../Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/Utilities/PropertyGetterSetterUtilities.cs)

## 哪些日志是非阻塞的

下面这些信息不一定等于失败：

- `Could not find assembly for project ... Skipping.`
- 一些 `CS0169`、`CS0414` 级别的 Glue warning
- 某些 editor-only 或 developer-only glue 缺失但 Action 最终返回 0

真正决定成败的是：

- `UnrealSharpBuildTool` 的退出码
- 具体 `*.Glue.csproj` 是否报 error
- `BuildEmitLoadOrder` 是否最终完成

## 如果插件源码刚更新过

官方 Quickstart 提醒：

- 如果你是通过比较容易产生过期二进制的路径编译的插件，更新 Git 后可能需要清理项目或插件的 `Binaries/`、`Intermediate/`。

参考：

- <https://www.unrealsharp.com/getting-started/quickstart>
