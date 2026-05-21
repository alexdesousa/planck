defmodule Planck.Agent.SkillIndex do
  @moduledoc """
  Holds all skill-related state for a running agent.

  Two concerns live here:

  - **System prompt index** — `pool`, `ranked`, and `top_n` are frozen at
    session start and used by `SystemPrompt.build/1` on every turn without
    calling any external function (cache-friendly).
  - **Tool dispatch** — `names` and `refresh_fn` are used by the `load_skill`
    and `list_skills` tools to resolve and hot-reload the skill pool.
  """

  alias Planck.Agent.Skill

  @typedoc """
  - `:pool` — frozen list of `Skill.t()` for the system prompt index; set at
    session start, refreshed at compaction
  - `:ranked` — skill names ordered by usage history (from SQLite); used by the
    index to determine the "last used" section
  - `:top_n` — maximum number of ranked skills shown in the index
  - `:names` — skill names declared in TEAM.json `"skills"` array; used by
    `AgentSpec.to_start_opts/2` for tool resolution
  - `:refresh_fn` — returns the live skill pool; called by `load_skill` and
    `list_skills` tools only, never by the system prompt
  - `:index_refresh_fn` — called after compaction to rebuild `pool` and
    `ranked`; returns `{[Skill.t()], [String.t()]}`. `nil` means the index
    stays frozen for the entire session.
  """
  @type t :: %__MODULE__{
          pool: [Skill.t()],
          ranked: [String.t()],
          top_n: pos_integer(),
          names: [String.t()],
          refresh_fn: (-> [Skill.t()]) | nil,
          index_refresh_fn: (-> {[Skill.t()], [String.t()]}) | nil
        }

  defstruct pool: [], ranked: [], top_n: 5, names: [], refresh_fn: nil, index_refresh_fn: nil

  @doc "Return an empty skill index."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Build a `SkillIndex` from agent start opts."
  @spec from_opts(keyword()) :: t()
  def from_opts(opts) do
    %__MODULE__{
      pool: Keyword.get(opts, :skill_pool, []),
      ranked: Keyword.get(opts, :ranked_skill_names, []),
      top_n: Keyword.get(opts, :top_skills, 5),
      names: Keyword.get(opts, :skill_names, []),
      refresh_fn: Keyword.get(opts, :skill_refresh_fn),
      index_refresh_fn: Keyword.get(opts, :skill_index_refresh_fn)
    }
  end

  @doc """
  Refresh `pool` and `ranked` by calling `index_refresh_fn`.

  Called after compaction — the right moment to pick up newly created skills
  and updated usage rankings without busting the prefix cache on normal turns.
  Returns the index unchanged when no `index_refresh_fn` is set.
  """
  @spec refresh(t()) :: t()
  def refresh(%__MODULE__{index_refresh_fn: nil} = index), do: index

  def refresh(%__MODULE__{index_refresh_fn: fun} = index) do
    {pool, ranked} = fun.()
    %{index | pool: pool, ranked: ranked}
  end
end
