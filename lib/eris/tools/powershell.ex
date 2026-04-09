defmodule Eris.Tools.PowerShell do
  @behaviour Eris.Tool

  @impl true
  def schema do
    %Eris.Tool{
      name: "powershell",
      description:
        "Execute a PowerShell command. Returns stdout, stderr, and exit code. " <>
          "Use this for running tests, installing packages, git operations, etc. " <>
          "This tool is specifically for Windows PowerShell commands.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "command" => %{"type" => "string", "description" => "The PowerShell command to run"},
          "timeout" => %{"type" => "integer", "description" => "Timeout in seconds (default 120)"}
        },
        "required" => ["command"]
      }
    }
  end

  # ── 危险命令检测 ──

  @dangerous_patterns [
    {~r/\bRemove-Item\s+-Recurse\s+-Force\s+(\/|~|\$HOME|\$PROFILE)/, "recursive delete on home/root"},
    {~r/\bRemove-Item\s+-Recurse\s+-Force\s+/, "force recursive delete"},
    {~r/\bFormat-Volume\b/, "format filesystem"},
    {~r/\bSet-Disk\b.*-Number\s+\d+\s+-IsOffline/, "modify disk"},
    {~r/>\s*C:\\\\Windows\\\\System32\\\\config\\\\SYSTEM/, "overwrite system config"},
    {~r/\bSet-ItemPermission\b.*-Value\s+FullControl\s+\\/, "chmod 777 equivalent"},
    {~r/\bInvoke-Expression\b.*\|\s*Invoke-Expression/, "pipe to Invoke-Expression"},
    {~r/\bInvoke-WebRequest\b.*\|\s*Invoke-Expression/, "pipe Invoke-WebRequest to Invoke-Expression"},
    {~r/\bInvoke-RestMethod\b.*\|\s*Invoke-Expression/, "pipe Invoke-RestMethod to Invoke-Expression"}
  ]

  @impl true
  def execute(args, ctx) do
    command = args["command"]
    timeout_sec = Map.get(args, "timeout", 120)

    # 检查 PowerShell 是否可用
    case get_powershell() do
      {:error, reason} ->
        {"❌ PowerShell tool is not available on this system: #{reason}\n" <>
         "Please ensure you have PowerShell installed:\n" <>
         "  - Windows: PowerShell 5.1 or PowerShell 7+\n" <>
         "  - macOS/Linux: Install from https://github.com/PowerShell/PowerShell", ctx}

      {:ok, ps_info} ->
        case check_dangerous(command) do
          {:dangerous, reason} ->
            {"⚠️ Blocked: #{reason}\nCommand: #{command}\nIf intentional, modify the command to be more specific.", ctx}

          :safe ->
            cwd = ctx.cwd || File.cwd!()

            case run_powershell(command, cwd, timeout_sec, ps_info) do
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

  # ── PowerShell 检测 ──

  @doc """
  检测当前系统可用的 PowerShell。
  返回 {:ok, ps_info} 或 {:error, reason}
  """
  def get_powershell() do
    case :os.type() do
      {:win32, _} ->
        # Windows: 优先使用 PowerShell 7+, 回退到 PowerShell 5.1
        case detect_powershell_7() do
          {:ok, path} ->
            {:ok, %{type: :windows, command: path, version: :pwsh}}

          {:error, _} ->
            case detect_powershell_5() do
              {:ok, path} ->
                {:ok, %{type: :windows, command: path, version: :ps5}}

              {:error, reason} ->
                {:error, reason}
            end
        end

      {:unix, _} ->
        # Linux/macOS: 尝试安装 PowerShell
        case detect_powershell_unix() do
          {:ok, path} ->
            {:ok, %{type: :unix, command: path, version: :pwsh}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # 检测 Windows PowerShell 7+ (pwsh.exe)
  defp detect_powershell_7() do
    pwsh_paths = [
      "C:\\Program Files\\PowerShell\\7\\pwsh.exe",
      "C:\\Program Files\\PowerShell\\7\\Preview\\pwsh.exe",
      "#{System.user_home()}/pwsh.exe",
      "#{System.user_home()}/scoop/apps/pwsh/current/pwsh.exe",
      "#{System.user_home()}/scoop/apps/pwsh-preview/current/pwsh.exe"
    ]

    # 检查 PATH 中是否有 pwsh
    path_env = System.get_env("PATH") || ""
    pwsh_in_path =
      path_env
      |> String.split(";")
      |> Enum.any?(&String.contains?(&1, "PowerShell") && String.contains?(&1, "pwsh"))

    if pwsh_in_path do
      {:ok, "pwsh"}
    else
      # 尝试常见路径
      Enum.find(pwsh_paths, fn path ->
        File.exists?(path)
      end)
      |> case do
        nil ->
          {:error, "PowerShell 7+ (pwsh) not found. Please install from https://aka.ms/powershell"}

        path ->
          {:ok, path}
      end
    end
  end

  # 检测 Windows PowerShell 5.1 (powershell.exe)
  defp detect_powershell_5() do
    # PowerShell 5.1 通常在 System32 中
    ps5_path = "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"

    if File.exists?(ps5_path) do
      {:ok, ps5_path}
    else
      # 检查 PATH 中是否有 powershell
      path_env = System.get_env("PATH") || ""
      ps5_in_path =
        path_env
        |> String.split(";")
        |> Enum.any?(&String.contains?(&1, "WindowsPowerShell"))

      if ps5_in_path do
        {:ok, "powershell"}
      else
        {:error, "PowerShell 5.1 not found. Please enable Windows Features > Windows PowerShell 2.0"}
      end
    end
  end

  # 检测 Unix 系统上的 PowerShell
  defp detect_powershell_unix() do
    # 检查常见安装位置
    pwsh_paths = [
      "/usr/bin/pwsh",
      "/usr/local/bin/pwsh",
      "#{System.user_home()}/.dotnet/tools/pwsh",
      "#{System.user_home()}/.local/bin/pwsh"
    ]

    # 检查 PATH 中是否有 pwsh
    path_env = System.get_env("PATH") || ""
    pwsh_in_path =
      path_env
      |> String.split(":")
      |> Enum.any?(&String.contains?(&1, "pwsh"))

    if pwsh_in_path do
      {:ok, "pwsh"}
    else
      # 尝试常见路径
      Enum.find(pwsh_paths, fn path ->
        File.exists?(path)
      end)
      |> case do
        nil ->
          {:error, "PowerShell not found. Please install from https://aka.ms/powershell"}

        path ->
          {:ok, path}
      end
    end
  end

  # ── PowerShell 执行 ──

  defp run_powershell(command, cwd, timeout_sec, ps_info) do
    task =
      Task.async(fn ->
        case ps_info.version do
          :pwsh ->
            # PowerShell 7+
            System.cmd(ps_info.command, ["-NoProfile", "-NonInteractive", "-Command", command],
              cd: cwd,
              stderr_to_stdout: true,
              parallelism: true
            )

          :ps5 ->
            # PowerShell 5.1
            # 使用 -ExecutionPolicy Bypass 避免执行策略限制
            System.cmd(ps_info.command, ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", command],
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
    # 在 ; 链中找最后的 Set-Location 命令
    parts = String.split(command, ";")

    Enum.reduce(parts, current_cwd, fn part, cwd ->
      part = String.trim(part)

      # 支持 Set-Location 和 cd 别名
      if String.starts_with?(part, "Set-Location ") or String.starts_with?(part, "cd ") do
        target =
          part
          |> String.replace_prefix("Set-Location ", "")
          |> String.replace_prefix("cd ", "")
          |> String.trim()
          |> String.trim("\"'")

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
