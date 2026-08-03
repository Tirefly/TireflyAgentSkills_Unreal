---
name: ue5-cpp-compile
description: UE5 C++ 项目编译与引擎环境判定指南。必须用于任何 UE5 引擎版本判定、EngineAssociation 解析、Unreal Engine 安装目录确认、UnrealBuildTool 路径验证、刷新项目文件、编译/构建 Unreal Engine C++ 工程、Game/Editor Target 的 Debug/DebugGame/Development/Shipping 配置编译、清理重建、切换引擎版本后重建等任务。当用户请求编译 UE5 项目、build UE5、构建 C++ 工程、生成项目文件、UnrealBuildTool 编译、确认 UE 引擎路径或版本时使用此 Skill。
---

# UE5 C++ 项目编译

这个 Skill 是面向 Agent 的 UE5 C++ 项目编译工作流指南，也是用户级唯一规范中 UE5 引擎版本判定、Unreal Engine 安装目录约定和 C++ 编译流程的承载 Skill。处理 UE5 引擎版本、引擎路径、UBT 路径、项目文件刷新或 C++ 编译时，必须先使用本 Skill。

编译 UE5 C++ 项目时，必须按"识别项目 → 判定引擎版本 → 确定编译环境 → 执行编译"的顺序进行，不可跳过任何一步，也不可凭直觉或缓存文件猜测引擎版本。

适用范围：

- 识别一个目录是否为需要编译 C++ 工程的 UE5 项目
- 从 `.uproject` 的 `EngineAssociation` 字段判定项目使用的 UE5 版本
- 验证引擎安装目录与 UnrealBuildTool 是否可用
- 确认用户级约定的 Unreal Engine 安装根目录 `E:\UnrealEngine\`
- 区分 Game Target 与 Editor Target，区分 Debug/DebugGame/Development/Shipping 配置的语义和适用场景
- 使用 UnrealBuildTool 执行编译、刷新项目文件、清理重建
- 编译失败时的排查顺序

不适用范围：

- UnrealSharp 托管层（C# Glue / BuildEmitLoadOrder）的编译问题，交给 `unrealsharp-agent-skill`
- UE5 C++ 代码风格问题，交给 `ue5-cpp-style`

## 核心流程（四步，不可跳过）

1. **识别项目**：在工作区或用户指定路径下找到 `.uproject` 文件，确认是否为 C++ 项目（存在 Source 目录、`.Build.cs`、`.Target.cs`）。详见 [01-project-detection.md](references/01-project-detection.md)。
2. **判定引擎版本**：读取 `.uproject` 中的 `EngineAssociation` 字段作为唯一事实来源，不要从 `.vscode/compileCommands*.json`、`Intermediate/TargetInfo*.json`、`Saved/`、日志等缓存文件推断。
3. **确定编译环境**：验证引擎安装目录 `E:\UnrealEngine\UE_<版本>` 存在，验证 `UnrealBuildTool.exe` 存在；根据用户需求确定 Target（Game/Editor）与 Config（Debug/DebugGame/Development/Shipping）。详见 [02-compile-environment.md](references/02-compile-environment.md)。
4. **执行编译**：使用 UnrealBuildTool 执行编译命令。新增文件后先刷新项目文件再编译。详见 [03-compile-commands.md](references/03-compile-commands.md)。

## 任务路由

根据问题类型，优先读取下列参考文件：

- 如何找到 `.uproject`、判断是否 C++ 项目、从 `EngineAssociation` 解析引擎版本：读 [01-project-detection.md](references/01-project-detection.md)
- 引擎安装目录约定、UnrealBuildTool 路径验证、Target 与 Config 的选择、何时需要先刷新项目文件：读 [02-compile-environment.md](references/02-compile-environment.md)
- 完整编译命令模板、刷新项目文件命令、常用附加参数、编译失败排查顺序：读 [03-compile-commands.md](references/03-compile-commands.md)

## 工作规则

- 判定引擎版本的唯一标准是 `.uproject` 的 `EngineAssociation` 字段。不要根据 `.vscode/compileCommands*.json`、workspace 元数据、`.idea/`、`Saved/`、`Intermediate/`、日志或其他生成/本地缓存文件推断项目引擎版本。
- 引擎安装目录约定为 `E:\UnrealEngine\UE_<版本>`（例如 `E:\UnrealEngine\UE_5.6`）。如果该目录不存在，停止编译并向用户报告，不要尝试其他路径。
- 如果 `EngineAssociation` 是 GUID，先使用该 GUID 查询 Windows 注册表中的 Unreal Engine Builds 映射；查不到时必须询问用户，不要用缓存文件或 IDE 元数据猜测。
- 编译前如果没有生成过项目文件，或新增了 `.h`/`.cpp`/`.Build.cs`/`.Target.cs` 文件，或修改了 `.Build.cs` 的模块依赖、`.Target.cs` 的额外模块、`.uproject` 的 Modules/Plugins 列表，必须先执行刷新项目文件命令（`-projectfiles`），再执行编译命令。
- 如果用户没有明确指定 Target，必须询问用户需要 Game Target 还是 Editor Target，不要默认假设。Editor Target 用于在编辑器中开发调试，Game Target 用于独立运行的游戏可执行文件。
- 如果用户没有明确指定 Config，默认使用 Development。Shipping 仅用于最终发布构建。
- `-rocket` 参数表示使用已安装的引擎版本，是必需参数，所有编译和刷新命令都应包含。
- 编译命令中项目名、项目路径、引擎路径如果包含空格，必须用双引号包裹。在 PowerShell 中调用路径含空格的可执行文件时，必须使用调用运算符 `&`。
- 编译失败时，按"错误信息 → 受影响模块 → Build.cs 依赖 → 引擎版本匹配 → 刷新项目文件 → -rebuild → -clean"的顺序排查，不要一开始就 `-clean` 全量重建。

## 快速检查清单

完成 UE5 C++ 编译前，确认以下事项：

**项目识别**（详见 01-project-detection.md）

- [ ] 已找到 `.uproject` 文件并读取其完整路径
- [ ] 已确认项目为 C++ 项目（存在 Source 目录或 `.Build.cs`）
- [ ] 已从 `EngineAssociation` 读取引擎版本，未使用缓存文件推断

**编译环境**（详见 02-compile-environment.md）

- [ ] 引擎安装目录 `E:\UnrealEngine\UE_<版本>` 存在
- [ ] `UnrealBuildTool.exe` 存在于该引擎的 `Engine/Binaries/DotNET/UnrealBuildTool/` 下
- [ ] 已确定 Target（Game 或 Editor）
- [ ] 已确定 Config（Debug/DebugGame/Development/Shipping）
- [ ] 如有新增文件或结构变化，已先执行刷新项目文件命令

**执行编译**（详见 03-compile-commands.md）

- [ ] 编译命令中所有含空格的路径都用双引号包裹
- [ ] 已包含 `-rocket` 和 `-progress` 参数
- [ ] 已捕获编译输出并向用户报告结果
