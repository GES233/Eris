defmodule Eris.Tools.ZipElixirProject do
  @behaviour Eris.Tool

  @impl true
  def schema,
    do: %Eris.Tool{
      name: "zip_elixir_project",
      description:
        "Zip an Elixir project into a single file, combining README, mix.exs, and all source code.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "root_dir" => %{
            "type" => "string",
            "description" => "Root directory of the Elixir project (default: current working directory)"
          },
          "output_file" => %{
            "type" => "string",
            "description" => "Output file path for the zipped content (default: '_build/project.md')"
          },
          "include_readme" => %{
            "type" => "boolean",
            "description" => "Include README.md content (default: true)",
            "default" => true
          },
          "include_mix_exs" => %{
            "type" => "boolean",
            "description" => "Include mix.exs content (default: true)",
            "default" => true
          },
          "pattern" => %{
            "type" => "string",
            "description" => "File pattern to include from lib/ (default: 'lib/**/*.ex')",
            "default" => "lib/**/*.ex"
          }
        },
        "required" => []
      }
    }

  @impl true
  def execute(args, ctx) do
    root_dir = Map.get(args, "root_dir")
    output_file = Map.get(args, "output_file", "_build/project.md")
    include_readme = Map.get(args, "include_readme", true)
    include_mix_exs = Map.get(args, "include_mix_exs", true)
    pattern = Map.get(args, "pattern", "lib/**/*.ex")

    cwd =
      case root_dir do
        nil -> Eris.Tool.Context.resolve_path(ctx, ".")
        dir -> Eris.Tool.Context.resolve_path(ctx, dir)
      end

    # 仿照 merge_codes_into_one_file.exs 的样式
    apply_pattern = fn pattern ->
      cwd
      |> Path.join(pattern)
      |> Path.wildcard()
      |> Enum.map(fn
        path ->
          path
          |> File.read!()
      end)
      |> Enum.join("\n")
      |> String.trim()
    end

    # 构建内容
    content =
      apply_pattern.(pattern)
      |> then(fn code ->
        readme =
          if include_readme and File.exists?(Path.join(cwd, "README.md")) do
            File.read!(Path.join(cwd, "README.md"))
          else
            ""
          end

        mix_exs =
          if include_mix_exs and File.exists?(Path.join(cwd, "mix.exs")) do
            File.read!(Path.join(cwd, "mix.exs"))
          else
            ""
          end

        """
        #{readme}

        ## Source Code

        ```elixir
        #{mix_exs}

        #{code}
        ```

        """
      end)
      |> then(&String.trim/1)

    # 写入文件
    output_path = Eris.Tool.Context.resolve_path(ctx, output_file)

    case File.write(output_path, content) do
      :ok ->
        {"Successfully wrote project to #{output_path}", ctx}

      {:error, reason} ->
        {"Error writing to #{output_path}: #{inspect(reason)}", ctx}
    end
  end
end
