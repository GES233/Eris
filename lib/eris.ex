defmodule Eris do
  @moduledoc """
  Documentation for `Eris`.
  """

  def chat(prompt, opts \\ []) do
    llm_conf = Keyword.fetch!(opts, :llm_conf)
    tools = Keyword.get_lazy(opts, :tools, &Eris.Tools.all/0)
    max_rounds = Keyword.get(opts, :max_rounds, 50)

    IO.puts(IO.ANSI.cyan() <> "You > " <> IO.ANSI.reset() <> prompt)
    IO.puts("")

    system_msg = Eris.Prompts.build_system_prompt(tools, [])

    messages = [
      %{"role" => "system", "content" => system_msg},
      %{"role" => "user", "content" => prompt}
    ]

    ctx = Eris.Tool.Context.new(llm_conf: llm_conf, tools: tools)

    streaming_loop(messages, ctx, llm_conf, tools, max_rounds)
  end

  # ── 流式 Agent 循环 ──────────────────────────────

  defp streaming_loop(_messages, _ctx, _llm_conf, _tools, 0) do
    IO.puts("\n(reached maximum tool-call rounds)")
    nil
  end

  defp streaming_loop(messages, ctx, llm_conf, tools, rounds_left) do
    tool_schemas = Enum.map(tools, &Eris.Tool.function_calling/1)
    parent = self()

    # 在独立 Task 里跑 HTTP 流，IEx 进程收消息打印
    task =
      Task.async(fn ->
        try do
          Eris.LLM.chat_completion(llm_conf, messages,
            stream_output: true,
            caller_pid: parent,
            tools: tool_schemas
          )
        rescue
          e -> {:error, Exception.message(e)}
        end
      end)

    case collect_stream(task) do
      {:error, msg} ->
        IO.puts(IO.ANSI.red() <> "\n[Error] #{msg}" <> IO.ANSI.reset())
        nil

      final ->
        tool_calls_list = normalize_tool_calls(final.tool_calls)

        if Enum.empty?(tool_calls_list) do
          # 纯文本回复，结束
          IO.puts("\n")
          final.content || ""
        else
          IO.puts("\n")

          # ★ 把 assistant 消息（含 tool_calls）写入 history ★
          assistant_msg = build_assistant_message(final.content, tool_calls_list)
          messages = messages ++ [assistant_msg]

          # 执行所有工具（并行）
          {tool_messages, ctx} =
            if length(tool_calls_list) == 1 do
              # 单个工具，直接执行
              execute_one(tool_calls_list |> hd(), ctx)
            else
              # 多个工具，并行执行
              execute_parallel(tool_calls_list, ctx)
            end

          messages = messages ++ tool_messages

          # 更新 token 统计
          llm_conf = %{
            llm_conf
            | total_prompt_tokens: llm_conf.total_prompt_tokens + final.usage.prompt_tokens,
              total_completion_tokens:
                llm_conf.total_completion_tokens + final.usage.completion_tokens
          }

          # 递归进入下一轮
          streaming_loop(messages, ctx, llm_conf, tools, rounds_left - 1)
        end
    end
  end

  # ── 流式收集 ──────────────────────────────────────

  defp collect_stream(task, timeout \\ 180_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect(task, deadline)
  end

  defp do_collect(task, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))
    task_ref = task.ref

    receive do
      # 文本 token → 逐字打印
      {:llm_token, text} ->
        IO.write(text)
        do_collect(task, deadline)

      # 推理 token（reasoning model）
      {:llm_reasoning, delta} ->
        IO.write(IO.ANSI.italic() <> IO.ANSI.faint() <> delta <> IO.ANSI.reset())
        do_collect(task, deadline)

      # 流结束 → 拿到完整结果
      {:llm_stream_done, final} ->
        Task.await(task, 5_000)
        final

      # Task 出错（HTTP 异常等）
      {^task_ref, {:error, msg}} ->
        {:error, msg}

      # Task 正常返回但没发 stream_done（不应发生）
      {^task_ref, _result} ->
        %{content: "", tool_calls: [], usage: %{prompt_tokens: 0, completion_tokens: 0}}

      # 忽略 DOWN 正常退出
      {:DOWN, _ref, :process, _pid, :normal} ->
        do_collect(task, deadline)
    after
      remaining ->
        Task.shutdown(task, :brutal_kill)
        {:error, "LLM request timed out"}
    end
  end

  # ── 工具执行 ──────────────────────────────────────

  defp execute_one(tc, ctx) do
    tool_name = tc["function"]["name"]
    tool_args = tc["function"]["arguments"]

    IO.puts(IO.ANSI.faint() <> "  > #{tool_name}(#{brief_args(tool_args)})" <> IO.ANSI.reset())

    {result_text, new_ctx} = Eris.Tools.execute(tool_name, tool_args, ctx)

    tool_msg = %{
      "role" => "tool",
      "tool_call_id" => tc["id"],
      "content" => result_text
    }

    {[tool_msg], new_ctx}
  end

  defp execute_parallel(tool_calls, ctx) do
    # 为每个工具启动独立 Task，并发执行
    # 和 Python 版 ThreadPool 并行执行思路一致
    tasks =
      Enum.map(tool_calls, fn tc ->
        tool_name = tc["function"]["name"]
        tool_args = tc["function"]["arguments"]

        IO.puts(
          IO.ANSI.faint() <>
            "  > #{tool_name}(#{brief_args(tool_args)})" <>
            IO.ANSI.reset()
        )

        {tc, Task.async(fn -> Eris.Tools.execute(tool_name, tool_args, ctx) end)}
      end)

    # 按顺序收集结果，ctx 线程化传递
    Enum.map_reduce(tasks, ctx, fn {tc, task}, _acc_ctx ->
      {result_text, new_ctx} = Task.await(task, 120_000)

      tool_msg = %{
        "role" => "tool",
        "tool_call_id" => tc["id"],
        "content" => result_text
      }

      {tool_msg, new_ctx}
    end)
  end

  # ── 辅助函数 ──────────────────────────────────────

  defp brief_args(args, maxlen \\ 80) do
    s =
      args
      |> Enum.map(fn {k, v} -> "#{k}=#{String.slice(inspect(v), 0, 40)}" end)
      |> Enum.join(", ")

    if byte_size(s) > maxlen,
      do: String.slice(s, 0, maxlen) <> "...",
      else: s
  end

  # tool_calls 可能是 list（non-streaming）或 map（streaming，idx => %{id, name, args}）
  defp normalize_tool_calls(tool_calls) when is_list(tool_calls), do: tool_calls

  defp normalize_tool_calls(tool_calls) when is_map(tool_calls) do
    tool_calls
    |> Enum.sort_by(fn {idx, _} -> idx end)
    |> Enum.map(fn {_idx, tc} ->
      args =
        case tc[:args] || tc["args"] do
          s when is_binary(s) -> Jason.decode!(s)
          m when is_map(m) -> m
        end

      %{
        "id" => tc[:id] || tc["id"],
        "type" => "function",
        "function" => %{
          "name" => tc[:name] || tc["name"],
          "arguments" => args
        }
      }
    end)
  end

  defp normalize_tool_calls(_), do: []

  defp build_assistant_message(content, tool_calls) do
    msg = %{"role" => "assistant", "content" => content || nil}

    openai_tool_calls =
      Enum.map(tool_calls, fn tc ->
        %{
          "id" => tc["id"],
          "type" => "function",
          "function" => %{
            "name" => tc["function"]["name"],
            "arguments" =>
              case tc["function"]["arguments"] do
                args when is_map(args) -> Jason.encode!(args)
                args -> to_string(args)
              end
          }
        }
      end)

    Map.put(msg, "tool_calls", openai_tool_calls)
  end
end
