defmodule Eris.Prompts do
  @moduledoc """
  实现 Prompt 的动态构建。

  这个模块负责构建系统提示词（System Prompt），包括：
  - 助手身份定义
  - 环境信息
  - 工具描述
  - 用户偏好
  - 对话规则
  - 其他动态内容

  设计原则：
  - 模块化：每个部分独立构建，便于维护和扩展
  - 动态性：根据上下文动态调整内容
  - 可配置性：通过 opts 控制包含哪些部分
  - 效率：避免不必要的 Token 消耗
  """

  require Logger

  @assistant_identity """
  You're Eris, an AI assistant that help developers with several tasks.
  """

  @conversation_rules """
  ## Conversation Rules

  1. **Tool Usage**: When you need to use a tool, call it with the correct parameters.
     Tools are your hands - use them when needed.
  2. **Reasoning**: Think step by step. Explain your reasoning before taking actions.
  3. **Clarity**: Be clear and concise. Avoid unnecessary verbosity.
  4. **Safety**: Never execute commands that could harm the system or data.
  5. **Privacy**: Respect user privacy. Don't expose sensitive information.
  6. **Error Handling**: If something goes wrong, explain the error and suggest solutions.
  7. **Context Awareness**: Remember the conversation context and build upon it.
  8. **Tool Results**: When receiving tool results, analyze them and continue the task.
  """

  @tool_usage_guidelines """
  ## Tool Usage Guidelines

  You have access to various tools that can help you complete tasks:

  - **File Operations**: Read, edit, write files in the current project
  - **Search**: Find files and search for patterns in code
  - **Execution**: Run shell commands (Bash/PowerShell)
  - **Project Management**: Zip Elixir projects, create sub-agents
  - **Information**: Get environment information

  When using tools:
  1. Choose the right tool for the task
  2. Provide all required parameters
  3. Analyze the results before proceeding
  4. Handle errors gracefully
  """

  # @system_template """
  # ## System Environment

  # - **Working Directory**: #{File.cwd!()}
  # - **Architecture**: #{:erlang.system_info(:system_architecture)}
  # - **Elixir Version**: #{System.version()}
  # - **OTP Version**: #{:erlang.system_info(:otp_release)}
  # """

  @default_opts [
    include_identity: true,
    include_environment: true,
    include_tools: true,
    include_rules: true,
    include_guidelines: true,
    include_user_prefs: false,
    include_context_summary: false
  ]

  @doc """
  构建系统提示词。

  ## 参数

  - `ctx`: 上下文数据，包含当前会话状态
  - `opts`: 选项列表，控制包含哪些部分

  ## 选项

  - `:include_identity` - 是否包含助手身份 (默认：true)
  - `:include_environment` - 是否包含系统环境信息 (默认：true)
  - `:include_tools` - 是否包含工具描述 (默认：true)
  - `:include_rules` - 是否包含对话规则 (默认：true)
  - `:include_guidelines` - 是否包含工具使用指南 (默认：true)
  - `:include_user_prefs` - 是否包含用户偏好 (默认：false)
  - `:include_context_summary` - 是否包含上下文摘要 (默认：false)

  ## 示例

      iex> Eris.Prompts.build_system_prompt(ctx, [include_tools: true])
      "You're Eris...\\n\\n## System Environment\\n..."
  """
  def build_system_prompt(ctx, opts \\ []) do
    opts = Keyword.merge(@default_opts, opts)

    sections =
      []
      |> maybe_add_section(opts[:include_identity], @assistant_identity)
      |> maybe_add_section(opts[:include_environment], get_final_environment(ctx))
      |> maybe_add_section(opts[:include_tools], get_tools_description(ctx))
      |> maybe_add_section(opts[:include_rules], @conversation_rules)
      |> maybe_add_section(opts[:include_guidelines], @tool_usage_guidelines)
      |> maybe_add_section(opts[:include_user_prefs], get_user_preferences(ctx))
      |> maybe_add_section(opts[:include_context_summary], get_context_summary(ctx))

    Enum.join(sections, "\n\n")
  end

  @doc """
  获取最终环境信息。

  根据上下文决定是否包含完整的环境信息。
  如果是默认界面或隐私敏感场景，可以省略部分信息。
  """
  def get_final_environment(ctx \\ %{}) do
    include_full_env = ctx[:include_full_environment] != false

    env_parts =
      ["Working Directory: #{File.cwd!()}", "Architecture: #{:erlang.system_info(:system_architecture)}"]

    if include_full_env do
      env_parts ++ [
        "Elixir Version: #{System.version()}",
        "OTP Version: #{:erlang.system_info(:otp_release)}"
      ]
    else
      env_parts
    end
    |> Enum.join("\n")

    "## System Environment\n\n#{env_parts}"
  end

  @doc """
  获取工具描述。

  从 Eris.Tools 模块获取所有工具的 schema，
  并格式化为 LLM 可理解的描述。
  """
  def get_tools_description(ctx \\ %{}) do
    tools = ctx[:tools] || Eris.Tools.all()
    schemas = Enum.map(tools, &Eris.Tool.function_calling/1)

    # 将 schema 转换为自然语言描述
    descriptions =
      Enum.map(schemas, fn schema ->
        func = schema["function"]
        "• **#{func["name"]}**: #{func["description"]}"
      end)
      |> Enum.join("\n")

    "## Available Tools\n\n#{descriptions}"
  end

  @doc """
  获取用户偏好。

  从上下文或配置中读取用户偏好设置。
  目前返回空字符串，未来可以从配置文件或用户设置中读取。
  """
  def get_user_preferences(ctx \\ %{}) do
    prefs = ctx[:user_preferences] || %{}

    if map_size(prefs) == 0 do
      ""
    else
      prefs_str =
        prefs
        |> Enum.map(fn {key, value} -> "- **#{key}**: #{inspect(value)}" end)
        |> Enum.join("\n")

      "## User Preferences\n\n#{prefs_str}"
    end
  end

  @doc """
  获取上下文摘要。

  当对话较长时，可以提供一个摘要，帮助 LLM 理解当前状态。
  这有助于节省 Token 并保持上下文连贯性。
  """
  def get_context_summary(ctx \\ %{}) do
    case ctx[:context_summary] do
      nil ->
        ""

      summary ->
        "## Context Summary\n\n#{summary}"
    end
  end

  # 添加部分到 sections 列表。
  defp maybe_add_section(sections, true, content) when is_binary(content) and content != "" do
    sections ++ [content]
  end

  defp maybe_add_section(sections, _, _content) do
    sections
  end

  @doc """
  估算 Token 数量。

  简单的估算方法：每 4 个字符约等于 1 个 token。
  更精确的实现可以使用专门的 token 计数库。
  """
  def estimate_tokens(text) when is_binary(text) do
    div(byte_size(text), 4) + 1
  end

  @doc """
  检查是否需要压缩上下文。

  根据最大上下文 token 限制和当前使用情况，
  判断是否需要对消息历史进行压缩。
  """
  def should_compress?(ctx, max_tokens) do
    current_tokens = ctx[:current_tokens] || 0
    threshold = max_tokens * 0.8

    current_tokens > threshold
  end

  @doc """
  构建完整的消息列表。

  将系统提示词和用户消息组合成完整的消息列表。
  """
  def build_messages(system_prompt, user_messages) do
    messages =
      if system_prompt != "" do
        [%{"role" => "system", "content" => system_prompt}]
      else
        []
      end

    messages ++ Enum.map(user_messages, fn msg ->
      %{"role" => "user", "content" => msg}
    end)
  end

  @doc """
  动态调整 Prompt 长度。

  根据 token 限制，动态调整 Prompt 的各个部分，
  确保总长度不超过限制。
  """
  def adjust_for_token_limit(system_prompt, max_tokens) do
    current_tokens = estimate_tokens(system_prompt)

    if current_tokens <= max_tokens do
      system_prompt
    else
      # 逐步移除非关键部分
      truncated =
        system_prompt
        |> remove_section("## User Preferences")
        |> remove_section("## Context Summary")
        |> remove_section("## Tool Usage Guidelines")

      new_tokens = estimate_tokens(truncated)

      if new_tokens <= max_tokens do
        truncated
      else
        # 进一步截断环境信息
        truncated
        |> remove_section("## System Environment")
        |> then(&if &1 == "", do: @assistant_identity, else: &1)
      end
    end
  end

  defp remove_section(text, section) do
    text
    |> String.split(section)
    |> List.first()
    |> String.trim_trailing("\n\n")
  end
end
