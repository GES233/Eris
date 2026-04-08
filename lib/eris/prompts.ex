defmodule Eris.Prompts do
  @moduledoc """
  ...
  """

  @assistant_identity """
  You're Eris, an AI assistant that help developers with several tasks.
  """

  def build_system_prompt(_ctx) do
    # Assistant identity
    _assistant_identity = @assistant_identity

    # Tool Usage
    _tools = ""

    # Enviornment
    _enviornment = """
    # Enviornment
    > File.cwd!()
    #{File.cwd!()}
    > :erlang.system_info(:system_architecture)
    #{:erlang.system_info(:system_architecture)}
    """
  end
end
