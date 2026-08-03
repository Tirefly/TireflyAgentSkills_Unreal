# 项目识别与引擎版本判定

本文件覆盖 UE5 项目识别和引擎版本判定的规则：如何找到 `.uproject`、如何判断是否为 C++ 项目、如何从 `EngineAssociation` 判定引擎版本。本文件是用户级唯一规范中 UE5 引擎版本判定规则的详细承载位置。

## 目录

- [找到 .uproject 文件](#找到-uproject-文件)
- [判断是否为 C++ 项目](#判断是否为-c-项目)
- [从 EngineAssociation 判定引擎版本](#从-engineassociation-判定引擎版本)
- [禁止的版本推断方式](#禁止的版本推断方式)

---

## 找到 .uproject 文件

UE5 项目的根标志是 `.uproject` 文件。识别步骤：

1. 如果用户明确指定了项目路径，直接验证该路径下是否存在 `.uproject` 文件。
2. 如果用户没有指定路径，在当前工作区下递归搜索 `*.uproject` 文件。
3. 如果工作区下只有一个 `.uproject` 文件，使用它。
4. 如果工作区下有多个 `.uproject` 文件（例如包含插件子项目），优先选择位于工作区根目录的那个，并向用户确认。

`.uproject` 文件是一个 JSON 格式文件，示例：

```json
{
	"FileVersion": 3,
	"EngineAssociation": "5.6",
	"Name": "MyProject",
	"Modules": [
		{
			"Name": "MyProject",
			"Type": "Runtime"
		}
	]
}
```

关键字段：

- `EngineAssociation`：引擎版本标识，用于判定项目使用的 UE5 版本（详见下文）。
- `Name`：项目名，用于编译命令中的 `<ProjectName>`。
- `Modules`：项目包含的模块列表，用于判断项目规模和模块组成。

---

## 判断是否为 C++ 项目

仅找到 `.uproject` 还不能确定需要编译 C++ 代码。纯 Blueprint 项目没有 C++ 源码，不需要使用 UnrealBuildTool 编译。

判断为 C++ 项目的条件（满足任一即可）：

- 项目根目录下存在 `Source/` 目录，且 `Source/` 下至少有一个 `.Build.cs` 文件。
- 项目根目录下存在 `*.Target.cs` 文件（如 `MyProject.Target.cs`、`MyProjectEditor.Target.cs`），通常位于 `Source/` 下。
- 项目根目录下存在 `*.cpp` 或 `*.h` 文件（位于 `Source/` 或 `Plugins/<插件名>/Source/` 下）。

如果以上条件都不满足，项目可能是纯 Blueprint 项目，不需要 C++ 编译。此时应向用户确认是否确实需要编译 C++ 代码，避免对 Blueprint 项目执行无效的 C++ 编译流程。

---

## 从 EngineAssociation 判定引擎版本

`EngineAssociation` 字段是判定项目引擎版本的**唯一标准**。它有两种格式：

### 格式一：版本号字符串

最常见的格式，值为引擎版本号字符串：

```json
"EngineAssociation": "5.6"
```

此时引擎版本为 `5.6`，引擎安装目录约定为 `E:\UnrealEngine\UE_5.6`。

常见的版本号示例：

- `"5.3"` → 引擎目录 `E:\UnrealEngine\UE_5.3`
- `"5.4"` → 引擎目录 `E:\UnrealEngine\UE_5.4`
- `"5.5"` → 引擎目录 `E:\UnrealEngine\UE_5.5`
- `"5.6"` → 引擎目录 `E:\UnrealEngine\UE_5.6`
- `"5.7"` → 引擎目录 `E:\UnrealEngine\UE_5.7`

### 格式二：自定义引擎 GUID

当项目使用源码版引擎或自定义安装的引擎时，`EngineAssociation` 可能是一个 GUID 字符串：

```json
"EngineAssociation": "{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}"
```

此时不能直接从字段值推导引擎目录。处理方式：

1. 在 Windows 注册表 `HKEY_CURRENT_USER\Epic Games\Unreal Engine\Builds` 下查找该 GUID 对应的引擎路径。
2. 如果找不到，向用户询问引擎安装路径，不要猜测。

### 解析流程

1. 读取 `.uproject` 文件内容（JSON 格式）。
2. 取出 `EngineAssociation` 字段值。
3. 如果值是版本号字符串（如 `"5.6"`），拼接引擎目录为 `E:\UnrealEngine\UE_<值>`。
4. 如果值是 GUID 字符串，查询注册表或询问用户。
5. 记录引擎版本号和引擎安装目录，供后续步骤使用。

---

## 禁止的版本推断方式

以下来源**不能**作为引擎版本的判定依据：

- `.vscode/compileCommands*.json`：这是 IDE 生成的编译数据库，可能过期或来自不同引擎。
- `Intermediate/TargetInfo*.json`：UBT 生成的中间文件，可能在切换引擎后未更新。
- `.idea/` 下的配置文件：IDE 元数据，不保证与项目实际引擎一致。
- `Saved/`、`Intermediate/` 下的日志或缓存文件：可能来自历史构建。
- workspace 元数据、`*.sln` 文件中的路径：可能指向错误的引擎。

这些文件可能存在、可能过期、可能来自不同引擎，任何基于它们的版本推断都是不可靠的。只有 `.uproject` 的 `EngineAssociation` 字段是项目主动声明的引擎版本，是唯一可信来源。
