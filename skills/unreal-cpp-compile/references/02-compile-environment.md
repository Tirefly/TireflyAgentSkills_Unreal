# 编译环境确定

本文件覆盖编译环境的确定规则：引擎安装目录约定、UnrealBuildTool 路径验证、Target 与 Config 的选择、何时需要先刷新项目文件。本文件是用户级唯一规范中 Unreal Engine 安装目录规则的详细承载位置。

## 目录

- [引擎安装目录约定](#引擎安装目录约定)
- [验证 UnrealBuildTool](#验证-unrealbuildtool)
- [Target 选择：Game 还是 Editor](#target-选择game-还是-editor)
- [Config 选择](#config-选择)
- [何时需要先刷新项目文件](#何时需要先刷新项目文件)

---

## 引擎安装目录约定

本工作区约定 Unreal Engine 安装目录固定为：

```
E:\UnrealEngine\UE_<版本>
```

例如：

- UE 5.6 → `E:\UnrealEngine\UE_5.6`
- UE 5.7 → `E:\UnrealEngine\UE_5.7`

完整的引擎目录结构（以 5.6 为例）：

```
E:\UnrealEngine\UE_5.6\
└── Engine\
    └── Binaries\
        └── DotNET\
            └── UnrealBuildTool\
                └── UnrealBuildTool.exe
```

验证步骤：

1. 根据上一步从 `EngineAssociation` 解析出的引擎版本，拼接引擎根目录路径。
2. 使用 `Test-Path` 验证该目录是否存在。
3. 如果目录不存在，停止编译流程，向用户报告引擎未安装或路径不正确，不要尝试其他路径或猜测。

---

## 验证 UnrealBuildTool

UnrealBuildTool（UBT）是 Unreal 的编译入口。其路径固定为：

```
E:\UnrealEngine\UE_<版本>\Engine\Binaries\DotNET\UnrealBuildTool\UnrealBuildTool.exe
```

验证步骤：

1. 拼接 UBT 完整路径。
2. 使用 `Test-Path` 验证该文件是否存在。
3. 如果文件不存在，停止编译流程，向用户报告引擎安装不完整。

UBT 是一个 .NET 程序，通过命令行调用。编译命令的标准格式为：

```
"<UBT路径>" <目标> <平台> <配置> -Project="<项目路径>\<项目名>.uproject" -rocket -progress
```

---

## Target 选择：Game 还是 Editor

Unreal 编译目标分为两类：

### Game Target

- 命名格式：`<项目名>`（不带 Editor 后缀）
- 产物：独立运行的游戏可执行文件（`.exe`）
- 用途：独立运行的游戏、打包测试、性能测试、最终发布
- 可执行文件位置：`<项目>/Binaries/Win64/<项目名>.exe`
- 适用场景：需要脱离编辑器运行游戏、测试独立性能、验证发布构建

### Editor Target

- 命名格式：`<项目名>Editor`（带 Editor 后缀）
- 产物：编辑器可执行文件（`.exe`）
- 用途：在编辑器中开发、调试、预览游戏
- 可执行文件位置：`<项目>/Binaries/Win64/<项目名>Editor.exe`
- 适用场景：日常开发、编辑器内调试、修改关卡和资源

### 选择规则

- 如果用户明确指定了 Target，使用用户指定的 Target。
- 如果用户没有指定，**必须询问用户**需要 Game Target 还是 Editor Target，不要默认假设。
- 常见默认：日常开发使用 Editor Target + Development 或 DebugGame Config。
- 仅当用户明确表示要"打包发布""独立运行""性能测试"时，才使用 Game Target。

---

## Config 选择

Unreal 编译配置分为四种，按从快到慢、从功能受限到完整排序：

### Development（默认推荐）

- 包含游戏逻辑和引擎功能，Editor Target 的 Development 仍包含编辑器功能。
- 启动速度快，性能接近最终产品。
- 适合日常开发和迭代编译。
- 产物可运行，但不包含完整的调试符号优化。

### Debug

- 全量调试配置，所有代码都禁用优化，包含完整调试符号。
- 编译速度最慢，运行性能最差。
- 适合需要深入调试底层引擎代码或排查优化相关问题的场景。
- 仅在确实需要逐行调试引擎内部代码时使用。

### DebugGame

- 仅游戏模块代码禁用优化并包含完整调试符号，引擎模块仍为 Development 配置。
- 编译速度和调试体验介于 Development 和 Debug 之间。
- 适合调试自己的游戏代码，不需要深入调试引擎内部。
- 日常调试自己游戏逻辑时的推荐配置。

### Shipping

- 发布配置，移除所有调试符号、断言、统计和开发工具。
- 启动速度和运行性能最优。
- 适合最终发布构建、性能基准测试。
- 不适合开发调试，因为无法定位崩溃和断言。

### 选择规则

- 如果用户明确指定了 Config，使用用户指定的 Config。
- 如果用户没有指定，默认使用 **Development**。
- 如果用户表示要"调试自己写的代码"，推荐 **DebugGame**。
- 如果用户表示要"调试引擎内部代码"，推荐 **Debug**。
- 如果用户表示要"发布""打包最终版本"，使用 **Shipping**。

### Target 与 Config 的组合

常见组合：

| 场景 | Target | Config |
|------|--------|--------|
| 日常编辑器开发 | Editor | Development |
| 调试自己游戏代码 | Editor | DebugGame |
| 深入调试引擎代码 | Editor | Debug |
| 独立运行测试 | Game | Development |
| 最终发布构建 | Game | Shipping |

---

## 何时需要先刷新项目文件

刷新项目文件（`-projectfiles`）会让 UBT 扫描项目的 Source 目录、Build.cs、Target.cs，生成构建所需的中间文件和 IDE 工程文件。

必须先刷新项目文件再编译的场景：

- 首次编译一个项目（项目从未生成过中间文件）。
- 新增了 `.h`、`.cpp`、`.Build.cs`、`.Target.cs` 文件。
- 修改了 `.Build.cs` 的模块依赖（`PublicDependencyModuleNames`、`PrivateDependencyModuleNames`）。
- 修改了 `.Target.cs` 的额外模块列表（`ExtraModuleNames`）。
- 修改了 `.uproject` 的 `Modules` 或 `Plugins` 列表。
- 切换了引擎版本后首次编译。
- 删除了 `Intermediate/` 目录或执行过 `-clean`。

不需要刷新的场景：

- 仅修改了已有 `.cpp` 或 `.h` 的内容（未新增文件、未改 Build.cs）。
- 上一次编译成功且没有结构变化。

刷新项目文件命令见 [03-compile-commands.md](03-compile-commands.md)。
