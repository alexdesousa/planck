defmodule Sidecar.SkillReflectorTest do
  use ExUnit.Case, async: true

  alias Sidecar.SkillReflector

  describe "reflect_threshold/0" do
    test "defaults to 5" do
      assert SkillReflector.reflect_threshold() == 5
    end
  end

  describe "reflect_timeout/0" do
    test "has a positive default" do
      assert SkillReflector.reflect_timeout() > 0
    end
  end

  describe "reflect/2" do
    test "returns :ok even when parent agent does not exist" do
      assert :ok = SkillReflector.reflect("nonexistent-agent", [])
    end

    test "returns :ok with an empty turn_messages list" do
      assert :ok = SkillReflector.reflect("any-agent-id", [])
    end
  end
end
