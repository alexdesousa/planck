defmodule Sidecar.FileType do
  @moduledoc """
  Utilities for detecting whether a file contains binary or text content.

  Detection is based on sampling the first bytes of the file and checking
  for valid UTF-8 — no extension lists to maintain. A PDF without an
  extension is detected as binary; a `.heex` file is detected as text.
  """

  @sample_bytes 4_096

  @doc """
  Returns `true` if the file's content is not valid UTF-8 text.

  Reads the first #{@sample_bytes} bytes and checks `String.valid?/1`.
  Returns `false` for files that cannot be opened.
  """
  @spec binary?(Path.t()) :: boolean()
  def binary?(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, f} ->
        sample = IO.binread(f, @sample_bytes)
        :ok = File.close(f)
        is_binary(sample) and not String.valid?(sample)

      _ ->
        false
    end
  end
end
