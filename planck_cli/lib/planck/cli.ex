defmodule Planck.CLI do
  @moduledoc false

  use Application

  require Logger

  alias Planck.CLI.Config

  @impl true
  def start(_type, _args) do
    # Apply any --sname / --cookie argv overrides before preload so Skogsra
    # picks them up at the `:config` source level.
    apply_distribution_argv()

    Config.preload()
    Config.validate!()

    start_distribution(Config.sname!(), Config.cookie!())

    if System.get_env("__BURRITO") do
      # Running as a compiled binary — execute the CLI and halt when done.
      code = Planck.CLI.Main.run(System.argv())
      System.halt(code)
    else
      # Development: start the web server so http://localhost:4000 is always
      # available when running `iex -S mix` or `mix run --no-halt`.
      Planck.Web.Supervisor.start_link()
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # Parse just --sname / --cookie from argv and write them into Application env
  # before preload() runs so they override the Skogsra defaults.
  @spec apply_distribution_argv() :: :ok
  defp apply_distribution_argv do
    {opts, _, _} =
      OptionParser.parse(System.argv(),
        strict: [sname: :string, cookie: :string],
        aliases: []
      )

    if sname = opts[:sname], do: Config.put_sname(sname)
    if cookie = opts[:cookie], do: Config.put_cookie(cookie)
    :ok
  end

  defp start_distribution(sname, cookie) do
    node_name = String.to_atom(sname)
    node_cookie = String.to_atom(cookie)

    case :net_kernel.start([node_name, :shortnames]) do
      {:ok, _} ->
        Node.set_cookie(node_cookie)

      {:error, {:already_started, _}} ->
        Node.set_cookie(node_cookie)

      {:error, reason} ->
        Logger.warning(
          "Could not start Erlang distribution (#{inspect(reason)}). " <>
            "Sidecar will not be available."
        )
    end

    :ok
  rescue
    _ ->
      Logger.warning("Could not start Erlang distribution. Sidecar will not be available.")
      :ok
  end
end
