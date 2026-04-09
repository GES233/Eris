defmodule Eris.Entry do
  @moduledoc """
  Eris 的 TUI 入口。

  布局：
  ┌─────────────────────────────────┐
  │  Eris  [状态]                   │  ← 标题栏 (1行)
  ├─────────────────────────────────┤
  │                                 │
  │  对话历史（Markdown 渲染）       │  ← 消息区（弹性）
  │                                 │
  ├─────────────────────────────────┤
  │  > 输入框                       │  ← 输入区 (3行)
  └─────────────────────────────────┘

  与 Eris.Seasons (gen_statem) 集成：
  - mount 时启动 Seasons，订阅流式事件
  - handle_info 接收 {:seasons_token, text} 等消息，更新 UI
  - 用户按 Enter 发送消息

  启动方式：
  - mix run --no-halt          （或直接 mix run，terminate/2 会调用 System.stop/0）
  - iex -S mix                 （手动调用 Eris.Entry.start_link/1，传 name: nil 避免注册冲突）
  """

  use ExRatatui.App

  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.{Block, Markdown, Paragraph, TextInput}

  # ── 状态结构 ──────────────────────────────────────

  defmodule AppState do
    defstruct [
      # Seasons gen_statem 的 PID
      :seasons_pid,
      # TextInput 的 Rust 状态引用
      :input_ref,
      # 对话历史，每条是 %{role: :user | :assistant, content: String.t()}
      messages: [],
      # 当前正在流式输出的 assistant 文本
      streaming_text: "",
      # 当前 UI 状态
      ui_state: :idle,
      # 消息区滚动偏移
      scroll: 0,
      # Throbber 动画步骤
      throbber_step: 0,
      # 当前正在执行的工具名
      current_tool: nil
    ]
  end

  # ── ExRatatui.App 回调 ────────────────────────────

  @impl true
  def mount(opts) do
    llm_conf = Keyword.fetch!(opts, :llm_conf)
    tools = Keyword.get(opts, :tools, Eris.Tools.all())

    # 启动 Seasons gen_statem
    {:ok, seasons_pid} =
      :gen_statem.start_link(Eris.Seasons,
        [llm_conf: llm_conf, tools: tools, subscriber: self()],
        []
      )

    input_ref = ExRatatui.text_input_new()

    state = %AppState{
      seasons_pid: seasons_pid,
      input_ref: input_ref
    }

    {:ok, state}
  end

  @impl true
  def render(state, frame) do
    full = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}

    # 垂直分割：标题(1) + 消息区(弹性) + 输入区(3)
    [title_rect, msg_rect, input_rect] =
      Layout.split(full, :vertical, [
        {:length, 1},
        {:min, 0},
        {:length, 3}
      ])

    title_widget = render_title(state, frame.width)
    msg_widget = render_messages(state, msg_rect)
    input_widget = render_input(state)

    [
      {title_widget, title_rect},
      {msg_widget, msg_rect},
      {input_widget, input_rect}
    ]
  end

  @impl true
  def handle_event(%ExRatatui.Event.Key{code: "enter"}, state) do
    do_enter(state)
  end

  def handle_event(%ExRatatui.Event.Key{code: "\r"}, state) do
    do_enter(state)
  end

  def handle_event(%ExRatatui.Event.Key{code: "\n"}, state) do
    do_enter(state)
  end

  # Ctrl+C 退出
  def handle_event(%ExRatatui.Event.Key{code: "c", modifiers: ["ctrl" | _]}, state) do
    {:stop, state}
  end

  # Page Up / Page Down 滚动
  def handle_event(%ExRatatui.Event.Key{code: "page_up"}, state) do
    {:noreply, %{state | scroll: max(0, state.scroll - 5)}}
  end

  def handle_event(%ExRatatui.Event.Key{code: "page_down"}, state) do
    {:noreply, %{state | scroll: state.scroll + 5}}
  end

  def handle_event(%ExRatatui.Event.Key{code: "backspace"}, state) do
    ExRatatui.text_input_handle_key(state.input_ref, "backspace")
    {:noreply, state}
  end

  def handle_event(%ExRatatui.Event.Key{code: <<127>>}, state) do
    ExRatatui.text_input_handle_key(state.input_ref, "backspace")
    {:noreply, state}
  end

  def handle_event(%ExRatatui.Event.Key{code: "\b"}, state) do
    ExRatatui.text_input_handle_key(state.input_ref, "backspace")
    {:noreply, state}
  end

  # 其他按键转发给 TextInput
  def handle_event(%ExRatatui.Event.Key{code: code}, state) do
    ExRatatui.text_input_handle_key(state.input_ref, code)
    {:noreply, state}
  end

  def handle_event(_event, state) do
    {:noreply, state}
  end

  # ── terminate/2：TUI 退出时停止 VM（mix run 场景） ──
  #
  # 在 IEx 下运行时，System.stop/0 会关闭整个 IEx session，
  # 如果不希望这样，可在 IEx 里手动调用 Eris.Entry.start_link/1
  # 并在退出后自行处理。
  @impl true
  def terminate(_reason, _state) do
    # 仅在非 IEx 环境下自动停止 VM
    unless iex_running?() do
      System.stop(0)
    end

    :ok
  end

  # ── handle_info ────────────────────────────────────

  @impl true
  def handle_info({:seasons_token, text}, state) do
    new_streaming = state.streaming_text <> text
    {:noreply, %{state | streaming_text: new_streaming, ui_state: :generating}}
  end

  def handle_info({:seasons_reasoning, _delta}, state) do
    # 推理 token 暂时忽略（不显示在 UI 上）
    {:noreply, state}
  end

  def handle_info({:seasons_done, final_text}, state) do
    # 流式输出完成，把 streaming_text 固化为一条 assistant 消息
    content = if final_text != "", do: final_text, else: state.streaming_text

    assistant_msg = %{role: :assistant, content: content}
    new_messages = state.messages ++ [assistant_msg]

    {:noreply,
     %{state | messages: new_messages, streaming_text: "", ui_state: :idle, current_tool: nil}}
  end

  def handle_info({:seasons_state, :idle}, state) do
    {:noreply, %{state | ui_state: :idle}}
  end

  def handle_info({:seasons_state, :thinking}, state) do
    {:noreply, %{state | ui_state: :thinking}}
  end

  def handle_info({:seasons_state, :tool_running}, state) do
    {:noreply, %{state | ui_state: :tool_running}}
  end

  def handle_info({:seasons_tool_call, tool_name, _args}, state) do
    {:noreply, %{state | ui_state: :tool_running, current_tool: tool_name}}
  end

  def handle_info({:seasons_tool_result, _tool_name, _result}, state) do
    {:noreply, %{state | ui_state: :thinking, current_tool: nil}}
  end

  # Throbber 动画 tick（由 Process.send_after 驱动）
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, 100)
    {:noreply, %{state | throbber_step: state.throbber_step + 1}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── 渲染辅助函数 ──────────────────────────────────

  defp do_enter(state) do
    text = ExRatatui.text_input_get_value(state.input_ref) |> String.trim()

    if text != "" do
      # 清空输入框
      ExRatatui.text_input_set_value(state.input_ref, "")

      # 把用户消息加入历史
      user_msg = %{role: :user, content: text}
      new_messages = state.messages ++ [user_msg]

      # 发送给 Seasons
      Eris.Seasons.user_input(state.seasons_pid, text)

      new_state = %{
        state
        | messages: new_messages,
          streaming_text: "",
          ui_state: :thinking,
          scroll: 0
      }

      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  defp render_title(state, _width) do
    status_text =
      case state.ui_state do
        :idle -> " [ready]"
        :thinking -> " [thinking...]"
        :generating -> " [generating...]"
        :tool_running ->
          tool = state.current_tool || "tool"
          " [running: #{tool}]"
      end

    %Paragraph{
      text: "Eris" <> status_text,
      style: %Style{fg: :cyan, modifiers: [:bold]}
    }
  end

  defp render_messages(state, _rect) do
    # 把历史消息 + 当前流式文本拼成 Markdown
    history_md =
      state.messages
      |> Enum.map(fn
        %{role: :user, content: text} ->
          "**You:** #{text}"

        %{role: :assistant, content: text} ->
          "**Eris:**\n\n#{text}"
      end)
      |> Enum.join("\n\n---\n\n")

    # 如果正在流式输出，追加当前流式文本
    full_md =
      cond do
        state.streaming_text != "" ->
          streaming_part = "**Eris:**\n\n#{state.streaming_text}▌"

          if history_md != "" do
            history_md <> "\n\n---\n\n" <> streaming_part
          else
            streaming_part
          end

        state.ui_state in [:thinking, :tool_running] and state.streaming_text == "" ->
          thinking_part =
            case state.ui_state do
              :thinking -> "_Thinking..._"
              :tool_running -> "_Running #{state.current_tool || "tool"}..._"
              _ -> ""
            end

          if history_md != "" do
            history_md <> "\n\n---\n\n" <> thinking_part
          else
            thinking_part
          end

        true ->
          if history_md == "" do
            "_Welcome to Eris! Type a message and press Enter to start._"
          else
            history_md
          end
      end

    %Markdown{
      content: full_md,
      block: %Block{
        title: "Chat",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :dark_gray}
      },
      scroll: {state.scroll, 0},
      wrap: true
    }
  end

  defp render_input(state) do
    placeholder =
      case state.ui_state do
        :idle -> "Type a message... (Enter to send, Ctrl+C to quit)"
        _ -> "Waiting for response..."
      end

    %TextInput{
      state: state.input_ref,
      placeholder: placeholder,
      placeholder_style: %Style{fg: :dark_gray},
      block: %Block{
        title: "Input",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :blue}
      },
      cursor_style: %Style{modifiers: [:reversed]}
    }
  end

  # ── 私有辅助 ──────────────────────────────────────

  # 检测是否在 IEx 交互式 shell 中运行
  defp iex_running? do
    Code.ensure_loaded?(IEx) and IEx.started?()
  end
end
