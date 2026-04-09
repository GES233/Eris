defmodule Eris.Tools.ZipElixirProject do
  # 如果需要

  def sqeeze_ex_files_under(root_path, pattern) do
    Path.join(root_path, pattern)
    |> Path.wildcard()
    |> Enum.map(fn
      path ->
        path
        |> File.read!()
    end)
    |> Enum.join("\n")
    |> String.trim()
  end
end
