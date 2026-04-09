defmodule Eris.LLM do
  # 照理说可以用 OpenAI Compat 的库来做。
  # 但不清楚怎么处理 Stream ，于是就手搓轮子了。
  defmodule Config do
    # 这种动态 Config 而不用 Elixir 的 Config 是为了适配这样的情形：
    # 主 Agent 选择 SOTA
    # 而副 Agent 选择量大管饱的模型
    @type t :: %__MODULE__{
            root_url: binary() | nil,
            provider: binary() | nil,
            model: binary(),
            api_key: binary(),
            max_tokens: non_neg_integer(),
            temperature: float(),
            max_context_tokens: non_neg_integer(),
            total_prompt_tokens: non_neg_integer(),
            total_completion_tokens: non_neg_integer(),
            manifest: map()
          }
    defstruct [
      :root_url,
      :provider,
      :model,
      :api_key,
      max_tokens: 8192,
      temperature: 0.0,
      max_context_tokens: 128_000,
      total_prompt_tokens: 0,
      total_completion_tokens: 0,
      manifest: %{}
    ]
  end

  defmodule DumbReceiver do
    def fetch_content(prev \\ %{content: "", maybe_reasoning: "", tool_calls_raw: %{}}) do
      receive do
        {:llm_token, content} ->
          fetch_content(%{prev | content: prev.content <> content})

        {:llm_reasoning, delta} ->
          fetch_content(%{prev | maybe_reasoning: prev.maybe_reasoning <> delta})

        {:llm_stream_done, fin} ->
          fin
      end
    end
  end

  @default_root_url "https://openrouter.ai/api/v1"

  def chat_completion(llm_conf = %Config{}, prev_messages, opts) do
    caller_pid = Keyword.get(opts, :caller_pid, self())
    url = build_url(llm_conf.root_url, "completions")
    stream? = Keyword.get(opts, :stream_output, true)
    tools = Keyword.get(opts, :tools, nil)

    model =
      if(is_nil(llm_conf.provider),
        do: llm_conf.model,
        else: llm_conf.provider <> "/" <> llm_conf.model
      )

    body =
      %{
        "model" => model,
        "messages" => prev_messages,
        "stream" => stream?,
        "temperature" => llm_conf.temperature,
        "max_tokens" => llm_conf.max_tokens
      }
      |> then(&if tools, do: Map.put(&1, "tools", tools), else: &1)
      |> then(
        &if stream?, do: Map.put(&1, "stream_options", %{"include_usage" => true}), else: &1
      )

    headers = [
      {"Authorization", "Bearer #{llm_conf.api_key}"},
      {"Content-Type", "application/json"}
    ]

    if stream? do
      do_stream_request(url, headers, body, caller_pid)
    else
      do_normal_request(url, headers, body)
    end
  end

  def responses(llm_conf = %Config{}, prev_messages, opts) do
    caller_pid = Keyword.get(opts, :caller_pid, self())
    url = build_url(llm_conf.root_url, "responses")
    stream? = Keyword.get(opts, :stream_output, true)
    tools = Keyword.get(opts, :tools, nil)

    model =
      if(is_nil(llm_conf.provider),
        do: llm_conf.model,
        else: llm_conf.provider <> "/" <> llm_conf.model
      )

    body =
      %{
        "model" => model,
        "input" => prev_messages,
        "stream" => stream?,
        "temperature" => llm_conf.temperature,
        "max_output_tokens" => llm_conf.max_tokens
      }
      |> then(&if tools, do: Map.put(&1, "tools", tools), else: &1)

    headers = [
      {"Authorization", "Bearer #{llm_conf.api_key}"},
      {"Content-Type", "application/json"}
    ]

    if stream? do
      do_responses_stream_request(url, headers, body, caller_pid)
    else
      do_responses_normal_request(url, headers, body)
    end
  end

  defp build_url(nil, "completions"), do: build_url(@default_root_url, "completions")
  defp build_url(base, "completions"), do: String.trim_trailing(base, "/") <> "/chat/completions"
  defp build_url(nil, "responses"), do: build_url(@default_root_url, "responses")
  defp build_url(base, "responses"), do: String.trim_trailing(base, "/") <> "/responses"

  defp do_stream_request(url, headers, body, caller_pid) do
    initial_acc = %{
      content: "",
      tool_calls_raw: %{},
      prompt_tokens: 0,
      completion_tokens: 0,
      buffer: ""
    }

    req_result =
      Req.post!(url,
        json: body,
        headers: headers,
        receive_timeout: 60_000,
        into: fn {:data, chunk}, {req, res} ->
          state = if is_binary(res.body), do: initial_acc, else: res.body

          raw_data = state.buffer <> chunk

          parts = String.split(raw_data, "\n\n")

          {complete_events, [leftover]} = Enum.split(parts, -1)

          new_state =
            Enum.reduce(complete_events, %{state | buffer: leftover}, fn event, acc ->
              parse_sse_event(event, acc, caller_pid)
            end)

          {:cont, {req, %{res | body: new_state}}}
        end
      )

    with %{} = final_state <- req_result.body do
      tool_calls =
        final_state.tool_calls_raw
        |> Enum.sort_by(fn {idx, _} -> idx end)
        |> Enum.map(fn {_idx, tc} ->
          args_map =
            case Jason.decode(tc.args) do
              {:ok, parsed} -> parsed
              {:error, _} -> %{}
            end

          %{
            "id" => tc.id,
            "type" => "function",
            "function" => %{
              "name" => tc.name,
              "arguments" => args_map
            }
          }
        end)

      renamed_final = %{
        content: final_state.content,
        tool_calls: tool_calls,
        usage: %{
          prompt_tokens: final_state.prompt_tokens,
          completion_tokens: final_state.completion_tokens
        }
      }

      send(caller_pid, {:llm_stream_done, renamed_final})
    else
      maybe_err ->
        send(caller_pid, {:dump, maybe_err})
    end
  end

  defp do_responses_stream_request(url, headers, body, caller_pid) do
    initial_acc = %{
      content: "",
      reasoning: "",
      tool_calls_raw: %{},
      prompt_tokens: 0,
      completion_tokens: 0,
      buffer: ""
    }

    req_result =
      Req.post!(url,
        json: body,
        headers: headers,
        receive_timeout: 60_000,
        into: fn {:data, chunk}, {req, res} ->
          state = if is_binary(res.body), do: initial_acc, else: res.body

          raw_data = state.buffer <> chunk
          parts = String.split(raw_data, "\n\n")
          {complete_events, [leftover]} = Enum.split(parts, -1)

          new_state =
            Enum.reduce(complete_events, %{state | buffer: leftover}, fn event, acc ->
              parse_responses_sse_event(event, acc, caller_pid)
            end)

          {:cont, {req, %{res | body: new_state}}}
        end
      )

    with %{} = final_state <- req_result.body do
      renamed_final = %{
        content: final_state.content,
        reasoning: final_state.reasoning,
        tool_calls: final_state.tool_calls_raw,
        usage: %{
          prompt_tokens: final_state.prompt_tokens,
          completion_tokens: final_state.completion_tokens
        }
      }

      send(caller_pid, {:llm_stream_done, renamed_final})
    end
  end

  defp parse_sse_event(event_str, acc, caller_pid) do
    case String.trim(event_str) do
      "data: [DONE]" ->
        acc

      "data: " <> json_str ->
        case Jason.decode(json_str) do
          {:ok, data} ->
            # 解析 Token 统计 (通常在最后一个 Chunk 出现)
            acc =
              case data["usage"] do
                %{"prompt_tokens" => p, "completion_tokens" => c} when not is_nil(p) ->
                  %{acc | prompt_tokens: p, completion_tokens: c}

                _ ->
                  acc
              end

            # 解析 Delta 内容
            delta = get_in(data, ["choices", Access.at(0), "delta"]) || %{}

            # 处理纯文本输出
            acc =
              if content = delta["content"] do
                if content != "", do: send(caller_pid, {:llm_token, content})
                %{acc | content: acc.content <> content}
              else
                acc
              end

            acc =
              case delta["tool_calls"] do
                nil ->
                  acc

                tc_deltas ->
                  send(caller_pid, {:llm_tool_delta, tc_deltas})

                  Enum.reduce(tc_deltas, acc, fn tc_delta, inner_acc ->
                    idx = tc_delta["index"]

                    existing =
                      Map.get(inner_acc.tool_calls_raw, idx, %{id: "", name: "", args: ""})

                    updated = %{
                      existing
                      | id: existing.id <> (tc_delta["id"] || ""),
                        name:
                          existing.name <>
                            (get_in(tc_delta, ["function", "name"]) || ""),
                        args:
                          existing.args <>
                            (get_in(tc_delta, ["function", "arguments"]) || "")
                    }

                    %{inner_acc | tool_calls_raw: Map.put(inner_acc.tool_calls_raw, idx, updated)}
                  end)
              end

            acc

          {:error, _reason} ->
            acc
        end

      _ignore ->
        acc
    end
  end

  defp do_normal_request(url, headers, body) do
    response = Req.post!(url, json: body, headers: headers, receive_timeout: 120_000)

    choice = get_in(response.body, ["choices", Access.at(0), "message"]) || %{}
    usage = response.body["usage"] || %{}

    %{
      content: choice["content"] || "",
      tool_calls: choice["tool_calls"] || [],
      usage: %{
        prompt_tokens: usage["prompt_tokens"] || 0,
        completion_tokens: usage["completion_tokens"] || 0
      }
    }
  end

  defp parse_responses_sse_event(event_str, acc, caller_pid) do
    # Responses API 的 SSE 格式：只有 data: 行，没有 event: 行
    # 类型信息在 JSON 的 "type" 字段中
    json_str =
      event_str
      |> String.split("\n")
      |> Enum.find_value(fn line ->
        if String.starts_with?(line, "data: ") do
          String.replace_prefix(line, "data: ", "")
        end
      end)

    case json_str do
      nil ->
        acc

      json_str ->
        case Jason.decode(json_str) do
          {:ok, data} ->
            handle_responses_event(data["type"], data, acc, caller_pid)

          {:error, _} ->
            acc
        end
        |> IO.inspect()
    end
  end

  # 文本输出增量
  defp handle_responses_event("response.output_text.delta", data, acc, caller_pid) do
    delta = data["delta"] || ""

    if delta != "" do
      send(caller_pid, {:llm_token, delta})
    end

    %{acc | content: acc.content <> delta}
  end

  # 推理摘要增量（reasoning model 特有）
  defp handle_responses_event("response.reasoning_summary_text.delta", data, acc, caller_pid) do
    delta = data["delta"] || ""

    if delta != "" do
      send(caller_pid, {:llm_reasoning, delta})
    end

    %{acc | reasoning: acc.reasoning <> delta}
  end

  # 流式完成：提取 usage
  defp handle_responses_event("response.completed", data, acc, _caller_pid) do
    usage = get_in(data, ["response", "usage"]) || %{}

    prompt_tokens = usage["input_tokens"] || usage["prompt_tokens"] || 0
    completion_tokens = usage["output_tokens"] || usage["completion_tokens"] || 0

    %{acc | prompt_tokens: prompt_tokens, completion_tokens: completion_tokens}
  end

  # 工具调用参数增量（预留）
  defp handle_responses_event("response.function_call_arguments.delta", data, acc, _caller_pid) do
    # TODO: 拼接工具调用参数
    # data["delta"] 是参数 JSON 片段
    # data["output_index"] 和 data["call_id"] 可用于标识是哪个工具调用
    IO.inspect(data)

    acc
  end

  # 忽略所有其他事件类型
  # response.created, response.in_progress, response.output_item.added,
  # response.reasoning_summary_part.added, response.reasoning_summary_text.done,
  # response.reasoning_summary_part.done, response.output_item.done,
  # response.content_part.added, response.output_text.done,
  # response.content_part.done, 等
  defp handle_responses_event(_type, _data, acc, _caller_pid) do
    acc
  end

  defp do_responses_normal_request(url, headers, body) do
    response = Req.post!(url, json: body, headers: headers, receive_timeout: 120_000)

    # 从 output 数组中提取文本和推理
    output = response.body["output"] || []

    {content, reasoning} =
      Enum.reduce(output, {"", ""}, fn item, {content_acc, reasoning_acc} ->
        case item["type"] do
          "message" ->
            # 从 message 类型的 item 中提取文本
            text =
              item["content"]
              |> Enum.map_join(fn part -> part["text"] || "" end)

            {content_acc <> text, reasoning_acc}

          "reasoning" ->
            # 从 reasoning 类型的 item 中提取摘要
            summary_text =
              item["summary"]
              |> Enum.map_join(fn part -> part["text"] || "" end)

            {content_acc, reasoning_acc <> summary_text}

          _ ->
            {content_acc, reasoning_acc}
        end
      end)

    usage = response.body["usage"] || %{}

    %{
      content: content,
      reasoning: reasoning,
      tool_calls: [],
      usage: %{
        prompt_tokens: usage["input_tokens"] || usage["prompt_tokens"] || 0,
        completion_tokens: usage["output_tokens"] || usage["completion_tokens"] || 0
      }
    }
  end
end
