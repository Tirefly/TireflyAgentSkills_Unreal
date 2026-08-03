# 编译命令参考

本文件覆盖 UE5 C++ 项目的编译命令模板、刷新项目文件命令、常用附加参数和编译失败排查顺序。本文件是用户级唯一规范中 UE5 C++ 编译命令规则的详细承载位置。

## 目录

- [路径变量约定](#路径变量约定)
- [刷新项目文件命令](#刷新项目文件命令)
- [Game Target 编译命令](#game-target-编译命令)
- [Editor Target 编译命令](#editor-target-编译命令)
- [常用附加参数](#常用附加参数)
- [编译失败排查顺序](#编译失败排查顺序)
- [完整执行示例](#完整执行示例)

---

## 路径变量约定

为使命令模板可读，本文件使用以下变量占位符。实际执行时需替换为具体值：

| 占位符 | 含义 | 示例 |
|--------|------|------|
| `<EngineVersionPath>` | 引擎版本目录名，来自 EngineAssociation | `UE_5.6` |
| `<UBT>` | UnrealBuildTool.exe 完整路径 | `E:\UnrealEngine\UE_5.6\Engine\Binaries\DotNET\UnrealBuildTool\UnrealBuildTool.exe` |
| `<ProjectPath>` | .uproject 文件所在目录的完整路径 | `D:\Projects\MyProject` |
| `<ProjectName>` | 项目名，来自 .uproject 的 Name 字段 | `MyProject` |

UBT 完整路径拼接公式：

```
E:\UnrealEngine\<EngineVersionPath>\Engine\Binaries\DotNET\UnrealBuildTool\UnrealBuildTool.exe
```

项目文件完整路径：

```
<ProjectPath>\<ProjectName>.uproject
```

> 注意：所有含空格的路径在命令中必须用双引号包裹。在 PowerShell 中调用路径含空格的可执行文件时，必须使用调用运算符 `&`。

---

## 刷新项目文件命令

新增文件、修改 Build.cs/Target.cs、切换引擎版本后，先执行此命令再编译：

```
& "<UBT>" -projectfiles -project="<ProjectPath>\<ProjectName>.uproject" -game -rocket -progress
```

参数说明：

- `-projectfiles`：指示 UBT 生成项目文件，不执行编译。
- `-project="..."`：指定目标 `.uproject` 文件。
- `-game`：指示这是游戏项目（而非引擎本身）。
- `-rocket`：使用已安装的引擎版本（必需）。
- `-progress`：显示生成进度。

---

## Game Target 编译命令

Game Target 产物为独立运行的游戏可执行文件。目标名格式为 `<ProjectName>`（不带 Editor 后缀）。

### Debug Config

```
& "<UBT>" <ProjectName> Win64 Debug -Project="<ProjectPath>\<ProjectName>.uproject" -rocket -progress
```

### DebugGame Config

```
& "<UBT>" <ProjectName> Win64 DebugGame -Project="<ProjectPath>\<ProjectName>.uproject" -rocket -progress
```

### Development Config

```
& "<UBT>" <ProjectName> Win64 Development -Project="<ProjectPath>\<ProjectName>.uproject" -rocket -progress
```

### Shipping Config

```
& "<UBT>" <ProjectName> Win64 Shipping -Project="<ProjectPath>\<ProjectName>.uproject" -rocket -progress
```

---

## Editor Target 编译命令

Editor Target 产物为编辑器可执行文件。目标名格式为 `<ProjectName>Editor`（带 Editor 后缀）。

### Debug Config

```
& "<UBT>" <ProjectName>Editor Win64 Debug -Project="<ProjectPath>\<ProjectName>.uproject" -rocket -progress
```

### DebugGame Config

```
& "<UBT>" <ProjectName>Editor Win64 DebugGame -Project="<ProjectPath>\<ProjectName>.uproject" -rocket -progress
```

### Development Config

```
& "<UBT>" <ProjectName>Editor Win64 Development -Project="<ProjectPath>\<ProjectName>.uproject" -rocket -progress
```

### Shipping Config

```
& "<UBT>" <ProjectName>Editor Win64 Shipping -Project="<ProjectPath>\<ProjectName>.uproject" -rocket -progress
```

> 注意：Shipping 配置的 Editor Target 很少使用，编辑器通常不发布。仅在特殊场景（如发行版工具编辑器）使用。

---

## 常用附加参数

以下参数可按需附加到编译命令末尾：

| 参数 | 作用 |
|------|------|
| `-rocket` | 使用已安装的引擎版本（必需，所有命令都应包含） |
| `-progress` | 显示编译进度 |
| `-verbose` | 显示详细编译输出，用于排查问题时 |
| `-clean` | 清理所有中间文件并重新编译（慎用，耗时长） |
| `-rebuild` | 强制重新编译所有文件，不清理中间文件 |
| `-noxge` | 禁用 XGE 分布式编译 |
| `-noubtmakefiles` | 不生成 UBT makefile 缓存 |
| `-log` | 输出详细日志信息 |

使用建议：

- 日常编译：`-rocket -progress` 即可。
- 排查编译错误：追加 `-verbose`。
- 怀疑中间文件损坏：先尝试 `-rebuild`，仍失败再用 `-clean`。
- 怀疑 makefile 缓存问题：追加 `-noubtmakefiles`。

---

## 编译失败排查顺序

编译失败时，按以下顺序排查，不要一开始就 `-clean` 全量重建：

1. **阅读错误信息**：从编译输出末尾的 error 行开始，定位第一个错误。UE5 编译错误通常是连锁的，第一个错误往往是根因。
2. **定位受影响模块**：根据错误信息中的文件路径，确定是哪个模块、哪个 Build.cs 出问题。
3. **检查 Build.cs 依赖**：如果错误是 "unresolved external symbol" 或 "could not find module"，检查 Build.cs 的 `PublicDependencyModuleNames` 和 `PrivateDependencyModuleNames` 是否遗漏了依赖模块。
4. **检查引擎版本匹配**：确认项目 `EngineAssociation` 与实际使用的引擎版本一致。使用了 5.6 的 API 但项目声明 5.5 会导致编译失败。
5. **检查新增文件**：如果新增了 `.h`/`.cpp`/`.Build.cs`/`.Target.cs` 但未刷新项目文件，先执行刷新项目文件命令。
6. **尝试 -rebuild**：如果以上都正常但仍编译失败，追加 `-rebuild` 强制重新编译。
7. **尝试 -clean**：仅当 `-rebuild` 仍失败时，使用 `-clean` 清理所有中间文件后重新编译。这是最后手段，耗时长。

常见错误模式：

- `fatal error C1083: 无法打开包含文件 "X.generated.h"`：UHT 未生成反射代码，先刷新项目文件。
- `unresolved external symbol`：Build.cs 缺少模块依赖，或新增文件未加入编译列表。
- `error C2039: "XXX" 不是 "YYY" 的成员`：引擎版本不匹配，API 在当前版本中不存在或已迁移。
- `Could not find UnrealBuildTool`：引擎路径错误，重新验证引擎安装目录。

---

## 完整执行示例

以项目 `MyProject`（引擎 5.6，路径 `D:\Projects\MyProject`）为例，执行 Editor Target + Development Config 编译：

### 步骤 1：验证引擎目录

```powershell
Test-Path -LiteralPath "E:\UnrealEngine\UE_5.6\Engine\Binaries\DotNET\UnrealBuildTool\UnrealBuildTool.exe"
```

预期输出：`True`

### 步骤 2（如有新增文件）：刷新项目文件

```powershell
& "E:\UnrealEngine\UE_5.6\Engine\Binaries\DotNET\UnrealBuildTool\UnrealBuildTool.exe" -projectfiles -project="D:\Projects\MyProject\MyProject.uproject" -game -rocket -progress
```

### 步骤 3：执行编译

```powershell
& "E:\UnrealEngine\UE_5.6\Engine\Binaries\DotNET\UnrealBuildTool\UnrealBuildTool.exe" MyProjectEditor Win64 Development -Project="D:\Projects\MyProject\MyProject.uproject" -rocket -progress
```

### 步骤 4（编译失败时）：追加 -verbose 排查

```powershell
& "E:\UnrealEngine\UE_5.6\Engine\Binaries\DotNET\UnrealBuildTool\UnrealBuildTool.exe" MyProjectEditor Win64 Development -Project="D:\Projects\MyProject\MyProject.uproject" -rocket -progress -verbose
```

> 注意：在 PowerShell 中调用路径含空格的可执行文件时，必须使用调用运算符 `&`。编译命令的退出码为 0 表示成功，非 0 表示失败，应捕获退出码并向用户报告结果。
