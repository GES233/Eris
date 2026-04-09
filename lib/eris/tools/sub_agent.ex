defmodule Eris.Tools.SubAgent do
  @behaviour Eris.Tool

  @impl true
  def schema,
    do: %Eris.Tool{
      name: "agent",
      description:
        "Spawn a sub-agent to handle a complex sub-task independently. " <>
          "The sub-agent has its own context and tool access.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "task" => %{"type" => "string", "description" => "What the sub-agent should accomplish"}
        },
        "required" => ["task"]
      }
    }

  @impl true
  def execute(%{"task" => task}, ctx) do
    if ctx.llm_conf == nil do
      {"Error: sub-agent requires llm_conf in context", ctx}
    else
      # 子 Agent 可用的工具：去掉 agent tool 防止递归
      available_tools = Enum.reject(ctx.tools || [], &(&1 == __MODULE__))

      result =
        Task.async(fn ->
          Eris.AgentLoop.run(task, ctx.llm_conf, available_tools,
            max_rounds: 20,
            max_context_tokens: ctx.llm_conf.max_context_tokens
          )
        end)
        |> Task.await(180_000)

      truncated = truncate_result(result, 5000)
      {"[Sub-agent completed]\n#{truncated}", ctx}
    end
  end

  defp truncate_result(text, max) do
    if byte_size(text) > max do
      String.slice(text, 0, max - 40) <> "\n... (sub-agent output truncated)"
    else
      text
    end
  end
end
