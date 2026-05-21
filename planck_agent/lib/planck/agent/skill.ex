defmodule Planck.Agent.Skill do
  @moduledoc """
  Filesystem-based agent skills.

  A skill is a subdirectory under a skills directory (e.g. `.planck/skills/`)
  containing a `SKILL.md` file. The file has YAML frontmatter with `name` and
  `description`, followed by usage instructions, resource references, and any
  other context the agent needs.

  ## Directory layout

      .planck/skills/
      └── n8n-expert/
          ├── SKILL.md            ← required
          ├── docs/
          │   └── node-types.md   ← lazily loaded by the agent via `read`
          └── scripts/
              └── validate.sh     ← runnable via `bash`

  ## SKILL.md format

      ---
      name: n8n-expert
      description: Expert at building n8n workflows and automation.
      ---

  Descriptions containing colons must be quoted:

      description: "Expert at n8n: workflow automation"

      # N8N Expert

      You are an expert at n8n...

      ## Resources

      - `docs/node-types.md` — reference for all n8n node types
      - `scripts/validate.sh` — validates a workflow JSON file

  Only `name` and `description` are parsed from the frontmatter. The rest of
  the file is plain Markdown consumed by the agent when it loads the skill.

  ## Usage

      skills = Planck.Agent.Skill.load_all(["~/.planck/skills"])

      # Skills are typically threaded through AgentSpec.to_start_opts/2 via
      # skill_pool:, which resolves spec.skills names and appends the skill
      # section to system_prompt for the relevant agent.
      start_opts = Planck.Agent.AgentSpec.to_start_opts(spec, skill_pool: skills)

  The agent discovers skills from the system prompt index and loads `SKILL.md`
  via the `read` tool when a skill is relevant. Scripts are run via `bash`.
  No special runtime support is required — skills are just files.
  """

  require Logger

  alias Planck.Agent.Tool

  @skill_file "SKILL.md"
  @frontmatter_re ~r/\A---\n(.*?)\n---/s

  @typedoc """
  A loaded skill.

  - `:name` — identifier used in the system prompt index
  - `:description` — one-line summary shown to the agent
  - `:path` — absolute path to the skill directory
  - `:skill_file` — absolute path to `SKILL.md`
  - `:always_present` — when `true`, always included in the system prompt index
    regardless of usage ranking. Set by users; agents always write `false`.
  - `:planck_version` — semver string set on Planck-bundled skills; `nil` on
    user- and agent-created skills. Used for upgrade detection.
  """
  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          path: Path.t(),
          skill_file: Path.t(),
          always_present: boolean(),
          planck_version: String.t() | nil
        }

  @enforce_keys [:name, :description, :path, :skill_file]
  defstruct [:name, :description, :path, :skill_file, always_present: false, planck_version: nil]

  @doc """
  Load all skills from a list of directories.

  Each directory is scanned for subdirectories containing a `SKILL.md` file.
  Directories that do not exist are silently skipped. Invalid `SKILL.md` files
  are skipped with a warning.

  Paths are expanded via `Path.expand/1` so `~` and relative paths resolve
  correctly.
  """
  @spec load_all([Path.t()]) :: [t()]
  def load_all(dirs) when is_list(dirs) do
    Enum.flat_map(dirs, &load_dir/1)
  end

  @doc """
  Load a single skill from a `SKILL.md` file path.

  Returns `{:ok, skill}` or `{:error, reason}`.
  """
  @spec from_file(Path.t()) :: {:ok, t()} | {:error, String.t()}
  def from_file(skill_file) do
    with {:ok, content} <- read_file(skill_file),
         {:ok, fields} <- parse_frontmatter(content, skill_file) do
      {:ok,
       %__MODULE__{
         name: fields.name,
         description: fields.description,
         path: Path.dirname(skill_file),
         skill_file: skill_file,
         always_present: fields.always_present,
         planck_version: fields.planck_version
       }}
    end
  end

  @doc """
  Build the skill index section for the system prompt.

  Accepts the full pool of available skills, the ordered list of ranked skill
  names (from SQLite usage history), and the maximum number of ranked skills to
  show. Returns `nil` when there are no skills at all.

  ## Structure

  1. **Pinned** (`always_present: true`) — always included, listed first.
  2. **Last used** — up to `top_n` skills from `ranked_names`, excluding pinned.
  3. **Discovery line** — appended when there are more skills than shown.
  """
  @spec system_prompt_section([t()], [String.t()], pos_integer()) :: String.t() | nil
  def system_prompt_section(all_skills, ranked_names, top_n)

  def system_prompt_section([], _ranked_names, _top_n), do: nil

  def system_prompt_section(all_skills, ranked_names, top_n) do
    skill_map = Map.new(all_skills, &{&1.name, &1})

    pinned = Enum.filter(all_skills, & &1.always_present)
    pinned_names = MapSet.new(pinned, & &1.name)

    ranked =
      ranked_names
      |> Enum.reject(&MapSet.member?(pinned_names, &1))
      |> Enum.flat_map(&List.wrap(Map.get(skill_map, &1)))
      |> Enum.take(top_n)

    shown = pinned ++ ranked
    shown_names = MapSet.new(shown, & &1.name)
    remaining = Enum.count(all_skills) - MapSet.size(shown_names)

    case shown do
      [] ->
        nil

      _ ->
        sections = []

        sections =
          if pinned != [] do
            entries = Enum.map_join(pinned, "\n", &skill_entry/1)
            ["\n## Skills\n\n#{entries}" | sections]
          else
            sections
          end

        sections =
          if ranked != [] do
            entries = Enum.map_join(ranked, "\n", &skill_entry/1)
            ["\n## Last used skills\n\n#{entries}" | sections]
          else
            sections
          end

        body = sections |> Enum.reverse() |> Enum.join("")

        String.trim_leading(body) <> discovery_line(remaining)
    end
  end

  @doc """
  Build a `load_skill` tool that loads a skill's `SKILL.md` by name.

  The tool is a closure over the given skill pool. It is automatically added to
  every agent when skills are available — agents do not need to declare it in
  their TEAM.json `"tools"` array.
  """
  @spec load_skill_tool([t()]) :: Tool.t()
  @spec load_skill_tool([t()], keyword()) :: Tool.t()
  def load_skill_tool(skills, opts \\ []) do
    skill_refresh_fn = Keyword.get(opts, :skill_refresh_fn)
    on_use = Keyword.get(opts, :on_use)

    Tool.new(
      name: "load_skill",
      description:
        "Load a skill's full instructions by name. Use this when a skill is relevant to the current task.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "description" => "The skill name (e.g. \"elixir-dev\")"}
        },
        "required" => ["name"]
      },
      execute_fn: fn agent_id, _id, %{"name" => name} ->
        current = if skill_refresh_fn, do: skill_refresh_fn.(), else: skills
        skill_map = Map.new(current, &{&1.name, &1})

        case Map.get(skill_map, name) do
          nil ->
            available = skill_map |> Map.keys() |> Enum.sort() |> Enum.join(", ")
            {:error, "Unknown skill: #{name}. Available: #{available}"}

          skill ->
            if on_use, do: on_use.(agent_id, name)

            case File.read(skill.skill_file) do
              {:ok, content} -> {:ok, "Skill directory: #{skill.path}\n\n" <> content}
              error -> error
            end
        end
      end
    )
  end

  @doc """
  Build a `list_skills` tool that returns all available skill names and descriptions.

  This is an opt-in discovery tool. Add `"list_skills"` to an agent's TEAM.json
  `"tools"` array when that agent needs to autonomously discover what skills exist.
  Workers that receive skill names from the orchestrator do not need this tool.
  """
  @spec list_skills_tool([t()]) :: Tool.t()
  def list_skills_tool(skills) do
    entries =
      Enum.map_join(skills, "\n", fn %__MODULE__{name: name, description: desc} ->
        "- **#{name}**: #{desc}"
      end)

    Tool.new(
      name: "list_skills",
      description: "List all available skills with their names and descriptions.",
      parameters: %{"type" => "object", "properties" => %{}, "required" => []},
      execute_fn: fn _agent_id, _id, _args ->
        if entries == "",
          do: {:ok, "No skills available."},
          else: {:ok, entries}
      end
    )
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec skill_entry(t()) :: String.t()
  defp skill_entry(%__MODULE__{name: name, description: desc}) do
    "- **#{name}** — #{desc}"
  end

  @spec discovery_line(non_neg_integer()) :: String.t()
  defp discovery_line(0), do: ""
  defp discovery_line(1), do: "\n\nCall `list_skills` to discover 1 more skill."
  defp discovery_line(n), do: "\n\nCall `list_skills` to discover #{n} more skills."

  @spec yaml_field([{charlist(), term()}], String.t()) :: term()
  defp yaml_field(pairs, key) do
    Enum.find_value(pairs, fn {k, v} -> k == String.to_charlist(key) && v end)
  end

  @spec load_dir(Path.t()) :: [t()]
  defp load_dir(dir) do
    expanded = Path.expand(dir)

    if File.dir?(expanded) do
      expanded |> File.ls!() |> Enum.flat_map(&load_entry(expanded, &1))
    else
      []
    end
  end

  @spec load_entry(Path.t(), String.t()) :: [t()]
  defp load_entry(dir, entry) do
    skill_path = Path.join(dir, entry)
    skill_file = Path.join(skill_path, @skill_file)

    if File.dir?(skill_path) and File.regular?(skill_file) do
      case from_file(skill_file) do
        {:ok, skill} ->
          [skill]

        {:error, reason} ->
          Logger.warning("[Planck.Agent.Skill] skipping #{skill_file}: #{reason}")
          []
      end
    else
      []
    end
  end

  @spec read_file(Path.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  @spec parse_frontmatter(String.t(), Path.t()) ::
          {:ok, map()} | {:error, String.t()}
  defp parse_frontmatter(content, path) do
    content = String.replace(content, "\r\n", "\n")

    case Regex.run(@frontmatter_re, content, capture: :all_but_first) do
      nil -> {:error, "#{path} has no frontmatter (expected --- ... --- at the top)"}
      [frontmatter] -> parse_yaml_fields(frontmatter, path)
    end
  end

  @spec parse_yaml_fields(String.t(), Path.t()) ::
          {:ok, map()} | {:error, String.t()}
  defp parse_yaml_fields(yaml, path) do
    Application.ensure_all_started(:yamerl)

    case :yamerl_constr.string(String.to_charlist(yaml)) do
      [[_ | _] = pairs] ->
        name = yaml_field(pairs, "name")
        desc = yaml_field(pairs, "description")
        always_present = yaml_field(pairs, "always_present")
        planck_version = yaml_field(pairs, "planck_version")

        cond do
          is_nil(name) ->
            {:error, "#{path}: missing required frontmatter field 'name'"}

          is_nil(desc) ->
            {:error, "#{path}: missing required frontmatter field 'description'"}

          true ->
            {:ok,
             %{
               name: to_string(name),
               description: to_string(desc),
               always_present: always_present == true,
               planck_version:
                 if(is_nil(planck_version), do: nil, else: to_string(planck_version))
             }}
        end

      _ ->
        {:error, "#{path}: frontmatter must be a YAML mapping"}
    end
  catch
    _, reason -> {:error, "#{path}: invalid YAML in frontmatter: #{inspect(reason)}"}
  end
end
