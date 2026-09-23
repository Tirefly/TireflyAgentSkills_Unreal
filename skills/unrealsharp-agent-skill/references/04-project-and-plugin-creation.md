# Project And Plugin Creation

## 目录

- 官方创建流程
- 通用路径约定
- 编辑器内创建入口
- GenerateProject 的参数语义
- 创建插件 C# 项目
- 创建后会看到什么

> 路径一律按“相对当前工作区”解析。

## 官方创建流程

官方 Quickstart 的推荐路径是：

1. 把 UnrealSharp 插件放进 `ProjectRoot/Plugins`
2. 生成项目文件
3. 用 IDE 编译 C++ 项目（这一步同时完成 glue 生成）
4. 启动编辑器
5. 首次启动后，通过 UnrealSharp UI 创建 C# 项目

参考：<https://www.unrealsharp.com/getting-started/quickstart>

## 通用路径约定

在多数 vendored UnrealSharp 项目里：

- 脚本根目录是 `Script/`（由 `Config/UnrealSharp.Settings.json` 的 `ScriptDirectoryName` 决定）
- 项目自己的 C# 工程位于 `Script/<ModuleName>/`
- 插件自己的 C# 工程位于 `Plugins/<Plugin>/Script/<ModuleName>/`
- **glue 工程不在这里**，见下

### glue 工程落在哪

glue 工程路径由 `ModuleFactory` 的 `ResolveOutputPaths()` 决定：

```csharp
string root = EmitsToProjectDirectory ? GeneratorStatics.Factory.Session.ProjectDirectory! : ModuleRoot;
GlueOutputDirectory = PathUtilities.GetUhtGeneratedModuleOutputPath(root, GeneratorStatics.TargetType, ModuleName);
CsProjPath = Path.Combine(GlueOutputDirectory, $"{ModuleName}.csproj");
```

展开后的完整路径：

```
<root>/Intermediate/UnrealSharp/UHT/<TargetType>/<ModuleName>/<ModuleName>.csproj
```

其中 `<root>` 分两种情况：

- **引擎模块且带扩展**（`EmitsToProjectDirectory == true`）→ 落到**项目**的 `Intermediate/`，并沿依赖关系传播（`PropagateProjectRedirection`）
- **其他模块**（项目模块、插件模块）→ 落到**该模块自己的** `Intermediate/`

所以你会看到 glue 分散在三处：插件自己的 `Plugins/UnrealSharp/Intermediate/`（引擎侧）、各插件模块的 `Plugins/<插件>/Intermediate/`、以及项目模块的 `Intermediate/`。这是设计如此，不是配置错误。

> 旧版文档里的 `Script/<ProjectName>.Glue/` 与 `Plugins/<Plugin>/Script/<Plugin>.Glue/` **已经不存在**。`.Glue` 后缀与 `obj/UHT/` 中间层都是历史结构。

默认根因见：

- `Plugins/UnrealSharp/Config/UnrealSharp.Settings.json`
- `Plugins/UnrealSharp/Source/UnrealSharpManagedGlue/Utilities/ModuleUtilities.cs`

## 编辑器内创建入口

创建入口的实现分布在：

- `Plugins/UnrealSharp/Source/UnrealSharpEditor/Private/UnrealSharpEditor.cpp` —— 命令与流程编排
- `Plugins/UnrealSharp/Source/UnrealSharpEditor/Private/Slate/CSNewProjectWizard.cpp` —— 新建工程向导
- `Plugins/UnrealSharp/Source/UnrealSharpEditor/Private/Slate/CSProjectDestination.cpp` —— 归属（项目/插件）与已有工程枚举
- `Plugins/UnrealSharp/Source/UnrealSharpEditor/Private/Slate/SCSTypeWizard.cpp` —— 新建 C# 类型向导

Quickstart 里也提到：编辑器顶部可通过 UnrealSharp 图标重新打开 New C# Project 流程。

编辑器命令（`Source/UnrealSharpEditor/Private/CSEditorCommands.cpp`）包括 `Create New C# Project`、`Create New C# Type`、`Open C# Solution`、`Merge Managed and Native Solution`、`Package Project`、`Open Settings...` 等。

### 已有工程的枚举规则

`CSProjectDestination.cpp` 的 `GatherProjects` 会递归扫描归属目录下的 `*.csproj`，并做两类过滤：

```cpp
if (FullProjectFile.Contains(TEXT("/obj/")) || FullProjectFile.Contains(TEXT("/bin/")))
{
    continue;
}

// ...
if (ProjectName.EndsWith(TEXT(".RuntimeGlue")))
{
    continue;
}
```

- 跳过 `obj/` 与 `bin/` 下的工程（即 glue 工程与中间产物不会出现在下拉里）
- 跳过 `*.RuntimeGlue` 工程（它是自动维护的，不该被用户选中）

