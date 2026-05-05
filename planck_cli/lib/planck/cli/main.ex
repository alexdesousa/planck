defmodule Planck.CLI.Main do
  @moduledoc false

  # Entry point for the compiled binary. Parses top-level argv and dispatches
  # to the appropriate mode. Returns an integer exit code — the caller
  # (Planck.CLI.start/2) is responsible for calling System.halt/1.

  @version Mix.Project.config()[:version]

  @help """
  planck — AI coding agent

  USAGE
    planck [OPTIONS]

  OPTIONS
    --web, web   Start the web server (Web UI + HTTP API at http://localhost:4000)
                 This is also the default when no option is given.
    --version    Print version and exit
    --help, -h   Print this help and exit

  EXAMPLES
    planck           # start the web server (default)
    planck web       # start the web server
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

      :web ->
        start_web()

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

  @spec parse([String.t()]) :: :help | :version | :web | :unknown
  defp parse([]), do: :web
  defp parse(["--help" | _]), do: :help
  defp parse(["-h" | _]), do: :help
  defp parse(["--version" | _]), do: :version
  defp parse(["--web" | _]), do: :web
  defp parse(["web" | _]), do: :web
  defp parse(_), do: :unknown
end
