defmodule LemonCore.Update.Daemon do
  @moduledoc """
  Restarts only the managed daemon observed before an update transaction.

  Ownership and process identity are verified by the packaged launcher's private
  `__update-daemon` hook. A stopped snapshot never starts a daemon. Restart runs
  the selected version's absolute launcher, with inherited release-selection
  variables removed, only after the pointer and durable receipt are committed.
  """

  alias LemonCore.Update.ManagedInstall

  @spec snapshot(String.t(), keyword()) :: {:ok, :stopped | String.t()} | {:error, atom()}
  def snapshot(version, opts) do
    case command(ManagedInstall.launcher(version, opts), ["__update-daemon", "snapshot"], opts) do
      {:ok, "stopped"} ->
        {:ok, :stopped}

      {:ok, token} ->
        if Regex.match?(~r/\A[a-f0-9]{64}\z/, token),
          do: {:ok, token},
          else: {:error, :daemon_ownership_unverified}

      :error ->
        {:error, :daemon_ownership_unverified}
    end
  end

  @spec restart(map(), :stopped | String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, {:daemon_restart_failed, map()}}
  def restart(result, :stopped, _previous, _target, _opts) do
    {:ok, Map.merge(result, %{restart_required: false, restart: "not_running"})}
  end

  def restart(result, token, previous, target, opts) do
    launcher = ManagedInstall.launcher(target, opts)
    previous_root = previous |> ManagedInstall.launcher(opts) |> Path.dirname() |> Path.dirname()

    case command(launcher, ["__update-daemon", "restart", token, previous_root], opts) do
      {:ok, _output} ->
        {:ok, Map.merge(result, %{restart_required: false, restart: "restarted"})}

      :error ->
        {:error,
         {:daemon_restart_failed, Map.merge(result, %{restart_required: true, restart: "failed"})}}
    end
  end

  defp command(launcher, args, opts) do
    task =
      Task.async(fn ->
        try do
          System.cmd(launcher, args,
            env: Keyword.get_lazy(opts, :release_command_env, &ManagedInstall.command_env/0),
            stderr_to_stdout: true
          )
        rescue
          _ -> {"", 1}
        end
      end)

    case Task.yield(task, 180_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> {:ok, String.trim(output)}
      _ -> :error
    end
  end
end
