defmodule Eris.Tools do
  @moduledoc """
  工具注册表。

  编译期确定工具列表，运行时按名查找。
  """

  @tools [
    Eris.Tools.ReadFile,
    Eris.Tools.EditFile,
    Eris.Tools.WriteFile,
    Eris.Tools.SubAgent,
    Eris.Tools.Glob,
    Eris.Tools.Grep,
    Eris.Tools.ZipElixirProject,
    Eris.Tools.Bash,
    Eris.Tools.PowerShell,
    Eris.Tools.FetchUrl
  ]

  def all, do: @tools

  @doc "生成所有工具的 OpenAI schema（用于 LLM 请求）"
  def schemas do
    Enum.map(@tools, &Eris.Tool.function_calling/1)
  end

  @doc "按名查找工具模块"
  def get(name) do
    Enum.find(@tools, &(&1.schema().name == name))
  end

  @doc "执行工具，处理未知工具和异常"
  def execute(name, args, ctx) do
    case get(name) do
      nil ->
        {"Error: unknown tool '#{name}'", ctx}

      tool ->
        try do
          tool.execute(args, ctx)
        rescue
          e ->
            {"Error executing #{name}: #{Exception.message(e)}", ctx}
        end
    end
  end
end
