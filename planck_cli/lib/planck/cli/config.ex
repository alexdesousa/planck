defmodule Planck.CLI.Config do
  @moduledoc """
  Runtime configuration for `planck_cli`.

  Values are resolved by Skogsra from (highest priority first):

  1. Environment variables
  2. Application config (`config :planck_cli, ...`)
  3. Per-environment defaults

  Call `preload/0` before starting any supervised children so Phoenix and
  other dependencies read the resolved values via `Application.get_env/2`.
  """

  use Skogsra

  defmodule CommaSeparatedList do
    @moduledoc false
    use Skogsra.Type

    @impl true
    def cast(value) when is_list(value), do: {:ok, value}

    def cast(value) when is_binary(value) do
      items = value |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
      {:ok, items}
    end

    def cast(_), do: {:error, "expected a comma-separated string or list"}
  end

  defmodule IpAddress do
    @moduledoc false

    # Skogsra type that parses an IP address string into an Erlang IP tuple.
    # Accepts IPv4 ("127.0.0.1") and IPv6 ("::1").
    # Passes tuples through unchanged so the default value works as-is.

    use Skogsra.Type

    @impl true
    @spec cast(term()) :: {:ok, :inet.ip_address()} | {:error, binary()}
    def cast(value) when is_tuple(value), do: {:ok, value}

    def cast(value) when is_binary(value) do
      case :inet.parse_address(String.to_charlist(value)) do
        {:ok, ip} -> {:ok, ip}
        {:error, _} -> {:error, "#{inspect(value)} is not a valid IP address"}
      end
    end

    def cast(value), do: {:error, "#{inspect(value)} is not a valid IP address"}
  end

  @envdoc """
  Phoenix endpoint secret key base used to sign cookies and LiveView connections.
  If not set a random key is generated at each startup — active sessions will
  not survive a restart. Set this env var for persistent sessions.
  """
  app_env :secret_key_base, :planck_cli, ["Elixir.Planck.Web.Endpoint", :secret_key_base],
    type: :binary,
    os_env: "SECRET_KEY_BASE",
    env_overrides: [
      dev: [default: "ktGG3zm3ZlYJnp6QqlvdH69bMgTT6H+gkCecYkXgYYp3a3YqaVpPGqH2JdjbbF0o"],
      test: [default: "vbREe4KPexSPleDG9tJVpfWcrTOPlKXXBDGS3+lU+a8H6t6NX5bJhC3waVBH8AH0"]
    ]

  @envdoc "HTTP port for the web UI."
  app_env :port, :planck_cli, ["Elixir.Planck.Web.Endpoint", :http, :port],
    type: :integer,
    os_env: "PORT",
    env_overrides: [
      dev: [default: 4000],
      test: [default: 4002],
      prod: [default: 4000]
    ]

  @envdoc """
  IP address to bind the web server to.
  Default is 127.0.0.1 (localhost only). Use 0.0.0.0 to expose on all
  network interfaces (e.g. inside a Docker container).
  """
  app_env :ip_address, :planck_cli, ["Elixir.Planck.Web.Endpoint", :http, :ip],
    type: Planck.CLI.Config.IpAddress,
    os_env: "IP_ADDRESS",
    default: {127, 0, 0, 1}

  @envdoc "Hostname used in generated URLs (e.g. planck.example.com)."
  app_env :host, :planck_cli, ["Elixir.Planck.Web.Endpoint", :url, :host],
    os_env: "HOST",
    default: "localhost"

  @envdoc """
  Erlang short node name for distributed mode (required by the sidecar).
  Defaults to `planck_cli`; passed as `--sname` to the Erlang VM at startup.
  """
  app_env :sname, :planck_cli, :sname,
    os_env: "NODE_SNAME",
    default: "planck_cli"

  @envdoc "Erlang magic cookie for distributed mode. Defaults to `planck`."
  app_env :cookie, :planck_cli, :cookie,
    os_env: "NODE_COOKIE",
    default: "planck"

  @envdoc """
  Comma-separated list of domains (with optional port) allowed for the image proxy
  (`/api/proxy`). Requests to unlisted domains return 403. Defaults to empty (deny all).

  Example: `PLANCK_PROXY_IMAGE_DOMAINS=image.coroto.net,cdn.example.com:8080`
  """
  app_env :proxy_image_domains, :planck_cli, :proxy_image_domains,
    os_env: "PLANCK_PROXY_IMAGE_DOMAINS",
    type: Planck.CLI.Config.CommaSeparatedList,
    default: []

  @envdoc """
  Colon-separated list of local path prefixes allowed for the image proxy.
  Only files under these paths are served via `file://` URLs. Path traversal
  is prevented. Defaults to empty (deny all local files).

  Example: `PLANCK_PROXY_IMAGE_PATHS=/home/user/comfyui/output:/tmp/images`
  """
  app_env :proxy_image_paths, :planck_cli, :proxy_image_paths,
    os_env: "PLANCK_PROXY_IMAGE_PATHS",
    type: Planck.Headless.Config.PathList,
    default: []
end
