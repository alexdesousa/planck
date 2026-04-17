defmodule Planck.AI.HTTPClient do
  @moduledoc false

  @callback get(String.t(), keyword()) ::
              {:ok, %{status: integer(), body: term()}} | {:error, term()}
end

defmodule Planck.AI.ReqHTTPClient do
  @moduledoc false

  @behaviour Planck.AI.HTTPClient

  @impl true
  def get(url, opts) do
    case Req.get(url, opts) do
      {:ok, resp} -> {:ok, %{status: resp.status, body: resp.body}}
      {:error, reason} -> {:error, reason}
    end
  end
end
