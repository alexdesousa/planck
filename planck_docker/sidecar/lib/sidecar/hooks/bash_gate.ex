defmodule Sidecar.Hooks.BashGate do
  @moduledoc """
  `ToolStart` gate over the `bash` tool, driven by an RLCD model.

  Non-`bash` tools proceed immediately with zero RLCD cost. For `bash`,
  the command and cwd are evaluated through the upstream `BASH_QUESTIONS`
  block (verbatim port of `disler/ten-levels-of-jev` L6 `bash-gate.ts`):
  an `effect` choice (`read_only` / `reversible` / `irreversible`) plus a
  `destructive_intent` boolean. Anything the model flags as irreversible
  or destructive parks for human approval — model verdicts never deny;
  the human approves or denies in the approval modal.

  Reasons are written for the human reading the modal (short, with the
  model's confidence attached) and translated sidecar-side via
  `Sidecar.Gettext` — the UI locale is pushed to the sidecar on every
  request, so the stored reason is already in the user's language when
  the modal renders it.

  The RLCD call goes through `Planck.Headless.ask/2` over distributed
  Erlang — the sidecar holds no model credentials itself. Only a missing
  RLCD model (`:no_rlcd_model`, i.e. no gate configured) proceeds to
  `:ok`. Any other failure (no headless node, RPC failure, malformed
  answers, raised exception) denies loudly with a warning, so `bash`
  never runs unevaluated when a gate is configured. This deliberately
  diverges from the `ToolStart` RPC wrapper's fail-open rule: a gate
  transport failure is itself a safety signal.
  """
  use Planck.Agent.Hooks.ToolStart
  use Gettext, backend: Sidecar.Gettext

  require Logger

  @bash_questions %{
    "effect" => %{
      "type" => "choice",
      "instructions" => "What does running `command` in `cwd` do to the machine?",
      "criteria" => %{
        "read_only" =>
          "Lists, reads, searches, tests, builds into a scratch directory; nothing durable changes",
        "reversible" =>
          "Changes files or state that git or a reinstall can restore: edits, installs, generated output",
        "irreversible" =>
          "Deletes or overwrites things with no way back: removing directories, force pushing, dropping data, rewriting history"
      }
    },
    "destructive_intent" => %{
      "type" => "boolean",
      "instructions" =>
        "Does `command` aim to remove or wipe something rather than build or inspect?",
      "criteria" => %{
        "true" => "rm -rf, drop, purge, force, reset --hard, truncate, overwriting real data",
        "false" => "Reading, listing, testing, installing, generating, or editing in place"
      }
    }
  }

  @typedoc false
  @type evaluation :: %{eval: boolean(), confidence: float()}

  @typedoc false
  @type answers :: %{
          irreversible: evaluation(),
          destructive: evaluation()
        }

  @doc false
  def bash_questions, do: @bash_questions

  @impl true
  def proceed_timeout, do: 15_000

  @impl true
  def proceed(agent_id, command_name, args)

  def proceed(_agent_id, "bash", args) when is_map(args) do
    command = Map.get(args, "command", "")
    cwd = Map.get(args, "cwd", Sidecar.Config.workspace_dir!())

    case evaluate(command, cwd) do
      {:ok, answers} ->
        gate_bash(answers)

      {:error, :no_rlcd_model} ->
        # No bash gate configured
        :ok

      {:error, :no_headless_node} ->
        reason = "[Sidecar.Hooks.BashGate] No headless node connected."
        Logger.warning(reason)
        {:deny, "headless node is disconnected"}

      {:error, _reason} ->
        reason = "[Sidecar.Hooks.BashGate] Failure when evaluating bash gate."
        Logger.warning(reason)
        {:deny, "something happened during the evaluation"}
    end
  rescue
    e ->
      reason = "[Sidecar.Hooks.BashGate] gate raised (#{Exception.message(e)}), failing closed"
      Logger.warning(reason)
      {:deny, "bash gate raised an exception (#{Exception.message(e)})"}
  end

  def proceed(_agent_id, _tool_name, _args) do
    :ok
  end

  @doc """
  Map RLCD answers onto a gate verdict. Pure — port of upstream `gateBash/2`
  with the block/allow outcome mapped onto park/allow: any blocked signal
  parks the call for human approval, since only the human denies.
  """
  @spec gate_bash(answers()) ::
          :ok
          | {:await_approval, String.t()}
  def gate_bash(answers)

  def gate_bash(%{irreversible: %{eval: true}, destructive: %{eval: true}} = answers) do
    reason =
      pgettext(
        "bash gate",
        "Likely irreversible (%{irreversible}) and destructive (%{destructive}): nothing would restore what this removes or overwrites",
        irreversible: format(answers.irreversible.confidence),
        destructive: format(answers.destructive.confidence)
      )

    {:await_approval, reason}
  end

  def gate_bash(%{irreversible: %{eval: true, confidence: confidence}})
      when is_float(confidence) do
    reason =
      pgettext(
        "bash gate",
        "Likely irreversible (%{confidence}): nothing would restore what this removes or overwrites",
        confidence: format(confidence)
      )

    {:await_approval, reason}
  end

  def gate_bash(%{destructive: %{eval: true, confidence: confidence}})
      when is_float(confidence) do
    reason =
      pgettext(
        "bash gate",
        "Looks destructive (%{confidence}): this command aims to wipe something",
        confidence: format(confidence)
      )

    {:await_approval, reason}
  end

  def gate_bash(_answers) do
    :ok
  end

  @spec evaluate(String.t(), String.t()) ::
          {:ok, answers()}
          | {:error, :no_headless_node}
          | {:error, :no_rlcd_model}
          | {:error, {:badrpc, term()}}
          | {:error, term()}
  defp evaluate(command, cwd)

  defp evaluate(command, cwd)
       when is_binary(command) and is_binary(cwd) do
    state = %{"command" => command, "cwd" => cwd}
    timeout = proceed_timeout()
    params = [state, @bash_questions]

    with {:ok, node} <- headless_node(),
         {:ok, answers} <- :rpc.call(node, Planck.Headless, :ask, params, timeout) do
      {:ok, evaluation(answers)}
    else
      {:badrpc, reason} -> {:error, {:badrpc, reason}}
      {:error, _} = error -> error
    end
  end

  @spec headless_node() :: {:ok, atom()} | {:error, :no_headless_node}
  defp headless_node do
    case System.get_env("PLANCK_HEADLESS_NODE") do
      empty when empty in [nil, ""] ->
        {:error, :no_headless_node}

      name when is_binary(name) ->
        {:ok, String.to_atom(name)}
    end
  end

  @spec evaluation(map()) :: answers()
  defp evaluation(answers)

  defp evaluation(answers) when is_map(answers) do
    {effect, confidence} = effect_answer(answers)
    irreversible_threshold = Sidecar.Config.bash_gate_irreversible_threshold!()
    irreversible? = effect == :irreversible and confidence >= irreversible_threshold

    destructive = destructive_answer(answers)
    destructive_threshold = Sidecar.Config.bash_gate_destructive_threshold!()
    destructive? = destructive >= destructive_threshold

    %{
      irreversible: %{eval: irreversible?, confidence: confidence},
      destructive: %{eval: destructive?, confidence: destructive}
    }
  end

  @spec effect_answer(map()) ::
          {:read_only, float()}
          | {:reversible, float()}
          | {:irreversible, float()}
          | {:unknown, float()}
  defp effect_answer(answers)

  defp effect_answer(%{"effect" => %{"choice" => choice, "confidence" => confidence}})
       when choice in ["read_only", "reversible", "irreversible"] and
              is_number(confidence) do
    {String.to_existing_atom(choice), confidence * 1.0}
  end

  defp effect_answer(_) do
    {:unknown, 0.0}
  end

  @spec destructive_answer(map()) :: float()
  defp destructive_answer(answers)

  defp destructive_answer(%{"destructive_intent" => %{"probability" => p}})
       when is_number(p) do
    p * 1.0
  end

  defp destructive_answer(%{"destructive_intent" => %{"noul" => p}})
       when is_number(p) do
    p * 1.0
  end

  defp destructive_answer(_) do
    0.0
  end

  @spec format(float()) :: String.t()
  defp format(number)

  defp format(number) when is_float(number) do
    :erlang.float_to_binary(number, decimals: 2)
  end
end
