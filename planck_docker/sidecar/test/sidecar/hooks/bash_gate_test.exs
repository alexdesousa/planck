defmodule Sidecar.Hooks.BashGateTest do
  use ExUnit.Case, async: false

  alias Sidecar.Hooks.BashGate

  defp verdict(irreversible?, iconf, destructive?, dconf) do
    %{
      irreversible: %{eval: irreversible?, confidence: iconf * 1.0},
      destructive: %{eval: destructive?, confidence: dconf * 1.0}
    }
  end

  describe inspect(&BashGate.gate_bash/1) do
    test "read-only command is allowed" do
      assert :ok = BashGate.gate_bash(verdict(false, 1.0, false, 0.01))
    end

    test "reversible command below destructive threshold is allowed" do
      assert :ok = BashGate.gate_bash(verdict(false, 0.9, false, 0.2))
    end

    test "irreversible with destructive intent parks for approval" do
      assert {:await_approval, reason} =
               BashGate.gate_bash(verdict(true, 0.99, true, 0.85))

      assert reason =~ "0.99"
      assert reason =~ "0.85"
    end

    test "extreme destructive intent parks whatever the effect pick" do
      assert {:await_approval, reason} =
               BashGate.gate_bash(verdict(false, 0.9, true, 0.95))

      assert reason =~ "0.95"
    end

    test "single-signal irreversible parks for approval" do
      assert {:await_approval, reason} =
               BashGate.gate_bash(verdict(true, 0.7, false, 0.2))

      assert reason =~ "0.70"
    end

    test "single-signal destructive parks for approval" do
      assert {:await_approval, reason} =
               BashGate.gate_bash(verdict(false, 0.5, true, 0.75))

      assert reason =~ "0.75"
    end

    test "low-confidence reversible parks a human (upstream rm -rf node_modules vector)" do
      assert {:await_approval, _} = BashGate.gate_bash(verdict(false, 0.35, true, 0.75))
    end

    test "threshold boundaries park" do
      assert {:await_approval, _} = BashGate.gate_bash(verdict(true, 0.6, false, 0.0))

      assert {:await_approval, _} = BashGate.gate_bash(verdict(false, 1.0, true, 0.7))
    end

    test "the gate never denies — only the human does" do
      for answers <- [
            verdict(true, 0.99, true, 0.99),
            verdict(false, 0.9, true, 0.99),
            verdict(true, 0.99, false, 0.0)
          ] do
        result = BashGate.gate_bash(answers)
        assert match?(:ok, result) or match?({:await_approval, _}, result)
      end
    end

    test "malformed answers fail open" do
      assert :ok = BashGate.gate_bash(%{})
      assert :ok = BashGate.gate_bash(%{"effect" => %{}})
    end

    test "thresholding lives in evaluation/1 — the gate only maps eval flags" do
      assert :ok = BashGate.gate_bash(verdict(false, 0.7, false, 0.2))
    end
  end

  describe inspect(&BashGate.proceed/3) do
    test "non-bash tools bypass with zero RLCD cost" do
      assert :ok = BashGate.proceed("agent-1", "write", %{"path" => "x", "content" => "y"})
      assert :ok = BashGate.proceed("agent-1", "read", %{"path" => "x"})
    end

    test "bash denies when no headless node is configured" do
      System.delete_env("PLANCK_HEADLESS_NODE")

      assert {:deny, _} = BashGate.proceed("agent-1", "bash", %{"command" => "rm -rf /"})
    end

    test "bash denies when the headless node is unreachable" do
      System.put_env("PLANCK_HEADLESS_NODE", "planck_headless_nowhere@nohost")

      assert {:deny, _} = BashGate.proceed("agent-1", "bash", %{"command" => "rm -rf /"})
    after
      System.delete_env("PLANCK_HEADLESS_NODE")
    end
  end

  describe inspect(&BashGate.bash_questions/0) do
    test "matches the upstream BASH_QUESTIONS shape" do
      questions = BashGate.bash_questions()

      assert %{
               "type" => "choice",
               "criteria" => %{"read_only" => _, "reversible" => _, "irreversible" => _}
             } =
               questions["effect"]

      assert %{"type" => "boolean", "criteria" => %{"true" => _, "false" => _}} =
               questions["destructive_intent"]
    end
  end
end
