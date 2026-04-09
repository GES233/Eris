defmodule Eris.Seasons do
  # 避免与 Elixir 的 Agent 冲突
  # 就是四季（循环）没有四的意思
  require Logger

  @behaviour :gen_statem

  defmodule State do
    defstruct [
      :llm,
      messages: [],
      llm_task: nil,
      pending_tools: %{},
      tool_builder: %{},
      current_tool_index: nil
    ]
  end

  @impl true
  def callback_mode, do: [:state_functions, :state_enter]

  @impl true
  def init(options) do
    llm_conf = Keyword.fetch!(options, :llm_conf)
    tools = Keyword.get(options, :tools, Eris.Tools.all())

    # 构建初始上下文
    ctx = %{
      include_full_environment: true,
      tools: tools,
      llm_conf: llm_conf
    }

    # 构建系统提示词
    system_prompt = Eris.Prompts.build_system_prompt(ctx,
      include_identity: true,
      include_environment: true,
      include_tools: true,
      include_rules: true,
      include_guidelines: true
    )

    # 初始化消息列表，包含系统提示词
    initial_messages = [
      %{"role" => "system", "content" => system_prompt}
    ]

    {:ok, :idle, %State{
      llm: llm_conf,
      messages: initial_messages,
      llm_task: nil,
      pending_tools: %{},
      tool_builder: %{},
      current_tool_index: nil,
      # system_prompt: system_prompt,
      # ctx: ctx
    }}
  end

  def idle(:enter, _old_state, _data), do: :keep_state_and_data

  def idle(:cast, {:user_input, text}, data) do
    new_msgs = data.messages ++ [%{"role" => "user", "content" => text}]

    # 收到输入后，先进入压缩检查状态
    {:next_state, :compressing, %{data | messages: new_msgs}}
  end

  def idle({:call, from}, :get_state, data) do
    {:keep_state_and_data, [{:reply, from, {:idle, data.messages}}]}
  end

  def compressing(:enter, _old_state, data) do
    # TODO: 估算 Token
    # token_count = estimate_tokens(data.messages)

    # if token_count > data.llm_conf.max_context_tokens * 0.8 do
    #   Logger.info("Context large, compressing...")
    #   compressed = do_compression(data.messages)
    #   send(self(), {:compression_done, compressed})
    # else
    send(self(), {:compression_done, data.messages})
    # end
    :keep_state_and_data
  end

  def compressing(:info, {:compression_done, messages}, data) do
    parent = self()

    task =
      Task.async(fn ->
        Eris.LLM.chat_completion(data.llm_conf, messages, stream_output: true, caller_pid: parent)
      end)

    {:next_state, :generating, %{data | messages: messages, llm_task: task, tool_builder: %{}}}
  end

  def generating(:enter, _old_state, _data), do: :keep_state_and_data

  # 1. 收到文本
  def generating(:info, {:llm_token, text}, _data) do
    # 直接在终端打印
    IO.write(text)
    :keep_state_and_data
  end

  # 2. 收到工具流片段
  def generating(:info, {:llm_tool_delta, deltas}, data) do
    new_data =
      Enum.reduce(deltas, data, fn delta, acc ->
        process_tool_delta(delta, acc)
      end)

    {:keep_state, new_data}
  end

  # 3. HTTP 流正式结束
  def generating(:info, {:llm_stream_done, _renamed_final}, data) do
    # 如果有 Token usage 的话，先记录在上面

    # 流结束意味着最后一个工具的 JSON 肯定完整了，检查并触发
    data_final = flush_last_tool(data)

    if map_size(data_final.pending_tools) > 0 do
      # 还有工具在跑，转入等待状态
      {:next_state, :awaiting_tools, data_final}
    else
      # 没工具了，纯文本对话结束
      IO.puts("\n")
      {:next_state, :idle, data_final}
    end
  end

  # 4. 有极快的工具在 Generating 期间就跑完了！
  def generating(:info, {ref, tool_result}, data) when is_map_key(data.pending_tools, ref) do
    data = handle_tool_result(data, ref, tool_result)
    {:keep_state, data}
  end

  # 处理 Task 退出消息 (消除控制台警告)
  def generating(:info, {:DOWN, _ref, :process, _pid, :normal}, _data), do: :keep_state_and_data

  def awaiting_tools(:enter, _old_state, _data), do: :keep_state_and_data

  def awaiting_tools(:info, {ref, tool_result}, data) when is_map_key(data.pending_tools, ref) do
    data = handle_tool_result(data, ref, tool_result)

    if map_size(data.pending_tools) == 0 do
      # 所有工具跑完！自动开启下一轮推理 (递归)
      send(self(), {:compression_done, data.messages})
      {:next_state, :compressing, data}
    else
      {:keep_state, data}
    end
  end

  def awaiting_tools(:info, {:DOWN, _ref, :process, _pid, :normal}, _data),
    do: :keep_state_and_data

  defp process_tool_delta(delta, data) do
    idx = delta["index"]
    func = delta["function"] || %{}

    # 初始化或更新工具在 buffer 中的内容
    current_tool =
      Map.get(data.tool_builder, idx, %{id: delta["id"], name: func["name"], args: ""})

    new_args = current_tool.args <> (func["arguments"] || "")
    updated_tool = %{current_tool | args: new_args}

    # 精彩的地方：当流切换到下一个 index 时，说明上一个 index 肯定完整了！
    data =
      if data.current_tool_index != nil and data.current_tool_index != idx do
        # 触发前一个工具
        trigger_tool(data, data.current_tool_index)
      else
        data
      end

    %{data | tool_builder: Map.put(data.tool_builder, idx, updated_tool), current_tool_index: idx}
  end

  # 当流彻底结束时，把最后一个工具触发了
  defp flush_last_tool(data) do
    if data.current_tool_index != nil do
      trigger_tool(data, data.current_tool_index)
    else
      data
    end
  end

  defp trigger_tool(data, idx) do
    tool_info = data.tool_builder[idx]

    case Jason.decode(tool_info.args) do
      {:ok, _args_map} ->
        Logger.info("\n[即刻执行工具] #{tool_info.name}")

        # 异步启动工具 Task
        task =
          Task.async(fn ->
            # 调用你的具体工具模块
            # Eris.Tools.execute(tool_info.name, args_map)
            "Result of #{tool_info.name}"
          end)

        # 追加到消息历史（此时要把大模型的 tool_call 先记录下来）
        # 注意：这里需要把助理发起 call 的消息记录下来，这对于继续对话至关重要
        # 略微简化，实际需要构造标准 OpenAI function_call message

        pending = Map.put(data.pending_tools, task.ref, tool_info.id)
        %{data | pending_tools: pending}

      {:error, _} ->
        Logger.error("解析工具参数失败: #{tool_info.args}")
        data
    end
  end

  defp handle_tool_result(data, ref, result) do
    tool_id = data.pending_tools[ref]
    pending = Map.delete(data.pending_tools, ref)

    # 将结果放入 messages
    tool_msg = %{"role" => "tool", "tool_call_id" => tool_id, "content" => result}

    %{data | pending_tools: pending, messages: data.messages ++ [tool_msg]}
  end
end
