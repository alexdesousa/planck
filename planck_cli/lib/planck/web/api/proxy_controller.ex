defmodule Planck.Web.API.ProxyController do
  @moduledoc false

  use Planck.Web, :controller

  alias OpenApiSpex.{Operation, Schema}

  @max_bytes 10_000_000

  def open_api_operation(:image),
    do: %Operation{
      tags: ["Resources"],
      summary: "Proxy an image",
      description: """
      Fetches an image through the server and returns it to the browser.
      Required to bypass CORS restrictions on cross-origin images and to serve
      local `file://` paths. Requests to domains or paths not in the server
      allowlist return `403`.
      """,
      operationId: "ProxyController.image",
      parameters: [
        Operation.parameter(:url, :query, :string, "Image URL to proxy (HTTP, HTTPS, or file://)",
          required: true
        )
      ],
      responses: %{
        200 =>
          Operation.response("Image", "application/octet-stream", %Schema{
            type: :string,
            format: :binary
          }),
        403 => Operation.response("Forbidden", "text/plain", %Schema{type: :string}),
        404 => Operation.response("Not Found", "text/plain", %Schema{type: :string}),
        502 => Operation.response("Bad Gateway", "text/plain", %Schema{type: :string})
      }
    }

  @spec image(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def image(conn, params)

  def image(conn, %{"url" => "file://" <> path}) do
    real_path = ("/" <> String.trim_leading(path, "/")) |> Path.expand()
    allowed = Planck.CLI.Config.proxy_image_paths!() |> Enum.map(&Path.expand/1)

    if Enum.any?(allowed, &String.starts_with?(real_path, &1)) do
      serve_file(conn, real_path)
    else
      send_resp(conn, 403, "")
    end
  end

  def image(conn, %{"url" => url}) do
    uri = URI.parse(url)
    allowed = Planck.CLI.Config.proxy_image_domains!()

    if uri.scheme in ["http", "https"] and uri.host in allowed do
      fetch_and_serve(conn, url)
    else
      send_resp(conn, 403, "")
    end
  end

  @spec fetch_and_serve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  defp fetch_and_serve(conn, url) do
    case Req.get(url) do
      {:ok, %{status: 200, body: body, headers: headers}} ->
        body =
          if is_binary(body) and byte_size(body) > @max_bytes,
            do: binary_part(body, 0, @max_bytes),
            else: body

        conn
        |> put_resp_content_type(content_type(headers))
        |> put_resp_header("cache-control", "public, max-age=3600")
        |> send_resp(200, body)

      {:ok, %{status: status}} ->
        send_resp(conn, status, "")

      {:error, _} ->
        send_resp(conn, 502, "")
    end
  end

  @spec serve_file(Plug.Conn.t(), Path.t()) :: Plug.Conn.t()
  defp serve_file(conn, path) do
    case File.read(path) do
      {:ok, body} ->
        conn
        |> put_resp_content_type(MIME.from_path(path))
        |> put_resp_header("cache-control", "public, max-age=3600")
        |> send_resp(200, body)

      {:error, _} ->
        send_resp(conn, 404, "")
    end
  end

  @spec content_type(%{optional(binary()) => [binary()]}) :: String.t()
  defp content_type(headers) do
    case Req.Response.get_header(%Req.Response{headers: headers}, "content-type") do
      [ct | _] -> ct |> String.split(";") |> List.first()
      [] -> "application/octet-stream"
    end
  end
end
