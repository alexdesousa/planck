defmodule Planck.Headless.Config.PathList do
  @moduledoc false

  use Skogsra.Type

  @impl Skogsra.Type
  @spec cast(term()) :: {:ok, [String.t()]} | {:error, String.t()}
  def cast(value) when is_binary(value) do
    paths =
      value
      |> String.split(":")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {:ok, paths}
  end

  def cast(value) when is_list(value) do
    if Enum.all?(value, &is_binary/1) do
      {:ok, value}
    else
      {:error, "expected a list of strings, got: #{inspect(value)}"}
    end
  end

  def cast(value) do
    {:error, "expected a colon-separated string or list of strings, got: #{inspect(value)}"}
  end
end
