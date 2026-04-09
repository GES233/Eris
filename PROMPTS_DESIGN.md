# Eris.Prompts 生成机制设计文档

## 📋 概述

`Eris.Prompts` 模块实现了动态、模块化的系统提示词生成机制，为 Eris AI 助手提供上下文感知、可配置的提示词构建能力。

## 🎯 核心设计原则

1. **模块化** - 每个 Prompt 部分独立构建，便于维护和扩展
2. **动态性** - 根据上下文动态调整内容
3. **可配置性** - 通过 opts 控制包含哪些部分
4. **效率** - 避免不必要的 Token 消耗
5. **上下文感知** - 根据会话状态智能调整内容

## 🏗️ 架构设计

### 1. 模块结构

```
Eris.Prompts
├── build_system_prompt/2      # 主入口：构建完整系统提示词
├── get_final_environment/1    # 获取系统环境信息
├── get_tools_description/1    # 获取工具描述
├── get_user_preferences/1     # 获取用户偏好
├── get_context_summary/1      # 获取上下文摘要
├── estimate_tokens/1          # Token 估算
├── should_compress?/2         # 检查是否需要压缩
├── build_messages/2           # 构建完整消息列表
└── adjust_for_token_limit/2   # 动态调整 Prompt 长度
```

### 2. Prompt 组成部分

#### 2.1 助手身份 (Assistant Identity)
```elixir
"You're Eris, an AI assistant that help developers with several tasks."
```

#### 2.2 对话规则 (Conversation Rules)
- 工具使用规范
- 推理步骤要求
- 清晰简洁原则
- 安全性和隐私保护
- 错误处理机制
- 上下文感知

#### 2.3 工具使用指南 (Tool Usage Guidelines)
- 文件操作工具
- 搜索工具
- 命令执行工具
- 项目管理工具
- 信息获取工具

#### 2.4 系统环境 (System Environment)
- 工作目录
- 系统架构
- Elixir 版本
- OTP 版本

#### 2.5 工具描述 (Available Tools)
动态生成所有可用工具的列表和描述。

#### 2.6 用户偏好 (User Preferences) - 可选
用户自定义的偏好设置。

#### 2.7 上下文摘要 (Context Summary) - 可选
对话状态的简要摘要。

## 🔧 使用示例

### 基础使用
```elixir
# 构建默认系统提示词
ctx = %{include_full_environment: true, tools: Eris.Tools.all()}
system_prompt = Eris.Prompts.build_system_prompt(ctx)

# 构建自定义系统提示词（只包含必要部分）
system_prompt = Eris.Prompts.build_system_prompt(ctx, [
  include_identity: true,
  include_environment: true,
  include_tools: false,  # 不包含工具描述
  include_rules: true
])
```

### 集成到 Seasons 状态机
```elixir
# 在 init/1 中构建系统提示词
def init(options) do
  llm_conf = Keyword.fetch!(options, :llm_conf)
  tools = Keyword.get(options, :tools, Eris.Tools.all())
  
  ctx = %{
    include_full_environment: true,
    tools: tools,
    llm_conf: llm_conf
  }
  
  system_prompt = Eris.Prompts.build_system_prompt(ctx, 
    include_identity: true,
    include_environment: true,
    include_tools: true,
    include_rules: true,
    include_guidelines: true
  )
  
  initial_messages = [
    %{"role" => "system", "content" => system_prompt}
  ]
  
  {:ok, :idle, %State{
    llm: llm_conf,
    messages: initial_messages,
    system_prompt: system_prompt,
    ctx: ctx
  }}
end
```

### Token 管理
```elixir
# 估算 Token 数量
token_count = Eris.Prompts.estimate_tokens(system_prompt)

# 检查是否需要压缩
if Eris.Prompts.should_compress?(ctx, llm_conf.max_context_tokens) do
  # 执行压缩逻辑
end

# 动态调整 Prompt 长度
adjusted_prompt = Eris.Prompts.adjust_for_token_limit(
  system_prompt,
  llm_conf.max_context_tokens
)
```

## 📊 数据流

```
┌─────────────┐
│   Seasons   │
│  State Machine
└──────┬──────┘
       │
       │ init/1
       ▼
┌─────────────┐
│  Eris.Prompts│
│ build_system │
│   _prompt   │
└──────┬──────┘
       │
       │ 返回系统提示词
       ▼
┌─────────────┐
│  Messages   │
│  List       │
│ (system +   │
│  user)      │
└──────┬──────┘
       │
       │ 发送给 LLM
       ▼
┌─────────────┐
│   Eris.LLM  │
│ chat_completion
└─────────────┘
```

## 🚀 扩展性设计

### 1. 添加新的 Prompt 部分

```elixir
# 在 Eris.Prompts 中添加新的获取函数
def get_new_section(ctx) do
  # 实现逻辑
end

# 在 build_system_prompt/2 中添加
|> maybe_add_section(opts[:include_new_section], get_new_section(ctx))
```

### 2. 自定义 Prompt 模板

```elixir
# 可以通过配置或环境变量自定义模板
@custom_identity System.get_env("ERIS_IDENTITY") || @assistant_identity
```

### 3. 动态工具注册

```elixir
# 支持动态添加工具
ctx = %{ctx | tools: Eris.Tools.all() ++ [CustomTool]}
```

## 🎨 优化策略

### 1. Token 优化
- 按需包含 Prompt 部分
- 动态调整长度
- 上下文压缩

### 2. 隐私保护
- 可选的环境信息
- 敏感数据过滤

### 3. 性能优化
- 缓存构建结果
- 避免重复计算

## 📝 最佳实践

1. **默认包含核心部分**：身份、规则、工具描述
2. **按需包含可选部分**：用户偏好、上下文摘要
3. **监控 Token 使用**：及时调整 Prompt 长度
4. **定期审查 Prompt**：确保内容相关性和有效性
5. **测试不同配置**：找到最适合的配置组合

## 🔮 未来改进方向

1. **多语言支持** - 支持不同语言的 Prompt
2. **A/B 测试** - 测试不同 Prompt 的效果
3. **机器学习优化** - 基于反馈自动优化 Prompt
4. **模板系统** - 支持更灵活的模板配置
5. **Prompt 版本管理** - 支持 Prompt 的版本控制和回滚

## 📚 相关模块

- `Eris.Seasons` - 状态机，使用 Prompt 构建消息
- `Eris.LLM` - LLM 交互，发送消息
- `Eris.Tools` - 工具注册表，提供工具描述
- `Eris.Tool` - 工具基类，定义工具 schema

---

**版本**: 1.0.0  
**最后更新**: 2024  
**作者**: Eris AI Assistant
