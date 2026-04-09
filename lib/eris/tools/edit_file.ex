defmodule Eris.Tools.EditFile do
  @behaviour Eris.Tool

  @impl true
  def schema,
    do: %Eris.Tool{
      name: "edit_file",
      description:
        "Edit a file by replacing an exact string match. " <>
          "old_string must appear exactly once in the file for safety. " <>
          "Include enough surrounding context to ensure uniqueness.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{"type" => "string", "description" => "Path to the file to edit"},
          "old_string" => %{
            "type" => "string",
            "description" => "Exact text to find (must be unique)"
          },
          "new_string" => %{"type" => "string", "description" => "Replacement text"}
        },
        "required" => ["file_path", "old_string", "new_string"]
      }
    }

  @impl true
  def execute(args, ctx) do
    file_path = args["file_path"]
    old_string = args["old_string"]
    new_string = args["new_string"]
    path = Eris.Tool.Context.resolve_path(ctx, file_path)

    result =
      case File.read(path) do
        {:ok, content} ->
          count = count_occurrences(content, old_string)

          cond do
            count == 0 ->
              preview = String.slice(content, 0, 500)
              "Error: old_string not found in #{file_path}.\nFile starts with:\n#{preview}"

            count > 1 ->
              "Error: old_string appears #{count} times in #{file_path}. " <>
                "Include more surrounding lines to make it unique."

            true ->
              new_content = replace_first(content, old_string, new_string)

              case File.write(path, new_content) do
                :ok ->
                  diff = format_diff(content, new_content, file_path)
                  "Edited #{file_path}\n#{diff}"

                {:error, reason} ->
                  "Error writing #{file_path}: #{inspect(reason)}"
              end
          end

        {:error, :enoent} ->
          "Error: #{file_path} not found"

        {:error, reason} ->
          "Error: #{file_path}: #{inspect(reason)}"
      end

    new_ctx = %{ctx | changed_files: MapSet.put(ctx.changed_files, path)}
    {result, new_ctx}
  end

  # 只替换第一个匹配（替代 Python 的 str.replace(s, old, new, 1)）
  # Elixir 的 String.replace 默认全局替换，没有 count 参数
  defp replace_first(content, old, new) do
    case String.split(content, old, parts: 2) do
      [before, after_part] -> before <> new <> after_part
      [_no_match] -> content
    end
  end

  defp count_occurrences(content, old) do
    # 不会正则转义，直接数子串出现次数
    String.split(content, old) |> length() |> Kernel.-(1)
  end

  # 调用系统 diff 生成 unified diff
  # 不引入第三方库，够用就行
  defp format_diff(old_content, new_content, file_path) do
    tmp_old = Path.join(System.tmp_dir!(), "eris_diff_old_#{:erlang.unique_integer([:positive])}")
    tmp_new = Path.join(System.tmp_dir!(), "eris_diff_new_#{:erlang.unique_integer([:positive])}")

    try do
      File.write!(tmp_old, old_content)
      File.write!(tmp_new, new_content)

      case System.cmd(
             "diff",
             ["-u", "-L", "a/#{file_path}", "-L", "b/#{file_path}", tmp_old, tmp_new],
             stderr_to_stdout: true
           ) do
        {output, 0} -> truncate_string(output, 3000)
        # diff exits 1 when there ARE differences
        {output, 1} -> truncate_string(output, 3000)
        {_output, 2} -> "(diff failed)"
      end
    after
      File.rm(tmp_old)
      File.rm(tmp_new)
    end
  end

  defp truncate_string(s, max_len) do
    if byte_size(s) > max_len do
      String.slice(s, 0, max_len) <> "\n... (diff truncated)"
    else
      s
    end
  end
end
