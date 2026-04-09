defmodule Eris.Tools.ReadFile do
  @behaviour Eris.Tool

  @impl true
  def schema,
    do: %Eris.Tool{
      name: "read_file",
      description:
        "Read a file's contents with line numbers. Always read a file before editing it.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{"type" => "string", "description" => "Path to the file"},
          "offset" => %{"type" => "integer", "description" => "Start line (1-based). Default 1."},
          "limit" => %{"type" => "integer", "description" => "Max lines to read. Default 2000."}
        },
        "required" => ["file_path"]
      }
    }

  @impl true
  def execute(args, ctx) do
    file_path = args["file_path"]
    offset = Map.get(args, "offset", 1)
    limit = Map.get(args, "limit", 2000)
    path = Eris.Tool.Context.resolve_path(ctx, file_path)

    result =
      case File.read(path) do
        {:ok, text} ->
          lines = String.split(text, "\n")
          total = length(lines)
          start_idx = max(0, offset - 1)
          chunk = Enum.slice(lines, start_idx, limit)

          numbered =
            chunk
            |> Enum.with_index(start_idx + 1)
            |> Enum.map(fn {ln, i} -> "#{i}\t#{ln}" end)
            |> Enum.join("\n")

          if total > start_idx + limit do
            "#{numbered}\n... (#{total} lines total, showing #{start_idx + 1}-#{start_idx + length(chunk)})"
          else
            if numbered == "", do: "(empty file)", else: numbered
          end

        {:error, :enoent} ->
          "Error: #{file_path} not found"

        {:error, reason} ->
          "Error: #{file_path}: #{inspect(reason)}"
      end

    {result, ctx}
  end
end
