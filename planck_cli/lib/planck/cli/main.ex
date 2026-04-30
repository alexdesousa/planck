defmodule Planck.CLI.Main do
  @moduledoc false

  # Entry point for the compiled binary. Parses top-level argv and dispatches
  # to the appropriate mode. Returns an integer exit code — the caller
  # (Planck.CLI.start/2) is responsible for calling System.halt/1.
  #
  # Long-running modes (TUI, Web) will start a supervised process tree and
  # block; they return only when the process exits.

  @version Mix.Project.config()[:version]

  @help """
  planck — AI coding agent

  USAGE
    planck [OPTIONS] [PROMPT]

  OPTIONS
    --tui        Start the interactive terminal UI (default when TTY detected)
    --web        Start the web UI (opens browser on http://localhost:4000)
    --sidecar    Start headless mode driven by the sidecar (no TUI or Web UI)
    --version    Print version and exit
    --help, -h   Print this help and exit

  EXAMPLES
    planck                         # interactive TUI
    planck "fix the auth bug"      # send a one-shot prompt (non-interactive)
    planck --web                   # web UI mode
    planck --sidecar               # headless mode for external integrations
  """

  @spec run([String.t()]) :: non_neg_integer()
  def run(argv) do
    case parse(argv) do
      :help ->
        IO.write(@help)
        0

      :version ->
        IO.puts("planck #{@version}")
        0

      :tui ->
        IO.puts("TUI mode coming soon. Use `planck --help` for available options.")
        0

      :web ->
        start_web()

      :sidecar ->
        IO.puts("Sidecar mode coming soon. Use `planck --help` for available options.")
        0

      {:prompt, text} ->
        IO.puts("Non-interactive mode coming soon.")
        IO.puts("Prompt received: #{text}")
        0

      :unknown ->
        IO.write(:stderr, "Unknown option. Run `planck --help` for usage.\n")
        1
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec start_web() :: non_neg_integer()
  defp start_web do
    case Planck.Web.Supervisor.start_link() do
      {:ok, _} ->
        Process.sleep(:infinity)
        0

      {:error, {:already_started, _}} ->
        0
    end
  end

  @spec parse([String.t()]) ::
          :help | :version | :tui | :web | :sidecar | {:prompt, String.t()} | :unknown
  defp parse([]), do: :tui
  defp parse(["--help" | _]), do: :help
  defp parse(["-h" | _]), do: :help
  defp parse(["--version" | _]), do: :version
  defp parse(["--tui" | _]), do: :tui
  defp parse(["tui" | _]), do: :tui
  defp parse(["--web" | _]), do: :web
  defp parse(["web" | _]), do: :web
  defp parse(["--sidecar" | _]), do: :sidecar
  defp parse(["sidecar" | _]), do: :sidecar
  defp parse([<<"-", _::binary>> | _]), do: :unknown
  defp parse([prompt | _]), do: {:prompt, prompt}
end
