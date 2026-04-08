defmodule Eris.LLM do
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

  defmodule DumbReceive do
    def fetch_content(
          prev \\ %{content: "", tool_calls_raw: %{}}
        ) do
      receive do
        {:llm_token, content} ->
          fetch_content(%{prev | content: prev.content <> content})

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

  # TODO: Add files
  # TODO: Add pictures(some model)

  defp build_url(nil, "completions"), do: build_url(@default_root_url, "completions")
  defp build_url(base, "completions"), do: String.trim_trailing(base, "/") <> "/chat/completions"
  # Add responses

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

    final_state = req_result.body

    renamed_final = %{
      content: final_state.content,
      tool_calls: final_state.tool_calls_raw,
      usage: %{
        prompt_tokens: final_state.prompt_tokens,
        completion_tokens: final_state.completion_tokens
      }
    }

    send(caller_pid, {:llm_stream_done, renamed_final})
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

            # (预留) 处理 Tool Calls 拼接逻辑
            # acc = if tool_calls = delta["tool_calls"] do ... else acc end
            # 或者换种方式？把 acc 的内容往外泄

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
end
