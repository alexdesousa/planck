defmodule Planck.Agent.TeamTemplate do
  @moduledoc """
  Loads static agent definitions from a JSON file.

  Only the serializable fields are loaded — `execute_fn` cannot be represented
  in JSON. The caller merges tools in programmatically before starting agents.

  ## JSON format

  Only `"type"`, `"provider"`, and `"model_id"` are required. `"system_prompt"`
  accepts either an inline string or a path to a `.md` file, resolved relative
  to the template file's directory.

      [
        {
          "type":          "builder",
          "name":          "Builder Joe",
          "provider":      "anthropic",
          "model_id":      "claude-sonnet-4-6",
          "system_prompt": "You are an expert software builder.",
          "opts": {
            "temperature": 0.7
          }
        },
        {
          "type":          "tester",
          "name":          "Tester Alice",
          "provider":      "ollama",
          "model_id":      "llama3.2",
          "system_prompt": "prompts/tester.md"
        }
      ]

  ## Loading from a file

      {:ok, specs} = Planck.Agent.TeamTemplate.load("config/team.json")

      tools_by_type = %{
        "builder" => [read_tool, write_tool],
        "tester"  => [read_tool, bash_tool]
      }

      team_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
      session_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

      Enum.each(specs, fn spec ->
        tools = Map.get(tools_by_type, spec.type, [])
        start_opts = Planck.Agent.AgentSpec.to_start_opts(spec,
          tools: tools,
          team_id: team_id,
          session_id: session_id
        )
        DynamicSupervisor.start_child(Planck.Agent.AgentSupervisor, {Planck.Agent.Agent, start_opts})
      end)

  ## Loading from a pre-decoded list

      {:ok, specs} = Planck.Agent.TeamTemplate.from_list(decoded_list)

  """

  require Logger

  alias Planck.Agent.AgentSpec

  @provider_atoms Map.new(Planck.AI.Model.providers(), fn p -> {Atom.to_string(p), p} end)

  @doc """
  Loads agent specs from a JSON file at `path`.

  `system_prompt` values that look like file paths (ending in `.md` or `.txt`)
  are resolved relative to the template file's directory and read from disk.

  Returns `{:ok, [AgentSpec.t()]}`. Invalid entries are skipped with a warning.
  Returns `{:error, reason}` if the file cannot be read or JSON is malformed.
  """
  @spec load(Path.t()) :: {:ok, [AgentSpec.t()]} | {:error, term()}
  def load(path) do
    base_dir = Path.dirname(path)

    with {:ok, content} <- File.read(path),
         {:ok, data} <- Jason.decode(content) do
      {:ok, from_list(data, base_dir: base_dir)}
    end
  end

  @doc """
  Converts a list of maps (as decoded from JSON) into a list of `AgentSpec` structs.

  Invalid entries are skipped with a warning; the rest are returned.
  Accepts `base_dir:` for resolving relative `system_prompt` file paths.
  """
  @spec from_list([map()]) :: [AgentSpec.t()]
  @spec from_list([map()], keyword()) :: [AgentSpec.t()]
  def from_list(entries, opts \\ []) when is_list(entries) do
    base_dir = Keyword.get(opts, :base_dir, File.cwd!())

    Enum.flat_map(entries, fn entry ->
      case from_map(entry, base_dir) do
        {:ok, spec} ->
          [spec]

        {:error, reason} ->
          Logger.warning(
            "[Planck.Agent.TeamTemplate] skipping entry: #{reason} — #{inspect(entry)}"
          )

          []
      end
    end)
  end

  @doc """
  Converts a single map into an `AgentSpec` struct.

  Returns `{:ok, spec}` or `{:error, reason}`.
  """
  @spec from_map(map()) :: {:ok, AgentSpec.t()} | {:error, String.t()}
  @spec from_map(map(), Path.t()) :: {:ok, AgentSpec.t()} | {:error, String.t()}
  def from_map(entry, base_dir \\ ".")

  def from_map(
        %{"type" => type, "provider" => raw_provider, "model_id" => model_id} = entry,
        base_dir
      )
      when is_binary(type) and type != "" and is_binary(model_id) and model_id != "" do
    with {:ok, provider} <- parse_provider(raw_provider),
         {:ok, system_prompt} <- resolve_system_prompt(entry["system_prompt"], base_dir) do
      {:ok,
       AgentSpec.new(
         type: type,
         name: entry["name"],
         description: entry["description"],
         provider: provider,
         model_id: model_id,
         system_prompt: system_prompt,
         opts: parse_opts(entry["opts"])
       )}
    end
  end

  def from_map(%{"type" => ""}, _base_dir), do: {:error, "type must not be empty"}

  def from_map(%{"type" => _}, _base_dir),
    do: {:error, "missing required field: provider or model_id"}

  def from_map(_, _base_dir), do: {:error, "missing required field: type"}

  # --- Private ---

  @spec parse_provider(String.t()) :: {:ok, atom()} | {:error, String.t()}
  defp parse_provider(p) do
    case Map.fetch(@provider_atoms, p) do
      {:ok, atom} ->
        {:ok, atom}

      :error ->
        {:error,
         "unknown provider #{inspect(p)}; valid: #{Enum.join(Map.keys(@provider_atoms), ", ")}"}
    end
  end

  @spec resolve_system_prompt(String.t() | nil, Path.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp resolve_system_prompt(nil, _base_dir), do: {:ok, ""}
  defp resolve_system_prompt("", _base_dir), do: {:ok, ""}

  defp resolve_system_prompt(value, base_dir) when is_binary(value) do
    if file_path?(value) do
      full_path = Path.join(base_dir, value)

      case File.read(full_path) do
        {:ok, content} -> {:ok, String.trim(content)}
        {:error, reason} -> {:error, "could not read system_prompt file #{full_path}: #{reason}"}
      end
    else
      {:ok, value}
    end
  end

  @spec file_path?(String.t()) :: boolean()
  defp file_path?(value) do
    String.ends_with?(value, ".md") or String.ends_with?(value, ".txt")
  end

  @spec parse_opts(map() | nil) :: keyword()
  defp parse_opts(nil), do: []

  defp parse_opts(map) when is_map(map) do
    Enum.flat_map(map, fn {k, v} ->
      try do
        [{String.to_existing_atom(k), v}]
      rescue
        ArgumentError ->
          Logger.warning("[Planck.Agent.TeamTemplate] unknown opt key #{inspect(k)}, skipping")
          []
      end
    end)
  end

  defp parse_opts(_), do: []
end
