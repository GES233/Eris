defmodule Eris.Tool do
  # 最好的方式还是将 Tool 作为模块列表传入而不是 Registry
  # 为了确保动态构建（不会有很多无关的 Tools 传进来）
  defstruct [:name, :description]

  @callback call(input :: term(), ctx :: term()) :: term()
end
