defmodule Eris.Tool do
  # 最好的方式还是将 Tool 作为模块列表传入而不是 Registry
  # 为了确保动态构建（不会有很多无关的 Tools 传进来）
  @type t :: %__MODULE__{
          name: binary() | module(),
          description: String.t(),
          parameters: map()
        }
  defstruct [:name, :description, :parameters]

  defmodule Context do
    @moduledoc """
    在工具之间显式传递的上下文。
    """
    @type t :: %__MODULE__{
            cwd: String.t() | nil,
            changed_files: MapSet.t(String.t()),
            llm_conf: Eris.LLM.Config.t() | nil,
            tools: [module()] | nil
          }

    defstruct cwd: nil,
              changed_files: MapSet.new(),
              llm_conf: nil,
              tools: nil

    def resolve_path(%__MODULE__{cwd: cwd}, file_path) do
      expanded = Path.expand(file_path)

      if Path.type(expanded) == :absolute do
        expanded
      else
        Path.join(cwd || File.cwd!(), file_path) |> Path.expand()
      end
    end

    def new(opts \\ []) do
      %__MODULE__{
        cwd: Keyword.get(opts, :cwd, File.cwd!()),
        changed_files: MapSet.new(),
        llm_conf: Keyword.get(opts, :llm_conf),
        tools: Keyword.get(opts, :tools)
      }
    end
  end

  @type args :: map()
  @type ctx :: Eris.Tool.Context.t()
  @type result :: {String.t(), ctx()}

  @callback schema() :: t()

  @callback execute(args(), ctx()) :: result()

  def function_calling(tool) do
    schema = tool.schema()

    %{
      "type" => "function",
      "function" => %{
        "name" => schema.name,
        "description" => schema.description,
        "parameters" => schema.parameters
      }
    }
  end
end
