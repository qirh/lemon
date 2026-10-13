defmodule CodingAgent.ControlPlaneProvider do
  @moduledoc """
  Exposes this agent's internals to the control plane's ops methods.

  The control plane reports on tasks, sessions, extensions, the run graph and
  progress, but must not depend on this app; it calls whatever provider is
  registered (see `LemonControlPlane.AgentRuntime`). `CodingAgent.Application`
  registers this module at boot.

  Each function is a thin adapter over the agent's own modules. Shapes match
  what the control plane used to read directly, so method payloads are
  unchanged.

  The `LemonControlPlane.AgentRuntime.Provider` behaviour is deliberately *not*
  declared here: this app must stay extractable without the reference runtime,
  so it carries no compile-time reference to it. `control_plane_provider_test`
  checks this module against the behaviour's callback list at runtime instead.
  """

  def list_tasks, do: CodingAgent.TaskStore.list(:all)

  def get_task(task_id), do: CodingAgent.TaskStore.get(task_id)

  def todo_progress(session_key) do
    progress = CodingAgent.Tools.TodoStore.get_progress(session_key)
    actionable_count = session_key |> CodingAgent.Tools.TodoStore.get_actionable() |> length()
    Map.put(progress, :actionable_count, actionable_count)
  end

  def feature_progress(cwd), do: CodingAgent.Tools.FeatureRequirements.get_progress(cwd)

  def compact_session(session_key, opts) do
    case live_session(session_key) do
      nil ->
        with cwd when is_binary(cwd) <- Keyword.get(opts, :cwd),
             {:ok, path} <- native_session_path(session_key, cwd),
             {:ok, pid} <- CodingAgent.Session.start_link(cwd: cwd, session_file: path) do
          try do
            CodingAgent.Session.compact(pid, opts)
          after
            GenServer.stop(pid, :normal)
          end
        else
          nil -> {:error, :session_not_found}
          {:error, _} = error -> error
        end

      pid ->
        CodingAgent.Session.compact(pid, opts)
    end
  end

  @doc "Return durable native branch entries for history replay through the runtime seam."
  def session_history(session_key, cwd) do
    with {:ok, path} <- native_session_path(session_key, cwd),
         {:ok, session} <- CodingAgent.SessionManager.load_from_file(path) do
      {:ok, CodingAgent.SessionManager.get_branch(session)}
    end
  end

  def session_tree(session_key, cwd, opts) do
    case live_session(session_key) do
      nil ->
        with {:ok, path} <- native_session_path(session_key, cwd),
             {:ok, session} <- CodingAgent.SessionManager.load_from_file(path) do
          {:ok, CodingAgent.Session.Rewind.tree(session, opts)}
        end

      pid ->
        CodingAgent.Session.tree(pid, opts)
    end
  end

  def session_rewind(session_key, cwd, entry_id, opts) do
    case live_session(session_key) do
      nil ->
        with {:ok, path} <- native_session_path(session_key, cwd) do
          :global.trans({{__MODULE__, path}, self()}, fn ->
            with {:ok, session} <- CodingAgent.SessionManager.load_from_file(path),
                 {:ok, result, _session} <-
                   CodingAgent.Session.Rewind.run(%{session | file_path: path}, entry_id, opts) do
              {:ok, result}
            end
          end)
        end

      pid ->
        CodingAgent.Session.rewind(pid, entry_id, opts)
    end
  end

  @doc "Fork native history and bind the independent resume token to a new logical session."
  def session_fork(source_key, cwd, destination_key) do
    with :ok <- ensure_idle(source_key),
         nil <- LemonCore.ChatStateStore.get(destination_key),
         {:ok, source_path} <- native_session_path(source_key, cwd) do
      id = LemonCore.Id.uuid()
      destination_path = CodingAgent.Session.Presentation.session_file_path(id, cwd)

      with {:ok, _session} <-
             CodingAgent.SessionManager.fork_file(source_path, destination_path, id: id) do
        LemonCore.ChatStateStore.put(destination_key, %LemonCore.ChatState{
          last_engine: "lemon",
          last_resume_token: id,
          updated_at: System.system_time(:millisecond)
        })
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :destination_exists}
    end
  end

  def tool_policy(profile), do: CodingAgent.ToolPolicy.from_profile(profile)

  @doc "Resolve canonical persona instructions and policy without exposing product dependencies."
  def resolve_subagent(cwd, id) do
    case CodingAgent.Subagents.fetch(cwd, id) do
      {:ok, persona} ->
        {:ok,
         persona
         |> Map.take([:prompt, :model, :role])
         |> Map.put(:tool_policy, CodingAgent.Subagents.tool_policy(persona, nil))}

      {:error, _reason} ->
        {:error, :persona_unavailable}
    end
  end

  defp ensure_idle(session_key) do
    case live_session(session_key) do
      nil ->
        :ok

      pid ->
        if CodingAgent.Session.get_state(pid).is_streaming, do: {:error, :busy}, else: :ok
    end
  end

  defp native_session_path(session_key, cwd) do
    case LemonCore.ChatStateStore.get(session_key) do
      state when is_map(state) ->
        engine = Map.get(state, :last_engine) || Map.get(state, "last_engine")
        token = Map.get(state, :last_resume_token) || Map.get(state, "last_resume_token")

        if engine == "lemon" and is_binary(token) and token != "" and
             Path.basename(token) == token do
          {:ok, CodingAgent.Session.Presentation.session_file_path(token, cwd)}
        else
          {:error, :unsupported_session}
        end

      nil ->
        {:error, :session_not_found}

      {:error, _} = error ->
        error
    end
  end

  defp live_session(session_key) do
    if Process.whereis(CodingAgent.SessionRegistry) do
      case Registry.lookup(CodingAgent.SessionRegistry, session_key) do
        [{pid, _}] ->
          pid

        [] ->
          CodingAgent.SessionRegistry
          |> Registry.select([{{:_, :"$1", %{session_key: session_key}}, [], [:"$1"]}])
          |> List.first()
      end
    end
  end

  def background_start(prompt, opts), do: CodingAgent.BackgroundRun.start(prompt, opts)

  def background_list(opts) do
    opts
    |> normalize_background_list_opts()
    |> CodingAgent.BackgroundRun.list()
  end

  def background_list_scoped(session_key, opts) do
    opts
    |> normalize_background_list_opts()
    |> then(&CodingAgent.BackgroundRun.list_scoped(session_key, &1))
  end

  def background_status(id), do: CodingAgent.BackgroundRun.status(id)

  def background_status_scoped(id, session_key),
    do: CodingAgent.BackgroundRun.status_scoped(id, session_key)

  def background_result(id), do: CodingAgent.BackgroundRun.result(id)

  def background_result_scoped(id, session_key),
    do: CodingAgent.BackgroundRun.result_scoped(id, session_key)

  def background_cancel(id), do: CodingAgent.BackgroundRun.cancel(id)

  def background_cancel_scoped(id, session_key),
    do: CodingAgent.BackgroundRun.cancel_scoped(id, session_key)

  def side_query(source, question, opts), do: CodingAgent.SideQuery.ask(source, question, opts)

  def run_graph(run_id), do: CodingAgent.RunGraph.get(run_id)

  def progress_snapshot(session_id, cwd), do: CodingAgent.Progress.snapshot(session_id, cwd)

  def load_extensions(paths), do: CodingAgent.Extensions.load_extensions_with_errors(paths)

  def extension_providers(extensions), do: CodingAgent.Extensions.get_providers(extensions)

  def extension_info(extensions), do: CodingAgent.Extensions.get_info(extensions)

  def tool_conflicts(cwd, opts), do: CodingAgent.ToolRegistry.tool_conflict_report(cwd, opts)

  def extension_dirs(cwd) do
    [CodingAgent.Config.extensions_dir(), CodingAgent.Config.project_extensions_dir(cwd)]
  end

  def wasm_sidecar_running? do
    is_pid(Process.whereis(CodingAgent.Wasm.SidecarSupervisor))
  end

  defp normalize_background_list_opts(opts) do
    case Keyword.get(opts, :status) do
      status
      when status in ~w(queued running completed error lost killed cancelled tracking_lost) ->
        Keyword.put(opts, :status, String.to_existing_atom(status))

      _ ->
        Keyword.delete(opts, :status)
    end
  end
end
