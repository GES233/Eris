defmodule Eris.Entry do
  use ExRatatui.App

  @impl true
  def mount(_opts) do
    # 先 spawn 一个主 Agent 出来
    # 根据系统上下文构建 Prompt
    # 等待回应
    search_input = ExRatatui.text_input_new()

    {:ok, %{count: 0, search_input: search_input}}
  end

  @impl true
  def render(state, frame) do
    alias ExRatatui.Widgets.Paragraph
    alias ExRatatui.Layout.Rect

    widget = %Paragraph{text: "Count: #{state.count}"}
    rect = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}
    [{widget, rect}]
  end

  @impl true
  def handle_event(%ExRatatui.Event.Key{code: "q"}, state) do
    {:stop, state}
  end

  def handle_event(%ExRatatui.Event.Key{code: "up"}, state) do
    {:noreply, %{state | count: state.count + 1}}
  end

  def handle_event(_event, state) do
    {:noreply, state}
  end
end
