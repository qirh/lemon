defmodule LemonCore.Durable do
  @moduledoc """
  Flush helpers for writes that must survive a host crash.

  `sync_file/1` fsyncs one file's contents. `sync_directory/1` makes directory
  entries durable: a rename or a newly created file is only on stable storage
  once its parent directory is synced.

  The BEAM cannot open a directory, so the directory flush runs GNU
  coreutils `sync DIR`, which fsyncs exactly that directory. Support is
  verified, not assumed: the utility must identify itself as GNU coreutils
  and document per-file syncing. macOS is never supported — its `sync`
  ignores arguments and only schedules a system-wide flush, and even a real
  `fsync(2)` there does not reach stable storage without `F_FULLFSYNC`.
  Unsupported hosts get `{:error, :directory_sync_unsupported}`; callers that
  depend on the barrier must fail closed on it.
  """

  @spec sync_file(Path.t()) :: :ok | {:error, term()}
  def sync_file(path) do
    with {:ok, device} <- :file.open(path, [:read, :raw, :binary]) do
      result = :file.sync(device)
      :ok = :file.close(device)
      result
    end
  end

  @spec sync_directory(Path.t()) :: :ok | {:error, term()}
  def sync_directory(dir) do
    case directory_sync_command() do
      {:ok, sync} -> run(sync, [dir])
      :error -> {:error, :directory_sync_unsupported}
    end
  end

  defp directory_sync_command do
    with false <- match?({:unix, :darwin}, :os.type()),
         sync when is_binary(sync) <- System.find_executable("sync"),
         {:ok, version} <- output(sync, ["--version"]),
         true <- version =~ "GNU coreutils",
         {:ok, help} <- output(sync, ["--help"]),
         true <- help =~ "If one or more files are specified, sync only them" do
      {:ok, sync}
    else
      _unsupported -> :error
    end
  end

  defp output(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      _failed -> :error
    end
  rescue
    _error -> :error
  end

  defp run(sync, args) do
    case System.cmd(sync, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, status} -> {:error, {:sync_failed, status}}
    end
  rescue
    error in ErlangError -> {:error, {:sync_failed, Exception.message(error)}}
  end
end
