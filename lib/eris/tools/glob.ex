defmodule Eris.Tools.Glob do
  @behaviour Eris.Tool

  @impl true
  def schema,
    do: %Eris.Tool{
      name: "glob",
      description: "Find files matching a glob pattern. Supports ** for recursive matching.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{"type" => "string", "description" => "Glob pattern, e.g. '**/*.py'"},
          "path" => %{
            "type" => "string",
            "description" => "Directory to search in (default: cwd)"
          }
        },
        "required" => ["pattern"]
      }
    }

  @impl true
  def execute(args, ctx) do
    pattern = args["pattern"]
    path = Map.get(args, "path", ".")
    base = Eris.Tool.Context.resolve_path(ctx, path)

    result =
      if File.dir?(base) do
        hits =
          Path.wildcard(Path.join(base, pattern))
          |> Enum.filter(&File.regular?/1)
          |> Enum.sort_by(&File.stat!(&1).mtime, :desc)
          |> Enum.take(100)

        case hits do
          [] -> "No files matched."
          _ -> Enum.join(hits, "\n")
        end
      else
        "Error: #{path} is not a directory"
      end

    {result, ctx}
  end
end