`GatherOwners` 会把“当前项目”与所有**位于 `Plugins/` 下且非 UnrealSharp 自身**的已启用插件列为可选归属。

## GenerateProject 的参数语义

见 `Plugins/UnrealSharp/Build/Scripts/BuildCommands/GenerateProject.cs`。该命令自带 `[Help(...)]` 声明：

| 参数 | 语义 |
|---|---|
| `ProjectFolder=<Path>` | **必填**，新工程所在目录 |
| `ProjectName=<Name>` | **必填**，新工程名 |
| `CreateModuleClass` | 是否附带默认模块类（`Module.template`） |
| `GenerateSolution` | 生成后是否刷新 solution |
| `RunUSharpProjectSetup` | 是否接着做 launchSettings 与首次构建 |
| `EditorOnly` | 标记为不可发布（写 `IsEditorOnly`/`IsPublishable`） |
| `Dependencies=<Path>+<Path>` | 额外工程依赖，写成 `ProjectReference` |
| `SkipIncludeAnalyzers` | 生成的 csproj 不引用 UnrealSharp Analyzer |
| `CompileIncludeFolder=<Path>` | 额外纳入编译的目录（glue 生成时用它挂扩展目录） |

命令做的事：`WriteProjectTemplate` → 可选 `WriteModuleTemplate` → `UpdateCsprojDocument`（注入 `UnrealSharp.Shared.props` 的相对路径导入、依赖、编译目录、EditorOnly/分析器开关）。

模板文件在 `Plugins/UnrealSharp/Templates/`：

- `Csproj.template` —— 新工程的最小 `.csproj`（只含 `TargetFramework`/`ImplicitUsings`/`Nullable`，其余靠 `Shared.props` 导入补齐）
- `Module.template` —— `CreateModuleClass` 时生成的模块类，带 `[UModule]` 与 `IModuleInterface`
- `Blank/`、`CSharpOnly/` —— 这两个是**编辑器 Plugin Browser 的插件模板**，不是 `GenerateProject` 用的

> 旧版文档提到的 `ProjectRoot`、`SkipSolutionGeneration`、`SkipUSharpProjSetup` 这几个参数**已经不存在**，不要照旧写。

## 创建插件 C# 项目

官方 FAQ 直接说明：UnrealSharp 支持 C# 插件项目。

参考：<https://www.unrealsharp.com/faq>

创建路径有两条，**这两条是不同入口，别混为一谈**：

1. **编辑器 New C# Project 向导**：归属下拉里选择某个插件，工程会落到 `Plugins/<Plugin>/Script/<Name>/`。这是“给已有插件加 C# 工程”。
2. **Plugin Browser 模板**：UnrealSharp 向编辑器注册了两个插件模板（`UnrealSharpEditor.cpp` 的 `RegisterPluginTemplates`）：
   - `Blank`（显示名 `Blank`）—— 标准空插件
   - `CSharpOnly`（显示名 **`C# Only`**，描述 “Create a blank plugin that can only contain content and C# scripts.”）—— 创建时就走 C# 路线

   这是“从零建一个 C# 插件”，入口在 Plugin Browser 而不是 UnrealSharp 工具栏。

如果用户问“项目和插件有什么差别”，回答重点应是：

- 归属根目录不同（`Script/` vs `Plugins/<Plugin>/Script/`）
- glue 工程的落盘根目录不同（项目模块在项目 `Intermediate/`，插件模块在插件自己的 `Intermediate/`）
- 依赖关系由 `ModuleFactory` 和 Automation 命令自动维护

### 一条重要的边界

**自动 glue 生成不会给插件写 C# 源码。** 它只为插件模块生成 glue 工程，且落在 `Plugins/<Plugin>/Intermediate/` 下——该目录在标准 Unreal 工程模板里就被 `.gitignore` 的 `Intermediate/*` 覆盖，所以插件子模块的工作区不会被弄脏。

真正会改动插件目录的是**上面第 1 条的手动操作**：向导会往 `Plugins/<Plugin>/Script/` 写东西，而那个路径**不在任何 gitignore 里**。这是设计意图（为插件写的 C# 源码本就该入库），但要知道它是手动的、且会改子模块。

## 创建后会看到什么

官方 Quickstart 强调：

- Solution 中会出现用户项目和对应的 glue 工程
- glue 工程是互操作层，会随 UHT 和构建刷新
- 不应直接修改它

在本代结构下，还要补充两点：

- glue 工程在 `Intermediate/` 下，**不要提交进 Git**，也不要手动编辑。
- 业务工程的 `.csproj` 很薄——它主要靠 `UnrealSharp.Shared.props` 导入拿到运行时、Analyzer、Source Generator 的引用。
