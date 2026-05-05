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

    test "bare unrecognised argument returns 1" do
      assert Planck.CLI.Main.run(["fix the auth bug"]) == 1
    end

    test "empty argv returns 0 (web mode default)" do
      assert Planck.CLI.Main.run([]) == 0
    end

    test "--port overrides port and starts web" do
      assert Planck.CLI.Main.run(["--port", "4001"]) == 0
    end

    test "--ip overrides bind address and starts web" do
      assert Planck.CLI.Main.run(["--ip", "127.0.0.1"]) == 0
    end

    test "--host overrides url host and starts web" do
      assert Planck.CLI.Main.run(["--host", "planck.local"]) == 0
    end

    test "--ip with invalid address returns 1" do
      assert Planck.CLI.Main.run(["--ip", "not-an-ip"]) == 1
    end
  end
end
