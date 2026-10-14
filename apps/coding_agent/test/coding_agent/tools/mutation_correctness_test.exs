defmodule CodingAgent.Tools.MutationCorrectnessTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.{Edit, FileValidation, Patch, Write}
  alias LemonAgent.Types.AgentToolResult

  @moduletag :tmp_dir

  test "edit returns an ordered diff with contiguous context", %{tmp_dir: cwd} do
    File.write!(Path.join(cwd, "ordered.txt"), "alpha\nold value\nomega\n")

    assert %AgentToolResult{trust: :untrusted, details: %{diff: diff}} =
             edit(cwd, "ordered.txt", "old value", "new value")

    assert diff == " 1\talpha\n-2\told value\n+2\tnew value\n 3\tomega"
  end

  test "unprefixed Add File content cannot silently create an empty file", %{tmp_dir: cwd} do
    patch = "*** Begin Patch\n*** Add File: invalid.txt\nunprefixed content\n*** End Patch"
    assert {:error, _} = Patch.execute("add", %{"patch_text" => patch}, nil, nil, cwd, [])
    refute File.exists?(Path.join(cwd, "invalid.txt"))
  end

  test "patch supplies complete bounded per-file snapshots including deletion", %{tmp_dir: cwd} do
    path = Path.join(cwd, "snapshot.txt")
    File.write!(path, "old\n")
    patch = "*** Begin Patch\n*** Update File: snapshot.txt\n@@\n-old\n+new\n*** End Patch"
    result = Patch.execute("patch", %{"patch_text" => patch}, nil, nil, cwd, [])
    assert [%{path: ^path, oldText: "old\n", newText: "new\n"}] = result.details.perFileResults

    result =
      Patch.execute(
        "delete",
        %{"patch_text" => "*** Begin Patch\n*** Delete File: snapshot.txt\n*** End Patch"},
        nil,
        nil,
        cwd,
        []
      )

    assert [%{path: ^path, oldText: "new\n", newText: nil}] = result.details.perFileResults
  end

  test "exact overlapping edit locations are ambiguous", %{tmp_dir: cwd} do
    path = Path.join(cwd, "overlap.txt")
    File.write!(path, "aaa")
    assert {:error, message} = edit(cwd, "overlap.txt", "aa", "b")
    assert message =~ "Found 2 occurrences"
    assert File.read!(path) == "aaa"
  end

  test "normalized overlapping edit locations are ambiguous", %{tmp_dir: cwd} do
    path = Path.join(cwd, "quotes.txt")
    File.write!(path, "“““")
    assert {:error, message} = edit(cwd, "quotes.txt", "\"\"", "b")
    assert message =~ "Found 2 occurrences"
    assert File.read!(path) == "“““"
  end

  test "edit rejects non-string arguments without raising", %{tmp_dir: cwd} do
    for key <- ["path", "old_text", "new_text"] do
      params = Map.put(%{"path" => "file.txt", "old_text" => "a", "new_text" => "b"}, key, 42)
      assert {:error, message} = Edit.execute("test", params, nil, nil, cwd, [])
      assert message == "#{key} must be a string"
    end
  end

  test "text mutation rejects binary sources without altering any patch target", %{tmp_dir: cwd} do
    for bytes <- [<<255, 10, 97>>, <<97, 0, 98>>] do
      path = Path.join(cwd, "binary.txt")
      File.write!(path, bytes)
      assert {:error, message} = edit(cwd, "binary.txt", "a", "b")
      assert message =~ "binary data"

      patch = "*** Add File: untouched.txt\n+new\n*** Update File: binary.txt\n@@\n-a\n+b\n"

      assert {:error, message} =
               Patch.execute("test", %{"patch_text" => patch}, nil, nil, cwd, [])

      assert message =~ "binary data"
      refute File.exists?(Path.join(cwd, "untouched.txt"))
      assert File.read!(path) == bytes
    end
  end

  test "write and patch reject binary input before creating files", %{tmp_dir: cwd} do
    for bytes <- [<<255>>, <<0>>] do
      assert {:error, message} =
               Write.execute(
                 "test",
                 %{"path" => "new.txt", "content" => bytes},
                 nil,
                 nil,
                 cwd,
                 []
               )

      assert message =~ "binary data"

      assert {:error, message} =
               Patch.execute(
                 "test",
                 %{"patch_text" => "*** Add File: new.txt\n+" <> bytes},
                 nil,
                 nil,
                 cwd,
                 []
               )

      assert message =~ "binary data"
      refute File.exists?(Path.join(cwd, "new.txt"))
    end
  end

  test "ambiguous patch context reports locations and preserves all targets", %{tmp_dir: cwd} do
    path = Path.join(cwd, "repeat.txt")
    File.write!(path, "same\nseparator\nsame\n")

    patch =
      "*** Add File: untouched.txt\n+new\n*** Update File: repeat.txt\n@@\n-same\n+changed\n"

    assert {:error, message} = Patch.execute("test", %{"patch_text" => patch}, nil, nil, cwd, [])
    assert message =~ "Ambiguous patch hunk"
    assert message =~ "lines 1, 3"
    assert File.read!(path) == "same\nseparator\nsame\n"
    refute File.exists?(Path.join(cwd, "untouched.txt"))
  end

  test "edit refuses target and parent symlinks", %{tmp_dir: cwd} do
    path = Path.join(cwd, "real.txt")
    File.write!(path, "original")
    File.ln_s!(path, Path.join(cwd, "link.txt"))
    File.ln_s!(cwd, Path.join(cwd, "linked_dir"))

    for target <- ["link.txt", "linked_dir/real.txt"] do
      assert {:error, message} = edit(cwd, target, "original", "changed")
      assert message =~ "symlink"
      assert File.read!(path) == "original"
    end
  end

  test "small edit and write results contain complete bounded snapshots", %{tmp_dir: cwd} do
    path = Path.join(cwd, "snapshot.txt")

    assert %AgentToolResult{details: created} =
             Write.execute(
               "test",
               %{"path" => "snapshot.txt", "content" => "before"},
               nil,
               nil,
               cwd,
               []
             )

    assert created.path == path
    assert created.oldText == nil
    assert created.newText == "before"
    assert %AgentToolResult{details: edited} = edit(cwd, "snapshot.txt", "before", "after")
    assert edited.path == path
    assert edited.oldText == "before"
    assert edited.newText == "after"

    assert %AgentToolResult{details: written} =
             Write.execute(
               "test",
               %{"path" => "snapshot.txt", "content" => "final"},
               nil,
               nil,
               cwd,
               []
             )

    assert written.oldText == "after"
    assert written.newText == "final"
  end

  test "snapshots omit both texts when either exceeds the bound" do
    small = String.duplicate("a", 16_384)
    large = small <> "b"

    assert %{oldText: ^small, newText: ^small} =
             FileValidation.put_text_snapshots(%{}, "/file", small, small)

    for {old, new} <- [{large, small}, {small, large}, {:unavailable, small}] do
      details = FileValidation.put_text_snapshots(%{}, "/file", old, new)
      assert details == %{path: "/file"}
    end
  end

  defp edit(cwd, path, old, new) do
    Edit.execute(
      "test",
      %{"path" => path, "old_text" => old, "new_text" => new},
      nil,
      nil,
      cwd,
      []
    )
  end
end
