defmodule Planck.CLI.MainTest do
  use ExUnit.Case, async: true

  # run/1 returns an exit code — no System.halt in tests.

  describe "run/1 exit codes" do
    test "--version returns 0" do
      assert Planck.CLI.Main.run(["--version"]) == 0
    end

    test "--help returns 0" do
      assert Planck.CLI.Main.run(["--help"]) == 0
    end

    test "-h returns 0" do
      assert Planck.CLI.Main.run(["-h"]) == 0
    end

    test "unknown flag returns 1" do
      assert Planck.CLI.Main.run(["--unknown-flag"]) == 1
    end

    test "empty argv returns 0 (tui mode)" do
      assert Planck.CLI.Main.run([]) == 0
    end

    test "--tui returns 0" do
      assert Planck.CLI.Main.run(["--tui"]) == 0
    end

    test "--web returns 0" do
      assert Planck.CLI.Main.run(["--web"]) == 0
    end

    test "--sidecar returns 0" do
      assert Planck.CLI.Main.run(["--sidecar"]) == 0
    end

    test "sidecar subcommand returns 0" do
      assert Planck.CLI.Main.run(["sidecar"]) == 0
    end

    test "bare prompt returns 0" do
      assert Planck.CLI.Main.run(["fix the auth bug"]) == 0
    end
  end
end
