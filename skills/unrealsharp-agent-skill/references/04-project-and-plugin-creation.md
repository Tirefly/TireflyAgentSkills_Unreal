# Project And Plugin Creation

## 目录

- 官方创建流程
- 通用路径约定
- 编辑器内创建入口
- GenerateProject 的参数语义
- 创建插件 C# 项目
- 创建后会看到什么

## 官方创建流程

官方 Quickstart 的推荐路径是：

1. 把 UnrealSharp 插件放进 `ProjectRoot/Plugins`
2. 生成项目文件
3. 用 IDE 编译 C++ 项目
4. 启动编辑器
5. 首次启动后，通过 UnrealSharp UI 创建 C# 项目

参考：

- <https://www.unrealsharp.com/getting-started/quickstart>

## 通用路径约定

在多数 vendored UnrealSharp 项目里：

- 脚本根目录通常是 `Script/`
- 项目主 Glue 工程通常是 `Script/<ProjectName>.Glue/`
- 插件也可能拥有 `Plugins/<Plugin>/Script/<Plugin>.Glue/`

默认根因见：

- [UnrealSharp.Settings.json](../../../../Plugins/UnrealSharp/Config/UnrealSharp.Settings.json)
- [GenerateProject.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharpPrograms/UnrealSharpBuildTool/Actions/GenerateProject.cs)

## 编辑器内创建入口

创建入口的本地实现可从这里看：

- [UnrealSharpEditor.cpp](../../../../Plugins/UnrealSharp/Source/UnrealSharpEditor/Private/UnrealSharpEditor.cpp)

高价值函数：

- `AddNewProject(...)`
- `LoadNewProject(...)`

Quickstart 里也提到：

- 编辑器顶部可通过 UnrealSharp 图标重新打开 New C# Project 流程。

## GenerateProject 的参数语义

见：

- [GenerateProject.cs](../../../../Plugins/UnrealSharp/Managed/UnrealSharpPrograms/UnrealSharpBuildTool/Actions/GenerateProject.cs)

高价值参数：

- `ProjectFolder`
表示生成目录所在的父目录。

- `ProjectRoot`
必须包含 `.uplugin` 或 `.uproject`，用于确定项目或插件归属。

- `ProjectName`
新项目名。

- `CreateModuleClass`
是否附带默认模块类。

- `EditorOnly`
是否标记为不可发布。

- `Dependencies`
额外项目依赖，会以 `ProjectReference` 的形式写入 `.csproj`。

- `SkipSolutionGeneration`
跳过 solution 刷新。

- `SkipUSharpProjSetup`
跳过 UnrealSharp 的 `.props` 和其他设置注入。

## 创建插件 C# 项目

官方 FAQ 直接说明：

- UnrealSharp 支持 C# 插件项目。

参考：

- <https://www.unrealsharp.com/faq>

如果用户问“项目和插件有什么差别”，回答重点应是：

- 归属的根目录不同
- Glue 项目生成位置不同
- 依赖关系会由 GlueModuleFactory 和 BuildTool 自动维护

## 创建后会看到什么

官方 Quickstart 强调：

- Solution 中会出现用户项目和对应的 Glue 项目
- `ProjectName.Glue` 是互操作层，会随 UHT 和构建刷新
- 不应直接修改它

参考：

- <https://www.unrealsharp.com/getting-started/quickstart>
