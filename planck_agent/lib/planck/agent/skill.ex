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
  """
  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          path: Path.t(),
          skill_file: Path.t()
        }

  @enforce_keys [:name, :description, :path, :skill_file]
  defstruct [:name, :description, :path, :skill_file]

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
         {:ok, name, description} <- parse_frontmatter(content, skill_file) do
      {:ok,
       %__MODULE__{
         name: name,
         description: description,
         path: Path.dirname(skill_file),
         skill_file: skill_file
       }}
    end
  end

  @doc """
  Generate a skills section for injection into an agent's system prompt.

  Produces a compact index of skill names and descriptions, followed by an
  instruction to load skills via the `load_skill` tool. Returns `nil` when
  the list is empty.
  """
  @spec system_prompt_section([t()]) :: String.t() | nil
  def system_prompt_section([]), do: nil

  def system_prompt_section(skills) do
    entries =
      Enum.map_join(skills, "\n", fn %__MODULE__{name: name, description: desc} ->
        "- **#{name}** — #{desc}"
      end)

    """
    ## Available skills

    #{entries}

    Use `load_skill` tool with the skill name to load its full instructions when relevant.
    Resource files referenced inside a skill are loaded via the `read` tool using
    the absolute paths provided in the skill's content.
    """
  end

  @doc """
  Build a `load_skill` tool that loads a skill's `SKILL.md` by name.

  The tool is a closure over the given skill pool. It is automatically added to
  every agent when skills are available — agents do not need to declare it in
  their TEAM.json `"tools"` array.
  """
  @spec load_skill_tool([t()]) :: Tool.t()
  def load_skill_tool(skills) do
    skill_map = Map.new(skills, &{&1.name, &1})

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
      execute_fn: fn _id, %{"name" => name} ->
        case Map.get(skill_map, name) do
          nil ->
            available = skill_map |> Map.keys() |> Enum.sort() |> Enum.join(", ")
            {:error, "Unknown skill: #{name}. Available: #{available}"}

          skill ->
            File.read(skill.skill_file)
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
      execute_fn: fn _id, _args ->
        if entries == "",
          do: {:ok, "No skills available."},
          else: {:ok, entries}
      end
    )
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

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
          {:ok, String.t(), String.t()} | {:error, String.t()}
  defp parse_frontmatter(content, path) do
    content = String.replace(content, "\r\n", "\n")

    case Regex.run(@frontmatter_re, content, capture: :all_but_first) do
      nil ->
        {:error, "#{path} has no frontmatter (expected --- ... --- at the top)"}

      [frontmatter] ->
        with {:ok, name} <- extract_field(frontmatter, "name", path),
             {:ok, description} <- extract_field(frontmatter, "description", path) do
          {:ok, name, description}
        end
    end
  end

  @spec extract_field(String.t(), String.t(), Path.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp extract_field(frontmatter, field, path) do
    pattern = ~r/^#{Regex.escape(field)}:\s*(.+)$/m

    case Regex.run(pattern, frontmatter, capture: :all_but_first) do
      [value] ->
        trimmed = String.trim(value)
        if trimmed != "", do: {:ok, trimmed}, else: {:error, "#{path}: #{field} is blank"}

      nil ->
        {:error, "#{path}: missing required frontmatter field '#{field}'"}
    end
  end
end
