defmodule Planck.Headless.SessionNameTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Planck.Headless.SessionName

  # --- sanitize/1 ---

  describe "sanitize/1" do
    test "lowercases input" do
      assert {:ok, "hello"} = SessionName.sanitize("HELLO")
    end

    test "converts spaces to hyphens" do
      assert {:ok, "crazy-mango"} = SessionName.sanitize("crazy mango")
    end

    test "converts underscores to hyphens" do
      assert {:ok, "crazy-mango"} = SessionName.sanitize("crazy_mango")
    end

    test "strips non-alphanumeric non-hyphen characters" do
      assert {:ok, "mysession"} = SessionName.sanitize("my!@#$%session")
    end

    test "collapses consecutive hyphens" do
      assert {:ok, "a-b"} = SessionName.sanitize("a---b")
    end

    test "trims leading and trailing hyphens" do
      assert {:ok, "hello"} = SessionName.sanitize("--hello--")
    end

    test "truncates to 64 characters" do
      long = String.duplicate("a", 80)
      assert {:ok, result} = SessionName.sanitize(long)
      assert String.length(result) == 64
    end

    test "returns {:error, :invalid} for empty string" do
      assert {:error, :invalid} = SessionName.sanitize("")
    end

    test "returns {:error, :invalid} when sanitization produces empty string" do
      assert {:error, :invalid} = SessionName.sanitize("!@#$%^")
    end
  end

  # --- generate/1 ---

  describe "generate/1" do
    test "produces an <adjective>-<noun> string", %{tmp_dir: dir} do
      assert {:ok, name} = SessionName.generate(dir)
      assert name =~ ~r/^[a-z]+-[a-z]+$/
    end

    test "generated name does not conflict with existing files", %{tmp_dir: dir} do
      {:ok, name1} = SessionName.generate(dir)
      File.touch!(Path.join(dir, "abc123_#{name1}.db"))

      {:ok, name2} = SessionName.generate(dir)
      assert name2 != name1
    end

    test "returns :exhausted if all retries collide", %{tmp_dir: dir} do
      # Generate with 0 retries always exhausts immediately.
      assert {:error, :exhausted} = SessionName.generate(dir, 0)
    end
  end
end
