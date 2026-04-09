defmodule Eris.AgentLoop do
  @moduledoc """
  简单的同步 Agent 循环。

  用于子 Agent 和一次性调用。
  不依赖 GenStatem，纯函数式递归。
  """

  def run(task, llm_conf, tools, opts \\ []) do
    max_rounds = Keyword.get(opts, :max_rounds, 80)
    max_context_tokens = Keyword.get(opts, :max_context_tokens, 128_000)

    system_msg = Eris.Prompts.build_system_prompt(tools, [])

    messages = [
      %{"role" => "system", "content" => system_msg},
      %{"role" => "user", "content" => task}
    ]

    ctx = %Eris.Tool.Context{
      cwd: File.cwd!(),
      changed_files: MapSet.new(),
      llm_conf: llm_conf,
      tools: tools
    }

    loop(messages, ctx, llm_conf, tools, max_rounds, max_context_tokens)
  end

  defp loop(_messages, _ctx, _llm_conf, _tools, 0, _max_ctx),
    do: "(reached maximum tool-call rounds)"

  defp loop(messages, ctx, llm_conf, tools, rounds_left, max_context_tokens) do
    # TODO: 上下文压缩
    tool_schemas = Enum.map(tools, &Eris.Tool.function_calling/1)

    result =
      Eris.LLM.chat_completion(llm_conf, messages,
        stream_output: false,
        tools: tool_schemas
      ) |> IO.inspect()

    if result.tool_calls == [] or result.tool_calls == %{} do
      # 纯文本回复，结束循环
      result.content || ""
    else
      # 有工具调用 → 执行 → 递归
      tool_calls_list = normalize_tool_calls(result.tool_calls)

      # 写入 assistant 消息
      assistant_msg = build_assistant_message(result.content, tool_calls_list)
      messages = messages ++ [assistant_msg]

      # 执行所有工具
      {tool_messages, ctx} =
        Enum.map_reduce(tool_calls_list, ctx, fn tc, acc_ctx ->
          tool_name = tc["function"]["name"]
          tool_args = tc["function"]["arguments"]

          {result_text, new_ctx} = Eris.Tools.execute(tool_name, tool_args, acc_ctx)

          msg = %{
            "role" => "tool",
            "tool_call_id" => tc["id"],
            "content" => result_text
          }

          {msg, new_ctx}
        end)

      messages = messages ++ tool_messages
      loop(messages, ctx, llm_conf, tools, rounds_left - 1, max_context_tokens)
    end
  end

  # tool_calls 可能是 list（来自 do_normal_request）或 map（来自流式）
  defp normalize_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, fn tc ->
      args =
        case get_in(tc, ["function", "arguments"]) do
          args when is_map(args) ->
            args

          args when is_binary(args) ->
            case Jason.decode(args) do
              {:ok, parsed} -> parsed
              {:error, _} -> %{}
            end

          _ ->
            %{}
        end

      %{
        "id" => tc["id"],
        "type" => "function",
        "function" => %{
          "name" => tc["function"]["name"],
          "arguments" => args
        }
      }
    end)
  end

  defp normalize_tool_calls(tool_calls) when is_map(tool_calls) do
    # 流式路径：idx => %{id, name, args}，args 是未解析的 JSON 字符串
    tool_calls
    |> Enum.sort_by(fn {idx, _} -> idx end)
    |> Enum.map(fn {_idx, tc} ->
      args =
        case tc[:args] || tc["args"] do
          s when is_binary(s) ->
            case Jason.decode(s) do
              {:ok, parsed} -> parsed
              {:error, _} -> %{}
            end

          m when is_map(m) ->
            m

          _ ->
            %{}
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
                args -> args
              end
          }
        }
      end)

    Map.put(msg, "tool_calls", openai_tool_calls)
  end
end
