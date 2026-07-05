# unrealsharp-agent-skill

一个面向 Agent 的 UnrealSharp 通用 Skill，适用于 UE 5.5 - 5.7 工程。

它主要覆盖这些场景：

- UnrealSharp 插件结构与模块职责
- `Script/*.csproj`、`*.Glue`、`generated.cs` 的关系
- `UnrealSharpBuildTool`、`BuildEmitLoadOrder`、热重载与启动链路
- 创建 C# 项目或 C# 插件项目
- `UClass`、`UProperty`、`UFunction` 等 UnrealSharp C# 写法
- 编辑器启动到 75% 卡住、Glue 编译失败、托管构建报错等排查

## 适用对象

适合这两类仓库：

- vendored 了 `Plugins/UnrealSharp` 源码的 UE 项目
- 需要在 UnrealSharp 项目里做日常开发、排错和结构定位的 Agent / AI 工作流

如果当前工作区里存在 `Plugins/UnrealSharp`，Skill 会优先基于本地插件源码和项目配置回答，而不是只给通用文档答案。

## 仓库结构

- `SKILL.md`: Skill 入口定义与任务路由
- `references/01-overview-and-layout.md`: 目录、模块和关键入口
- `references/02-build-generation-and-hot-reload.md`: 构建、生成、热重载
- `references/03-csharp-authoring-patterns.md`: UnrealSharp C# 编写规范与高风险模式
- `references/04-project-and-plugin-creation.md`: C# 项目 / 插件创建路径
- `references/05-troubleshooting-and-diagnostics.md`: 常见故障排查
- `references/06-official-links-and-local-entrypoints.md`: 官方链接和本地高价值入口

## 安装

如果你想把它作为项目内 Skill 管理，可以直接放到 `.github/skills/` 下。

示例：

```bash
git submodule add https://github.com/Tirefly/unrealsharp-agent-skill.git .github/skills/unrealsharp-agent-skill
```

也可以直接把整个目录拷贝到支持 `SKILL.md` 的 Agent / Copilot / Claude 风格工作流中使用。

## 使用方式

当任务涉及以下关键词时，就适合触发这个 Skill：

- `UnrealSharp`
- `Glue`
- `generated.cs`
- `BuildEmitLoadOrder`
- `UnrealSharpBuildTool`
- `Script/*.csproj`
- UnrealSharp 启动卡住、托管编译失败、C# 暴露规则异常

默认建议：

1. 先读 `SKILL.md`，确认任务路由。
2. 再按问题类型进入对应 `references/` 文档。
3. 如果工作区已 vendored `Plugins/UnrealSharp`，优先回到本地源码验证结论。

## 说明

这个仓库提供的是 Skill 和配套参考资料，不是 UnrealSharp 插件本体。

如果你要排查具体项目问题，最好同时具备：

- 项目自己的 `Script/` 目录
- `Plugins/UnrealSharp`
- 可用的 `.NET SDK`
- 对应 UE 工程的构建日志或报错信息

