defmodule Eris.Seasons do
  # 避免与 Elixir 的 Agent 冲突
  # 就是四季（循环）没有四的意思
  require Logger

  @behaviour :gen_statem

  defmodule State do
    defstruct [
      :llm_conf,
      :subscriber,
      tools: [],
      messages: [],
      llm_task: nil,
      pending_tools: %{},
      # idx => %{id, name, args}
      tool_builder: %{},
      current_tool_index: nil,
      # 流式累积的 assistant 文本（用于构建 assistant message）
      current_content: "",
      # 流式累积的 tool_calls（用于构建 assistant message）
      current_tool_calls_raw: %{}
    ]
  end

  # ── 公开 API ──────────────────────────────────────

  def start_link(opts) do
    :gen_statem.start_link(__MODULE__, opts, [])
  end

  def start_link(name, opts) do
    :gen_statem.start_link({:local, name}, __MODULE__, opts, [])
  end

  @doc "发送用户输入，触发一轮推理"
  def user_input(pid, text) do
    :gen_statem.cast(pid, {:user_input, text})
  end

  @doc "订阅流式事件（subscriber 会收到 {:seasons_token, text} 等消息）"
  def subscribe(pid, subscriber_pid) do
    :gen_statem.cast(pid, {:subscribe, subscriber_pid})
  end

  @doc "查询当前状态"
  def get_state(pid) do
    :gen_statem.call(pid, :get_state)
  end

  # ── gen_statem 回调 ────────────────────────────────

  @impl true
  def callback_mode, do: [:state_functions, :state_enter]

  @impl true
  def init(options) do
    llm_conf = Keyword.fetch!(options, :llm_conf)
    tools = Keyword.get(options, :tools, Eris.Tools.all())
    subscriber = Keyword.get(options, :subscriber, nil)

    # 构建初始上下文
    ctx = %{
      include_full_environment: true,
      tools: tools,
      llm_conf: llm_conf
    }

    # 构建系统提示词
    system_prompt =
      Eris.Prompts.build_system_prompt(ctx,
        include_identity: true,
        include_environment: true,
        include_tools: true,
        include_rules: true,
        include_guidelines: true
      )

    initial_messages = [
      %{"role" => "system", "content" => system_prompt}
    ]

    {:ok, :idle,
     %State{
       llm_conf: llm_conf,
       tools: tools,
       subscriber: subscriber,
       messages: initial_messages
     }}
  end

  # ── :idle 状态 ─────────────────────────────────────

  def idle(:enter, _old_state, data) do
    notify(data, {:seasons_state, :idle})
    :keep_state_and_data
  end

  def idle(:cast, {:subscribe, pid}, data) do
    {:keep_state, %{data | subscriber: pid}}
  end

  def idle(:cast, {:user_input, text}, data) do
    new_msgs = data.messages ++ [%{"role" => "user", "content" => text}]
    {:next_state, :compressing, %{data | messages: new_msgs}}
  end

  def idle({:call, from}, :get_state, data) do
    {:keep_state_and_data, [{:reply, from, {:idle, data.messages}}]}
  end

  # ── :compressing 状态 ──────────────────────────────

  def compressing(:enter, _old_state, data) do
    notify(data, {:seasons_state, :thinking})
    # TODO: 估算 Token，必要时压缩
    send(self(), {:compression_done, data.messages})
    :keep_state_and_data
  end

  def compressing(:info, {:compression_done, messages}, data) do
    parent = self()
    tool_schemas = Enum.map(data.tools, &Eris.Tool.function_calling/1)

    task =
      Task.async(fn ->
        Eris.LLM.chat_completion(data.llm_conf, messages,
          stream_output: true,
          caller_pid: parent,
          tools: tool_schemas
        )
      end)

    {:next_state, :generating,
     %{data | messages: messages, llm_task: task, tool_builder: %{}, current_content: "", current_tool_calls_raw: %{}}}
  end

  # ── :generating 状态 ───────────────────────────────

  def generating(:enter, _old_state, _data), do: :keep_state_and_data

  # 1. 收到文本 token
  def generating(:info, {:llm_token, text}, data) do
    notify(data, {:seasons_token, text})
    {:keep_state, %{data | current_content: data.current_content <> text}}
  end

  # 2. 收到推理 token
  def generating(:info, {:llm_reasoning, delta}, data) do
    notify(data, {:seasons_reasoning, delta})
    :keep_state_and_data
  end

  # 3. 收到工具流片段
  def generating(:info, {:llm_tool_delta, deltas}, data) do
    new_data =
      Enum.reduce(deltas, data, fn delta, acc ->
        process_tool_delta(delta, acc)
      end)

    {:keep_state, new_data}
  end

  # 4. HTTP 流正式结束
  def generating(:info, {:llm_stream_done, final}, data) do
    # 更新 token 统计
    llm_conf = %{
      data.llm_conf
      | total_prompt_tokens: data.llm_conf.total_prompt_tokens + (final.usage.prompt_tokens || 0),
        total_completion_tokens:
          data.llm_conf.total_completion_tokens + (final.usage.completion_tokens || 0)
    }

    data = %{data | llm_conf: llm_conf}

    # 流结束，最后一个工具的 JSON 肯定完整了
    data_final = flush_last_tool(data)

    if map_size(data_final.pending_tools) > 0 do
      # 还有工具在跑，转入等待状态
      {:next_state, :awaiting_tools, data_final}
    else
      # 没工具，纯文本对话结束
      notify(data_final, {:seasons_done, data_final.current_content})
      {:next_state, :idle, data_final}
    end
  end

  # 5. 有极快的工具在 generating 期间就跑完了
  def generating(:info, {ref, tool_result}, data) when is_map_key(data.pending_tools, ref) do
    data = handle_tool_result(data, ref, tool_result)
    {:keep_state, data}
  end

  # 忽略 Task DOWN 消息
  def generating(:info, {:DOWN, _ref, :process, _pid, :normal}, _data), do: :keep_state_and_data

  # ── :awaiting_tools 状态 ───────────────────────────

  def awaiting_tools(:enter, _old_state, data) do
    notify(data, {:seasons_state, :tool_running})
    :keep_state_and_data
  end

  def awaiting_tools(:info, {ref, tool_result}, data) when is_map_key(data.pending_tools, ref) do
    data = handle_tool_result(data, ref, tool_result)

    if map_size(data.pending_tools) == 0 do
      # 所有工具跑完，自动开启下一轮推理
      send(self(), {:compression_done, data.messages})
      {:next_state, :compressing, data}
    else
      {:keep_state, data}
    end
  end

  def awaiting_tools(:info, {:DOWN, _ref, :process, _pid, :normal}, _data),
    do: :keep_state_and_data

  # ── 内部辅助函数 ───────────────────────────────────

  # 通知订阅者
  defp notify(%State{subscriber: nil}, _msg), do: :ok
  defp notify(%State{subscriber: pid}, msg), do: send(pid, msg)

  # 处理工具流片段，当 index 切换时立即触发上一个工具
  defp process_tool_delta(delta, data) do
    idx = delta["index"]
    func = delta["function"] || %{}

    current_tool =
      Map.get(data.tool_builder, idx, %{
        id: delta["id"] || "",
        name: func["name"] || "",
        args: ""
      })

    updated_tool = %{
      current_tool
      | id: current_tool.id <> (delta["id"] || ""),
        name: current_tool.name <> (func["name"] || ""),
        args: current_tool.args <> (func["arguments"] || "")
    }

    # 当流切换到下一个 index 时，上一个 index 的 JSON 肯定完整了
    data =
      if data.current_tool_index != nil and data.current_tool_index != idx do
        trigger_tool(data, data.current_tool_index)
      else
        data
      end

    %{
      data
      | tool_builder: Map.put(data.tool_builder, idx, updated_tool),
        current_tool_index: idx
    }
  end

  # 流彻底结束时，触发最后一个工具
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
      {:ok, args_map} ->
        Logger.info("[Seasons] 触发工具: #{tool_info.name}")
        notify(data, {:seasons_tool_call, tool_info.name, args_map})

        # 构建工具执行上下文
        tool_ctx = %Eris.Tool.Context{
          cwd: File.cwd!(),
          changed_files: MapSet.new(),
          llm_conf: data.llm_conf,
          tools: data.tools
        }

        # 异步执行工具
        task =
          Task.async(fn ->
            {result_text, _new_ctx} = Eris.Tools.execute(tool_info.name, args_map, tool_ctx)
            result_text
          end)

        # 记录 pending，key 是 task.ref，value 是 {tool_call_id, tool_name}
        pending = Map.put(data.pending_tools, task.ref, {tool_info.id, tool_info.name})

        # 把 assistant 的 tool_call 记录到 current_tool_calls_raw（用于后续构建 assistant message）
        new_raw = Map.put(data.current_tool_calls_raw, idx, tool_info)

        %{data | pending_tools: pending, current_tool_calls_raw: new_raw}

      {:error, _} ->
        Logger.error("[Seasons] 解析工具参数失败: #{tool_info.args}")
        data
    end
  end

  defp handle_tool_result(data, ref, result_text) do
    {tool_call_id, tool_name} = data.pending_tools[ref]
    pending = Map.delete(data.pending_tools, ref)

    Logger.info("[Seasons] 工具完成: #{tool_name}")
    notify(data, {:seasons_tool_result, tool_name, result_text})

    # 如果这是第一个工具结果，先把 assistant message（含 tool_calls）写入 messages
    # 只在 pending_tools 从非空变为某个值时写一次 assistant message
    # 简化：每次工具完成都检查是否需要写 assistant message
    messages =
      if needs_assistant_message?(data.messages) do
        assistant_msg = build_assistant_message(data.current_content, data.current_tool_calls_raw)
        data.messages ++ [assistant_msg]
      else
        data.messages
      end

    tool_msg = %{
      "role" => "tool",
      "tool_call_id" => tool_call_id,
      "content" => result_text
    }

    %{data | pending_tools: pending, messages: messages ++ [tool_msg]}
  end

  # 检查是否需要写入 assistant message（避免重复写入）
  defp needs_assistant_message?(messages) do
    case List.last(messages) do
      %{"role" => "assistant"} -> false
      %{"role" => "tool"} -> false
      _ -> true
    end
  end

  defp build_assistant_message(content, tool_calls_raw) do
    openai_tool_calls =
      tool_calls_raw
      |> Enum.sort_by(fn {idx, _} -> idx end)
      |> Enum.map(fn {_idx, tc} ->
        %{
          "id" => tc.id,
          "type" => "function",
          "function" => %{
            "name" => tc.name,
            "arguments" => tc.args
          }
        }
      end)

    %{
      "role" => "assistant",
      "content" => if(content == "", do: nil, else: content),
      "tool_calls" => openai_tool_calls
    }
  end
end
