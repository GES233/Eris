defmodule Eris.Tools.WriteFile do
  @behaviour Eris.Tool

  @impl true
  def schema,
    do: %Eris.Tool{
      name: "write_file",
      description:
        "Create a new file or completely overwrite an existing one. " <>
          "For small edits to existing files, prefer edit_file instead.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{"type" => "string", "description" => "Path for the file"},
          "content" => %{"type" => "string", "description" => "Full file content to write"}
        },
        "required" => ["file_path", "content"]
      }
    }

  @impl true
  def execute(args, ctx) do
    file_path = args["file_path"]
    content = args["content"]
    path = Eris.Tool.Context.resolve_path(ctx, file_path)

    result =
      case File.mkdir_p(Path.dirname(path)) do
        :ok ->
          case File.write(path, content) do
            :ok ->
              n_lines = content |> String.split("\n") |> length()
              "Wrote #{n_lines} lines to #{file_path}"

            {:error, reason} ->
              "Error writing #{file_path}: #{inspect(reason)}"
          end

        {:error, reason} ->
          "Error creating directory: #{inspect(reason)}"
      end

    new_ctx = %{ctx | changed_files: MapSet.put(ctx.changed_files, path)}
    {result, new_ctx}
  end
end
