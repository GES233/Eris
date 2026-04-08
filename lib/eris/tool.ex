defmodule Eris.Tool do
  # 可以把 ToolRegistry 搞到 Application 上
  defstruct [:name, :description]

  @callback call(input :: term(), ctx :: term()) :: term()
end
