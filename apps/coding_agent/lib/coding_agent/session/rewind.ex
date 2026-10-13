defmodule CodingAgent.Session.Rewind do
  @moduledoc """
  Active-branch rewind with preview-bound, opt-in filesystem restoration.

  Rewind moves the cursor to immediately before a selected user message. The
  abandoned suffix remains in the session tree, but is no longer sent to the
  model. Files restore from the first recorded pre-mutation snapshot for each
  path in that suffix. Confirmation binds the branch revision and current file
  contents; it is stored server-side, expires after five minutes and is single use.
  """

  alias CodingAgent.SessionManager
  alias LemonCore.{Checkpoint, Store}

  @confirmation_table :session_rewinds
  @confirmation_ttl_ms 5 * 60 * 1000
  @mutation_tools ~w(write edit patch apply_patch bash)

  def tree(session, opts \\ []) do
    entries = SessionManager.entries(session)
    active = MapSet.new(SessionManager.get_branch(session), & &1.id)
    parents = MapSet.new(entries, & &1.parent_id)
    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit, 100)

    branches =
      entries
      |> Enum.filter(&(not MapSet.member?(parents, &1.id) or &1.id == session.leaf_id))
      |> Enum.map(&%{"leafId" => &1.id, "active" => &1.id == session.leaf_id})

    nodes =
      entries
      |> Enum.drop(offset)
      |> Enum.take(limit)
      |> Enum.map(fn entry ->
        role = entry.message && field(entry.message, :role)
        on_branch = MapSet.member?(active, entry.id)

        %{
          "id" => entry.id,
          "parentId" => entry.parent_id,
          "type" => Atom.to_string(entry.type),
          "role" => if(role, do: to_string(role)),
          "text" => preview(entry),
          "timestamp" => entry.timestamp,
          "isActive" => on_branch,
          "isLeaf" => not MapSet.member?(parents, entry.id),
          "rewindable" => on_branch and role in [:user, "user"]
        }
      end)

    %{
      "sessionId" => session.header.id,
      "leafId" => session.leaf_id,
      "entries" => nodes,
      "branches" => branches,
      "totalEntries" => length(entries),
      "offset" => offset,
      "hasMore" => offset + length(nodes) < length(entries)
    }
  end

  def run(session, entry_id, opts \\ []) do
    with {:ok, target, suffix} <- target_suffix(session, entry_id) do
      if Keyword.get(opts, :dry_run, true) do
        preview_rewind(session, target, suffix, opts)
      else
        execute_rewind(session, target, suffix, opts)
      end
    end
  end

  defp preview_rewind(session, target, suffix, opts) do
    restore_files = Keyword.get(opts, :restore_files, false)
    {plan, unavailable} = restoration_plan(session, suffix)

    with {:ok, fingerprints} <- fingerprints(plan, restore_files) do
      token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

      confirmation = %{
        token: token,
        revision: revision(session),
        entry_id: target.id,
        restore_files: restore_files,
        plan: plan,
        fingerprints: fingerprints,
        unavailable: unavailable,
        expires_at: System.system_time(:millisecond) + @confirmation_ttl_ms
      }

      case Store.put(@confirmation_table, session.header.id, confirmation) do
        :ok ->
          {:ok,
           %{
             "sessionId" => session.header.id,
             "entryId" => target.id,
             "confirmationToken" => token,
             "prompt" => message_text(target.message),
             "discardedMessages" => Enum.count(suffix, &(&1.type in [:message, :custom_message])),
             "restorePaths" => Enum.map(plan, & &1.path),
             "unrestorableTools" => unavailable
           }, session}

        {:error, _} ->
          {:error, :session_store_unavailable}
      end
    end
  end

  defp execute_rewind(session, target, suffix, opts) do
    token = Keyword.get(opts, :confirmation_token)
    confirmation = Store.get(@confirmation_table, session.header.id)
    restore_files = Keyword.get(opts, :restore_files, false)
    {plan, unavailable} = restoration_plan(session, suffix)

    cond do
      not is_binary(token) or token == "" ->
        {:error, :confirmation_required}

      not is_map(confirmation) or confirmation.token != token or
        confirmation.expires_at < System.system_time(:millisecond) or
        confirmation.revision != revision(session) or confirmation.entry_id != target.id or
        confirmation.restore_files != restore_files or confirmation.plan != plan or
          confirmation.unavailable != unavailable ->
        {:error, :stale_confirmation}

      restore_files and unavailable != [] ->
        {:error, :checkpoint_missing}

      true ->
        with {:ok, current} <- fingerprints(plan, restore_files),
             true <- current == confirmation.fingerprints,
             :ok <- Store.compare_and_delete(@confirmation_table, session.header.id, confirmation) do
          restore_and_rewind(session, target, if(restore_files, do: plan, else: []))
        else
          false -> {:error, :stale_confirmation}
          {:error, :mismatch} -> {:error, :stale_confirmation}
          {:error, _} = error -> error
        end
    end
  end

  defp restore_and_rewind(session, target, plan) do
    with {:ok, backup} <- backup_current_files(session, plan) do
      try do
        with :ok <- restore_plan(plan) do
          session = SessionManager.set_leaf_id(session, target.parent_id)

          {:ok,
           %{
             "sessionId" => session.header.id,
             "entryId" => target.id,
             "prompt" => message_text(target.message),
             "leafId" => session.leaf_id,
             "restoredPaths" => Enum.map(plan, & &1.path)
           }, session}
        else
          {:error, _} -> rollback_files(backup)
        end
      rescue
        _ -> rollback_files(backup)
      end
    end
  end

  defp backup_current_files(_session, []), do: {:ok, nil}

  defp backup_current_files(session, plan) do
    case Checkpoint.create_filesystem(session.header.id, Enum.map(plan, & &1.path),
           cwd: session.header.cwd,
           tool: "rewind",
           metadata: %{reason: "rewind_rollback"}
         ) do
      {:ok, checkpoint} -> {:ok, checkpoint.id}
      {:error, _} -> {:error, :restore_failed}
    end
  end

  defp rollback_files(nil), do: {:error, :restore_failed}

  defp rollback_files(backup) do
    case Checkpoint.restore_filesystem(backup) do
      {:ok, _} -> {:error, :restore_failed}
      {:error, _} -> {:error, :restore_rollback_failed}
    end
  end

  defp restore_plan(plan) do
    Enum.reduce_while(plan, :ok, fn item, :ok ->
      case Checkpoint.restore_filesystem(item.checkpoint_id, paths: [item.path]) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} -> {:halt, {:error, :restore_failed}}
      end
    end)
  end

  defp target_suffix(session, entry_id) do
    case SessionManager.get_entry(session, entry_id) do
      nil ->
        {:error, :entry_not_found}

      %{type: :message, message: message} = target ->
        if field(message, :role) in [:user, "user"] do
          case Enum.split_while(SessionManager.get_branch(session), &(&1.id != entry_id)) do
            {_, []} -> {:error, :entry_not_on_active_branch}
            {_, suffix} -> {:ok, target, suffix}
          end
        else
          {:error, :not_user_message}
        end

      _ ->
        {:error, :not_user_message}
    end
  end

  defp restoration_plan(session, suffix) do
    {paths, unavailable} =
      Enum.reduce(suffix, {%{}, []}, fn entry, {paths, unavailable} ->
        message = entry.message || %{}
        name = field(message, :tool_name)

        if entry.type == :message and field(message, :role) in [:tool_result, "tool_result"] do
          details = field(message, :details) || %{}
          checkpoint_id = field(details, :checkpoint_id)

          cond do
            is_binary(checkpoint_id) ->
              case checkpoint_files(checkpoint_id, session.header.cwd) do
                {:ok, files} ->
                  paths =
                    Enum.reduce(files, paths, fn snapshot, acc ->
                      Map.put_new(acc, snapshot.path, %{
                        checkpoint_id: checkpoint_id,
                        path: snapshot.path,
                        snapshot_digest: digest(snapshot)
                      })
                    end)

                  {paths, unavailable}

                {:error, _} ->
                  {paths, [name || "unknown" | unavailable]}
              end

            name in @mutation_tools and field(message, :is_error) != true ->
              {paths, [name | unavailable]}

            true ->
              {paths, unavailable}
          end
        else
          {paths, unavailable}
        end
      end)

    result_ids = MapSet.new(suffix, fn entry -> field(entry.message, :tool_call_id) end)

    interrupted =
      Enum.flat_map(suffix, fn entry ->
        case field(entry.message, :content) do
          blocks when is_list(blocks) ->
            Enum.flat_map(blocks, fn block ->
              if field(block, :type) in [:tool_call, "tool_call"] and
                   field(block, :name) in @mutation_tools and
                   not MapSet.member?(result_ids, field(block, :id)),
                 do: [field(block, :name)],
                 else: []
            end)

          _ ->
            []
        end
      end)

    {paths |> Map.values() |> Enum.sort_by(& &1.path),
     (Enum.reverse(unavailable) ++ interrupted) |> Enum.uniq()}
  end

  defp checkpoint_files(id, cwd) do
    with {:ok, checkpoint} <- Checkpoint.load(id),
         %{cwd: checkpoint_cwd, files: files} <- get_in(checkpoint, [:state, :filesystem]),
         true <- Path.expand(checkpoint_cwd) == Path.expand(cwd) do
      {:ok, files}
    else
      _ -> {:error, :checkpoint_scope_mismatch}
    end
  end

  defp fingerprints(_plan, false), do: {:ok, []}

  defp fingerprints(plan, true) do
    Enum.reduce_while(plan, {:ok, []}, fn item, {:ok, acc} ->
      case file_fingerprint(item.path) do
        {:ok, value} -> {:cont, {:ok, [{item.path, value} | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp file_fingerprint(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        {:ok, :missing}

      {:ok, %{type: :regular, mode: mode}} ->
        hash =
          path
          |> File.stream!(65_536, [])
          |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
          |> :crypto.hash_final()

        {:ok, {mode, hash}}

      {:ok, _} ->
        {:error, :unsupported_file_type}

      {:error, _} ->
        {:error, :restore_failed}
    end
  rescue
    _ -> {:error, :restore_failed}
  end

  defp revision(session),
    do: {session.header.id, session.leaf_id, SessionManager.entry_count(session)}

  defp digest(value), do: :crypto.hash(:sha256, :erlang.term_to_binary(value))

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_, _), do: nil

  defp preview(%{type: :message, message: message}) do
    if field(message, :role) in [:user, "user", :assistant, "assistant"] do
      message |> message_text() |> LemonCore.Redact.text(strict: true) |> String.slice(0, 240)
    else
      ""
    end
  end

  defp preview(_), do: ""

  defp message_text(message) do
    case field(message, :content) do
      text when is_binary(text) ->
        text

      blocks when is_list(blocks) ->
        Enum.map_join(blocks, "", fn block ->
          if field(block, :type) in [:text, "text"], do: field(block, :text) || "", else: ""
        end)

      _ ->
        ""
    end
  end
end
