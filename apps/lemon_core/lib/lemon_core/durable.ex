defmodule LemonCore.Durable do
  @moduledoc """
  Flush helpers for writes that must survive a host crash.

  `sync_file/1` fsyncs one file's contents. `sync_directory/1` makes directory
  entries durable — a rename or a newly created file is only on stable storage
  once its parent directory is synced. The BEAM cannot open a directory, so the
  directory flush runs the platform `sync` utility: `sync DIR` (GNU coreutils
  fsyncs that directory), falling back to a whole-system `sync`.
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
    case System.find_executable("sync") do
      nil ->
        {:error, :sync_unavailable}

      sync ->
        if run(sync, [dir]) == :ok, do: :ok, else: run(sync, [])
    end
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
