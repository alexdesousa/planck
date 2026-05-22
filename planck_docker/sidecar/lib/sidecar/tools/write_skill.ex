defmodule Sidecar.Tools.WriteSkill do
  @moduledoc """
  Writes or updates a skill file in the workspace skills directory.

  Creates `.planck/skills/<name>/SKILL.md` with `creator: agent` frontmatter.
  On update, preserves all existing frontmatter keys (so user-set
  `always_present: true` survives across rewrites) while replacing the
  description and body.

  Returns `{action, name}` where action is `"create_skill"` or `"update_skill"`,
  so the caller can inject the appropriate synthetic tool result into the parent
  agent's history.
  """

  @doc "Returns the `write_skill` tool definition."
  @spec tool() :: Planck.Agent.Tool.t()
  def tool do
    Planck.Agent.Tool.new(
      name: "write_skill",
      description:
        "Write or update a reusable skill in the workspace. " <>
          "Call list_skills first to check whether a skill with the same purpose already exists — " <>
          "update it instead of creating a duplicate. " <>
          "Structure the content with clear sections: When to Use, Quick Reference, " <>
          "Procedure (step-by-step), Pitfalls, and Verification.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" =>
              "Kebab-case skill name, e.g. \"git-workflow\" or \"elixir-test-patterns\"."
          },
          "description" => %{
            "type" => "string",
            "description" => "One-line description shown in the skill index (≤ 120 chars)."
          },
          "content" => %{
            "type" => "string",
            "description" =>
              "Full skill body (Markdown). Sections: When to Use, Quick Reference, " <>
                "Procedure, Pitfalls, Verification."
          }
        },
        "required" => ["name", "description", "content"]
      },
      execute_fn: fn _agent_id,
                     _id,
                     %{"name" => name, "description" => desc, "content" => body} ->
        write(name, desc, body)
      end
    )
  end

  @doc """
  Write the skill and return `{:ok, "action:name"}` where action is
  `"create_skill"` or `"update_skill"`. The colon-separated format lets the
  SkillReflector parse the action and name from the tool result string.
  """
  @spec write(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def write(name, description, content) do
    workspace = Sidecar.Config.workspace_dir!()
    skill_dir = Path.join([workspace, ".planck", "skills", name])
    skill_file = Path.join(skill_dir, "SKILL.md")

    action = if File.exists?(skill_file), do: "update_skill", else: "create_skill"

    frontmatter =
      case action do
        "update_skill" -> updated_frontmatter(skill_file, name, description)
        "create_skill" -> default_frontmatter(name, description)
      end

    file_content = frontmatter <> "\n\n" <> String.trim(content) <> "\n"

    with :ok <- File.mkdir_p(skill_dir),
         :ok <- File.write(skill_file, file_content) do
      {:ok, "#{action}:#{name}"}
    else
      {:error, reason} ->
        {:error, "Failed to write skill #{name}: #{:file.format_error(reason)}"}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec default_frontmatter(String.t(), String.t()) :: String.t()
  defp default_frontmatter(name, description) do
    build_frontmatter(name, description, false)
  end

  @spec updated_frontmatter(Path.t(), String.t(), String.t()) :: String.t()
  defp updated_frontmatter(skill_file, name, description) do
    build_frontmatter(name, description, read_always_present(skill_file))
  end

  @spec build_frontmatter(String.t(), String.t(), boolean()) :: String.t()
  defp build_frontmatter(name, description, always_present) do
    fields = [
      {"name", name},
      {"description", description},
      {"always_present", always_present},
      {"planck_version", nil},
      {"creator", "agent"}
    ]

    lines = Enum.map_join(fields, "\n", fn {k, v} -> "#{k}: #{yaml_scalar(v)}" end)
    "---\n#{lines}\n---"
  end

  # Encodes a scalar value using Ymlr for correct quoting, with a nil override
  # since Ymlr renders nil as the string "nil" rather than the YAML null keyword.
  @spec yaml_scalar(term()) :: String.t()
  defp yaml_scalar(nil), do: "null"
  defp yaml_scalar(value), do: Ymlr.Encode.to_s!(value)

  @frontmatter_re ~r/\A---\n(.*?)\n---/s

  @spec read_always_present(Path.t()) :: boolean()
  defp read_always_present(skill_file) do
    with {:ok, content} <- File.read(skill_file),
         [frontmatter] <- Regex.run(@frontmatter_re, content, capture: :all_but_first) do
      parse_always_present(frontmatter)
    else
      _ -> false
    end
  end

  @spec parse_always_present(String.t()) :: boolean()
  defp parse_always_present(frontmatter) do
    Application.ensure_all_started(:yamerl)

    case :yamerl_constr.string(String.to_charlist(frontmatter)) do
      [[_ | _] = pairs] ->
        Enum.any?(pairs, fn {k, v} -> k == ~c"always_present" and v == true end)

      _ ->
        false
    end
  end
end
