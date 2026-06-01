defmodule Planck.Headless.Secrets.EnvFile do
  @moduledoc """
  Default `Planck.Headless.Secrets` implementation that reads and writes
  API keys to `.planck/.env` and `~/.planck/.env`.

  Keys are stored as `KEY_NAME=value` lines. Writing a key that already
  exists updates it in-place; writing a new key appends it.

  This is the current default behaviour, unchanged from earlier releases.
  """

  @behaviour Planck.Headless.Secrets

  @local_path ".planck/.env"
  @global_path "~/.planck/.env"

  @impl true
  def store(key, value) do
    write_to(@local_path, key, value)
  end

  @impl true
  def fetch(key) do
    case read_key(key) do
      nil -> :not_found
      value -> {:ok, value}
    end
  end

  @impl true
  def list do
    keys =
      [@local_path, @global_path]
      |> Enum.flat_map(&read_keys/1)
      |> Enum.uniq()

    {:ok, keys}
  end

  @impl true
  def delete(key) do
    Enum.each([@local_path, @global_path], &delete_key(&1, key))
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

    lines =
      case File.read(expanded) do
        {:ok, content} -> String.split(content, "\n", trim: true)
        {:error, :enoent} -> []
      end

    {found, updated} =
      Enum.reduce(lines, {false, []}, fn line, {found, acc} ->
        if String.starts_with?(line, "#{key}=") do
          {true, ["#{key}=#{value}" | acc]}
        else
          {found, [line | acc]}
        end
      end)

    final = if found, do: updated, else: ["#{key}=#{value}" | updated]
    File.write(expanded, final |> Enum.reverse() |> Enum.join("\n") |> Kernel.<>("\n"))
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec read_key(String.t()) :: String.t() | nil
  defp read_key(key) do
    Enum.find_value([@local_path, @global_path], fn path ->
      expanded = Path.expand(path)

      case File.read(expanded) do
        {:ok, content} -> find_value(key, content)
        _ -> nil
      end
    end)
  end

  @spec find_value(String.t(), String.t()) :: String.t() | nil
  defp find_value(key, content)

  defp find_value(key, content)
       when is_binary(key) and is_binary(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      case String.split(line, "=", parts: 2) do
        [^key, val] -> val
        _ -> nil
      end
    end)
  end

  @spec read_keys(Path.t()) :: [String.t()]
  defp read_keys(path) do
    expanded = Path.expand(path)

    case File.read(expanded) do
      {:ok, content} ->
        find_keys(content)

      _ ->
        []
    end
  end

  @spec find_keys(String.t()) :: [String.t()]
  defp find_keys(content)

  defp find_keys(content) when is_binary(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, "=", parts: 2) do
        [key, _] -> [key]
        _ -> []
      end
    end)
  end

  @spec delete_key(Path.t(), String.t()) :: :ok | {:error, term()}
  defp delete_key(path, key)

  defp delete_key(path, key)
       when is_binary(path) and is_binary(key) do
    expanded = Path.expand(path)

    case File.read(expanded) do
      {:ok, content} ->
        updated =
          content
          |> String.split("\n", trim: true)
          |> Enum.reject(&String.starts_with?(&1, "#{key}="))
          |> Enum.join("\n")

        File.write(expanded, updated <> "\n")

      _ ->
        :ok
    end
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
