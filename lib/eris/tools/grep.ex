defmodule Eris.Tools.Grep do
  @behaviour Eris.Tool

  @skip_dirs MapSet.new(~w(.git node_modules __pycache__ .venv venv .tox dist build _build deps))

  @impl true
  def schema,
    do: %Eris.Tool{
      name: "grep",
      description:
        "Search file contents with regex. Returns matching lines with file path and line number.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{"type" => "string", "description" => "Regex pattern to search for"},
          "path" => %{
            "type" => "string",
            "description" => "File or directory to search (default: cwd)"
          },
          "include" => %{
            "type" => "string",
            "description" => "Only search files matching this glob (e.g. '*.py')"
          }
        },
        "required" => ["pattern"]
      }
    }

  @impl true
  def execute(args, ctx) do
    pattern_str = args["pattern"]
    path = Map.get(args, "path", ".")
    include = Map.get(args, "include")

    case Regex.compile(pattern_str) do
      {:ok, regex} ->
        base = Eris.Tool.Context.resolve_path(ctx, path)

        result =
          cond do
            not File.exists?(base) ->
              "Error: #{path} not found"

            File.regular?(base) ->
              search_file(base, regex)

            File.dir?(base) ->
              base
              |> walk(include)
              |> Enum.flat_map(&search_file(&1, regex))
              |> Enum.take(200)
              |> case do
                [] -> "No matches found."
                matches -> Enum.join(matches, "\n")
              end
          end

        {result, ctx}

      {:error, reason} ->
        {"Invalid regex: #{inspect(reason)}", ctx}
    end
  end

  defp search_file(path, regex) do
    case File.read(path) do
      {:ok, text} ->
        text
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} -> Regex.match?(regex, line) end)
        |> Enum.map(fn {line, lineno} -> "#{path}:#{lineno}: #{String.trim_trailing(line)}" end)

      {:error, _} ->
        []
    end
  end

  defp walk(root, include) do
    glob_pattern = if include, do: include, else: "**/*"

    Path.wildcard(Path.join(root, glob_pattern))
    |> Enum.filter(fn p ->
      File.regular?(p) and not Enum.any?(Path.split(p), &MapSet.member?(@skip_dirs, &1))
    end)
    |> Enum.take(5000)
  end
end
