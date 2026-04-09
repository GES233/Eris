defmodule Eris.Tools.Bash do
  @behaviour Eris.Tool

  @impl true
  def schema do
    %Eris.Tool{
      name: "bash",
      description:
        "Execute a shell command. Returns stdout, stderr, and exit code. " <>
          "Use this for running tests, installing packages, git operations, etc.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "command" => %{"type" => "string", "description" => "The shell command to run"},
          "timeout" => %{"type" => "integer", "description" => "Timeout in seconds (default 120)"}
        },
        "required" => ["command"]
      }
    }
  end

  # ── 危险命令检测 ──

  @dangerous_patterns [
    {~r/\brm\s+(-\w*)?-r\w*\s+(\/|~|\$HOME)/, "recursive delete on home/root"},
    {~r/\brm\s+(-\w*)?-rf\s/, "force recursive delete"},
    {~r/\bmkfs\b/, "format filesystem"},
    {~r/\bdd\s+.*of=\/dev\//, "raw disk write"},
    {~r/>\s*\/dev\/sd[a-z]/, "overwrite block device"},
    {~r/\bchmod\s+(-R\s+)?777\s+\//, "chmod 777 on root"},
    {~r/:\(\)\s*\{.*:\|:.*\}/, "fork bomb"},
    {~r/\bcurl\b.*\|\s*(sudo\s+)?bash/, "pipe curl to bash"},
    {~r/\bwget\b.*\|\s*(sudo\s+)?bash/, "pipe wget to bash"}
  ]

  @impl true
  def execute(args, ctx) do
    command = args["command"]
    timeout_sec = Map.get(args, "timeout", 120)

    # 检查 Shell 是否可用
    case get_shell() do
      {:error, reason} ->
        {"❌ Bash tool is not available on this system: #{reason}\n" <>
         "Please ensure you have a compatible shell installed:\n" <>
         "  - Linux/macOS: bash or sh\n" <>
         "  - Windows: Git Bash (install from https://git-scm.com)", ctx}

      shell_info ->
        case check_dangerous(command) do
          {:dangerous, reason} ->
            {"⚠️ Blocked: #{reason}\nCommand: #{command}\nIf intentional, modify the command to be more specific.", ctx}

          :safe ->
            cwd = ctx.cwd || File.cwd!()

            case run_shell(command, cwd, timeout_sec, shell_info) do
              {:ok, output, 0} ->
                new_cwd = maybe_update_cwd(command, cwd)
                new_ctx = %{ctx | cwd: new_cwd}
                {format_output(output), new_ctx}

              {:ok, output, exit_code} ->
                formatted = format_output(output) <> "\n[exit code: #{exit_code}]"
                {formatted, ctx}

              {:timeout, seconds} ->
                {"Error: timed out after #{seconds}s", ctx}

              {:exit, reason} ->
                {"Error running command: #{inspect(reason)}", ctx}
            end
        end
    end
  end

  # ── Shell 检测 ──

  @doc """
  检测当前系统可用的 Shell。
  返回 {:ok, shell_info} 或 {:error, reason}
  """
  def get_shell() do
    case :os.type() do
      {:unix, _} ->
        # Linux/macOS
        {:ok, %{type: :unix, command: "bash", fallback: "sh"}}

      {:win32, _} ->
        # Windows
        case detect_git_bash() do
          {:ok, path} ->
            {:ok, %{type: :windows, command: path, fallback: nil}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # 检测 Windows 上是否安装了 Git Bash。
  defp detect_git_bash() do
    # 常见 Git Bash 安装位置
    git_bash_paths = [
      "C:\\Program Files\\Git\\bin\\bash.exe",
      "C:\\Program Files (x86)\\Git\\bin\\bash.exe",
      "#{System.user_home()}/bin/bash.exe",
      "#{System.user_home()}/Git/bin/bash.exe"
    ]

    # 检查 PATH 中是否有 bash
    path_env = System.get_env("PATH") || ""
    bash_in_path =
      path_env
      |> String.split(";")
      |> Enum.any?(&String.contains?(&1, "Git") && String.contains?(&1, "bin"))

    if bash_in_path do
      {:ok, "bash"}
    else
      # 尝试常见路径
      Enum.find(git_bash_paths, fn path ->
        File.exists?(path)
      end)
      |> case do
        nil ->
          {:error, "Git Bash not found. Please install Git for Windows from https://git-scm.com"}

        path ->
          {:ok, path}
      end
    end
  end

  # ── Shell 执行 ──

  defp run_shell(command, cwd, timeout_sec, shell_info) do
    task =
      Task.async(fn ->
        case shell_info.type do
          :unix ->
            # Linux/macOS: 优先使用 bash，回退到 sh
            shell = shell_info.command
            System.cmd(shell, ["-c", command],
              cd: cwd,
              stderr_to_stdout: true,
              parallelism: true
            )

          :windows ->
            # Windows: 使用 Git Bash
            # 需要转义命令中的引号
            escaped_command = escape_windows_command(command)
            System.cmd(shell_info.command, ["-c", escaped_command],
              cd: cwd,
              stderr_to_stdout: true,
              parallelism: true
            )
        end
      end)

    case Task.yield(task, timeout_sec * 1000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, exit_code}} ->
        {:ok, output, exit_code}

      nil ->
        {:timeout, timeout_sec}

      err -> err
    end
  end

  # 转义 Windows Git Bash 命令中的特殊字符。
  defp escape_windows_command(command) do
    # Git Bash 需要转义双引号
    String.replace(command, "\"", "\\\"")
  end

  # ── 输出格式化 ──

  defp format_output(output) do
    trimmed = String.trim(output)
    if trimmed == "", do: "(no output)", else: truncate_output(trimmed)
  end

  defp truncate_output(output) do
    if byte_size(output) > 15_000 do
      head = String.slice(output, 0, 6000)
      tail = String.slice(output, -3000, 3000)
      "#{head}\n\n... truncated (#{byte_size(output)} chars total) ...\n\n#{tail}"
    else
      output
    end
  end

  # ── 危险命令检测 ──

  defp check_dangerous(command) do
    Enum.find_value(@dangerous_patterns, :safe, fn {pattern, reason} ->
      if Regex.match?(pattern, command), do: {:dangerous, reason}
    end)
  end

  # ── cd 追踪 ──

  defp maybe_update_cwd(command, current_cwd) do
    # 在 && 链中找最后的 cd 命令
    parts = String.split(command, "&&")

    Enum.reduce(parts, current_cwd, fn part, cwd ->
      part = String.trim(part)

      if String.starts_with?(part, "cd ") do
        target = part |> String.slice(3..-1//1) |> String.trim() |> String.trim("\"'")

        if target != "" do
          new_dir =
            Path.join(cwd, String.replace(target, "~", System.user_home() || ""))
            |> Path.expand()

          if File.dir?(new_dir), do: new_dir, else: cwd
        else
          cwd
        end
      else
        cwd
      end
    end)
  end
end
