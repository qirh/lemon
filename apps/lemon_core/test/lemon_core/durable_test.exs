defmodule LemonCore.DurableTest do
  use ExUnit.Case, async: true

  alias LemonCore.Durable

  @moduletag :tmp_dir

  test "a directory flush is claimed only where it is synchronous", %{tmp_dir: dir} do
    result = Durable.sync_directory(dir)

    cond do
      match?({:unix, :darwin}, :os.type()) ->
        # macOS `sync` ignores its arguments and only schedules a flush.
        assert result == {:error, :directory_sync_unsupported}

      gnu_sync?() ->
        assert result == :ok

      true ->
        assert result == {:error, :directory_sync_unsupported}
    end
  end

  test "a file flush syncs an existing file", %{tmp_dir: dir} do
    path = Path.join(dir, "data")
    File.write!(path, "contents")
    assert Durable.sync_file(path) == :ok
    assert {:error, :enoent} = Durable.sync_file(Path.join(dir, "missing"))
  end

  defp gnu_sync? do
    case System.find_executable("sync") do
      nil -> false
      sync -> match?({"sync (GNU coreutils)" <> _, 0}, System.cmd(sync, ["--version"]))
    end
  end
end
