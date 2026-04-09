defmodule Eris.Prompts do
  @moduledoc """
  实现 Prompt 的动态构建。
  """

  @assistant_identity """
  You're Eris, an AI assistant that help developers with several tasks.
  """

  # 整体秉承着一个原则：不知道就不写
  # 还有一个问题，上下文传什么？
  # opts 包含一个选项：是否保留每个 Session 开始的 Prompt
  def build_system_prompt(_ctx, _opts) do
    # 助手身份
    _assistant_identity = @assistant_identity

    # 关于用户/偏好

    # 工具相关
    _tools = """
    And Here're some tools related to the enviornment, help you.
    """

    # 系统环境
    _enviornment = get_final_enviornment()
  end

  def get_final_enviornment() do
    # 一方面是系统的，另一方面是当前目录的
    # 系统的 => 系统信息，运行时检测
    # 有没有默认的 erlang/elixir 程序/运行时？
    # 有没有 Node.js/Python...
    # 当前目录 => 如果是默认界面那就不处理（节省 Token 加保护隐私）
    # 有没有 Git ？
    """
    ## Enviornment
    > File.cwd!()
    #{File.cwd!()}
    > :erlang.system_info(:system_architecture)
    #{:erlang.system_info(:system_architecture)}
    """
  end
end
