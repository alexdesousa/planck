defmodule Planck.Headless.Secrets.EnvFile do
  @moduledoc """
  Default `Planck.Headless.Secrets` implementation that reads and writes
  API keys to `.planck/.env` and `~/.planck/.env`.

  Keys are stored as `KEY_NAME=value` lines. Writing a key that already
  exists updates it in-place; writing a new key appends it.

  This is the current default behaviour, unchanged from earlier releases.
  """

  @behaviour Planck.Agent.Secrets

  @local_path ".planck/.env"
  @global_path "~/.planck/.env"

  @impl true
  def store(key, value) do
    write_to(@local_path, key, value)
  end

  @impl true
  def fetch(key) do
    fetch_all()
    |> Map.get(key)
    |> case do
      nil -> {:error, :not_found}
      value -> {:ok, value}
    end
  end

  @impl true
  def fetch_all do
    [@global_path, @local_path]
    |> fetch_all(%{})
  end

  @impl true
  def list do
    keys =
      [@global_path, @local_path]
      |> fetch_all(%{})
      |> Map.keys()
      |> Enum.uniq()

    {:ok, keys}
  end

  @impl true
  def delete(key) do
    case delete_key(@local_path, key) do
      :deleted ->
        :ok

      :not_found ->
        delete_key(@global_path, key)
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Internal — used by headless.ex for write-on-configure
  # ---------------------------------------------------------------------------

  @doc """
  Write a key=value pair to the given `.env` file path.

  Creates the file and its parent directories if they don't exist.
  Updates the line in-place if the key already exists.
  """
  @spec write_to(Path.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def write_to(path, key, value) do
    expanded = Path.expand(path)
    :ok = ensure_dir(path)

    existing =
      case File.read(expanded) do
        {:ok, content} -> fetch_all(content)
        _ -> %{}
      end

    existing
    |> Map.put(key, value)
    |> Enum.map_join("\n", fn {k, v} -> "#{k}=#{v}" end)
    |> then(&File.write(expanded, &1 <> "\n"))
  end

  @spec fetch_all([Path.t()], variables) :: variables
        when variables: %{String.t() => String.t()}
  defp fetch_all(files, acc)

  defp fetch_all([], acc) do
    acc
  end

  defp fetch_all([file | rest], acc) do
    expanded = Path.expand(file)

    case File.read(expanded) do
      {:ok, content} ->
        variables = fetch_all(content)
        acc = Map.merge(acc, variables)
        fetch_all(rest, acc)

      _ ->
        fetch_all(rest, acc)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec fetch_all(String.t()) :: variables
        when variables: %{String.t() => String.t()}
  defp fetch_all(content)

  defp fetch_all(content) when is_binary(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, "=", parts: 2) do
        [k, v] -> [{k, v}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  @spec delete_key(Path.t(), String.t()) :: :deleted | :not_found
  defp delete_key(path, key)

  defp delete_key(path, key)
       when is_binary(path) and is_binary(key) do
    expanded = Path.expand(path)

    case File.read(expanded) do
      {:ok, content} ->
        vars = fetch_all(content)
        do_delete_key(expanded, key, vars)

      _ ->
        :not_found
    end
  end

  @spec do_delete_key(Path.t(), String.t(), %{String.t() => String.t()}) ::
          :not_found
          | :deleted
  defp do_delete_key(path, key, vars)

  defp do_delete_key(path, key, vars) when is_map_key(vars, key) do
    vars
    |> Map.delete(key)
    |> Enum.map_join("\n", fn {k, v} -> "#{k}=#{v}" end)
    |> then(&File.write(path, &1 <> "\n"))

    :deleted
  end

  defp do_delete_key(_path, _key, _vars) do
    :not_found
  end

  @spec ensure_dir(Path.t()) :: :ok | {:error, term()}
  defp ensure_dir(path)

  defp ensure_dir(path) when is_binary(path) do
    path
    |> Path.expand()
    |> Path.dirname()
    |> File.mkdir_p()
  end
end
