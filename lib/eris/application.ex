defmodule Eris.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      case build_llm_conf() do
        {:ok, llm_conf} ->
          [
            {Eris.Entry,
             [
               llm_conf: llm_conf,
               # 禁用全局注册名，避免 IEx 下重复启动冲突
               name: nil
             ]}
          ]

        {:error, reason} ->
          require Logger
          Logger.warning("[Eris] 未配置 LLM，跳过 TUI 启动：#{reason}")
          []
      end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Eris.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # 从环境变量读取 LLM 配置
  # 必须设置：ERIS_API_KEY
  # 可选：ERIS_ROOT_URL（默认 OpenRouter）、ERIS_MODEL（默认 claude-sonnet-4-5）
  defp build_llm_conf do
    case System.get_env("ERIS_API_KEY") do
      nil ->
        {:error, "未设置 ERIS_API_KEY 环境变量"}

      api_key ->
        llm_conf = %Eris.LLM.Config{
          root_url: System.get_env("ERIS_ROOT_URL"),
          model: System.get_env("ERIS_MODEL", "anthropic/claude-sonnet-4-5"),
          api_key: api_key
        }

        {:ok, llm_conf}
    end
  end
end
