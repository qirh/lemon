defmodule LemonControlPlane.Methods.SessionsRewind do
  @moduledoc "Previews and confirms native session rewinds."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.AgentRuntime
  alias LemonControlPlane.Methods.NativeSessions

  @impl true
  def name, do: "sessions.rewind"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    with {:ok, key, cwd} <- NativeSessions.target(params),
         {:ok, entry_id} <- NativeSessions.string(params, "entryId", 256),
         {:ok, restore_files} <- NativeSessions.boolean(params, "restoreFiles", false),
         {:ok, dry_run} <- NativeSessions.boolean(params, "dryRun", true),
         {:ok, token} <- confirmation(params, dry_run) do
      opts = [restore_files: restore_files, dry_run: dry_run, confirmation_token: token]

      case AgentRuntime.call(:session_rewind, [key, cwd, entry_id, opts], {:error, :unavailable}) do
        {:ok, result} when is_map(result) ->
          fields =
            if dry_run,
              do:
                ~w(confirmationToken prompt discardedMessages restorePaths unrestorableTools entryId sessionId),
              else: ~w(prompt leafId restoredPaths entryId sessionId)

          {:ok, Map.take(result, fields)}

        {:error, reason} ->
          NativeSessions.failure(reason)

        _ ->
          NativeSessions.failure(:invalid_response)
      end
    end
  end

  defp confirmation(params, dry_run) do
    if Map.has_key?(params, "confirmationToken") do
      NativeSessions.string(params, "confirmationToken", 256)
    else
      if dry_run, do: {:ok, nil}, else: NativeSessions.failure(:confirmation_required)
    end
  end
end
