defmodule Planck.CLI.Main do
  @moduledoc false

  # Entry point for the compiled binary. Parses top-level argv, applies any
  # server configuration overrides, then starts the web server.
  # Returns an integer exit code — the caller (Planck.CLI) is responsible
  # for calling System.halt/1.

  alias Planck.CLI.Config.IpAddress

  @version Mix.Project.config()[:version]

  @help """
  planck — AI coding agent

  USAGE
    planck [OPTIONS]

  OPTIONS
    --port N       HTTP port to listen on (default: 4000, env: PORT)
    --ip ADDRESS   IP address to bind to  (default: 127.0.0.1, env: IP_ADDRESS)
                   Use 0.0.0.0 to expose on all interfaces (e.g. Docker)
    --host NAME    Hostname for URL generation (default: localhost, env: HOST)
    --sname NAME   Erlang short node name for distribution (default: planck_cli,
                   env: NODE_SNAME). Required for sidecar connectivity.
    --cookie VALUE Erlang magic cookie (default: planck, env: NODE_COOKIE)
    --version      Print version and exit
    --help, -h     Print this help and exit

  EXAMPLES
    planck                              # start on localhost:4000
    planck --port 8080                  # custom port
    IP_ADDRESS=0.0.0.0 planck           # expose on all interfaces
    planck --sname mynode --cookie s3cr # custom distribution settings
  """

  @spec run([String.t()]) :: non_neg_integer()
  def run(argv) do
    case parse(argv) do
      {:help, _} ->
        IO.write(@help)
        0

      {:version, _} ->
        IO.puts("planck #{@version}")
        0

      {:web, opts} ->
        start_web_with_opts(opts)

      {:unknown, _} ->
        IO.write(:stderr, "Unknown option. Run `planck --help` for usage.\n")
        1
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec start_web_with_opts(keyword()) :: non_neg_integer()
  defp start_web_with_opts(opts) do
    case apply_server_opts(opts) do
      :ok ->
        start_web()

      {:error, reason} ->
        IO.write(:stderr, "#{reason}\n")
        1
    end
  end

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

  @type parse_result :: {:help | :version | :unknown, []} | {:web, keyword()}

  @spec parse([String.t()]) :: parse_result()
  defp parse(argv) do
    {opts, remaining, invalid} =
      OptionParser.parse(argv,
        strict: [
          port: :integer,
          ip: :string,
          host: :string,
          sname: :string,
          cookie: :string,
          help: :boolean,
          version: :boolean
        ],
        aliases: [h: :help]
      )

    cond do
      opts[:help] -> {:help, []}
      opts[:version] -> {:version, []}
      remaining != [] or invalid != [] -> {:unknown, []}
      true -> {:web, opts}
    end
  end

  alias Planck.CLI.Config

  @spec apply_server_opts(keyword()) :: :ok | {:error, String.t()}
  defp apply_server_opts(opts) do
    with :ok <- maybe_set_port(opts[:port]),
         :ok <- maybe_set_ip(opts[:ip]) do
      maybe_set_host(opts[:host])
    end
  end

  @spec maybe_set_port(integer() | nil) :: :ok
  defp maybe_set_port(nil), do: :ok
  defp maybe_set_port(port), do: Config.put_port(port)

  @spec maybe_set_ip(String.t() | nil) :: :ok | {:error, String.t()}
  defp maybe_set_ip(nil), do: :ok

  defp maybe_set_ip(ip_string) do
    case IpAddress.cast(ip_string) do
      {:ok, ip} -> Config.put_ip_address(ip)
      {:error, reason} -> {:error, "Invalid --ip: #{reason}"}
    end
  end

  @spec maybe_set_host(String.t() | nil) :: :ok
  defp maybe_set_host(nil), do: :ok
  defp maybe_set_host(host), do: Config.put_host(host)
end
