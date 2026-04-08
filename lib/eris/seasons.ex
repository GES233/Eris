defmodule Eris.Seasons do
  # 避免与 Elixir 的 Agent 冲突
  # 就是四季（循环）没有四的意思
  @behaviour :gen_statem

  defmodule State do
    defstruct [:llm, :tools, :messages, :sub_agent?]
  end

  @impl true
  def callback_mode, do: [:state_functions, :state_enter]

  @impl true
  def init(options) do
    llm_conf = Keyword.fetch!(options, :llm_conf)
    {:ok, :idle, %State{llm: llm_conf}}
  end

  def idle({:call, from}, :get_state, data) do
    {:keep_state_and_data, [{:reply, from, {:idle, data.messages}}]}
  end

  # 主要 cope 几个角度的来源
  # 来自用户
  # 来自模型
  # 来自系统
  # 来自外部工具

  # 如果说要实现类似于 Claude Code 的上下文压缩
  # 可能需要改用 :gen_statem
end
