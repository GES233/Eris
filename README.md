# Eris

学习 [he-yufeng/CoreCoder](https://github.com/he-yufeng/CoreCoder) 的 Elixir 实现。

## 简介

Eris 是一个基于 Elixir 的 AI 助手，专为开发者设计，支持：

- **流式对话**：实时接收 LLM 响应
- **工具调用**：支持文件读写、代码编辑等工具
- **并行执行**：多个工具可以并行执行
- **子 Agent**：可以创建子 Agent 处理复杂任务
- **多模型支持**：支持 OpenAI 兼容的 API

## 功能特性

### 核心功能

- **流式 Agent 循环**：支持流式输出和推理
- **工具系统**：
  - `read_file` - 读取文件内容（带行号）
  - `edit_file` - 编辑文件（精确字符串替换）
  - `agent` - 创建子 Agent 处理复杂任务
- **上下文管理**：自动跟踪修改的文件
- **Token 统计**：追踪 prompt 和 completion 的 token 使用

### 支持的模型

- OpenAI
- OpenRouter
- 其他 OpenAI 兼容 API

## 项目结构

```
lib/
├── eris.ex              # 核心对话逻辑
├── eris/application.ex  # OTP 应用
├── eris/llm.ex          # LLM 交互
├── eris/prompts.ex      # 提示词构建
├── eris/tools.ex        # 工具注册表
├── eris/tool.ex         # 工具行为定义
├── eris/tool/context.ex # 工具上下文
└── eris/agent_loop.ex   # 同步 Agent 循环
```

## 依赖

- `req` (~> 0.5.0) - HTTP 客户端
- `jason` (~> 1.4) - JSON 解析
- `ex_ratatui` (~> 0.5) - TUI 框架（预留）

## 使用方法

```elixir
# 基本对话
Eris.chat("你好", llm_conf: llm_config)

# 带工具调用
Eris.chat("帮我读取这个文件", 
  llm_conf: llm_config,
  tools: [Eris.Tools.ReadFile],
  max_rounds: 10
)
```

## 环境信息

Eris 会自动检测并报告当前环境信息，包括：
- 当前工作目录
- 系统架构
- 可用的运行时和工具

## 开发计划

- [ ] 实现 TUI 界面
- [ ] 添加更多工具
- [ ] 支持更多 LLM 提供商
- [ ] 实现上下文压缩
- [ ] 添加会话持久化

## 许可证

MIT
