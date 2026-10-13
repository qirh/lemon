defmodule CodingAgent.Tools.TodoWrite do
  @moduledoc """
  Replaces the current session's complete todo list through `TodoStore`.

  Entries require only `content`. Omitted `status` and `priority` default to
  `"pending"` and `"medium"`; explicitly supplied values must be valid.
  IDs are optional. An omitted ID reuses an unclaimed ID from the previous
  same-content entry, or gets a deterministic content-based ID. Repeated content
  receives distinct IDs in list order. Supply the returned ID when renaming a task
  to preserve its identity. Duplicate explicit IDs reject the entire write.

  Successful results contain the normalized full state in `details.todos` and
  the complete ACP/TUI plan in `details.plan.entries`, including completed tasks.
  Writes replace the list (including clearing it with `todos: []`), not patch it.
  """

  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAgent.AbortSignal
  alias LemonAi.Types.TextContent
  alias CodingAgent.Tools.TodoStore

  @doc """
  Returns the TodoWrite tool definition.
  """
  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(_cwd, opts \\ []) do
    session_id = Keyword.get(opts, :session_id, "")

    %AgentTool{
      name: "todowrite",
      description: "Write the session todo list.",
      label: "Write Todos",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "todos" => todos_schema()
        },
        "required" => ["todos"]
      },
      execute: &execute(&1, &2, &3, &4, session_id)
    }
  end

  @doc "The entry schema shared by the unified and standalone todo write tools."
  @spec todos_schema() :: map()
  def todos_schema do
    %{
      "type" => "array",
      "description" =>
        "Complete replacement plan, including completed tasks. Use [] to clear it. IDs are optional.",
      "items" => %{
        "type" => "object",
        "properties" => %{
          "content" => %{"type" => "string", "description" => "Brief description of the task"},
          "status" => %{
            "type" => "string",
            "enum" => ["pending", "in_progress", "completed"],
            "default" => "pending",
            "description" => "Task status; defaults to pending when omitted"
          },
          "priority" => %{
            "type" => "string",
            "enum" => ["high", "medium", "low"],
            "default" => "medium",
            "description" => "Priority; defaults to medium when omitted"
          },
          "id" => %{
            "type" => ["string", "null"],
            "description" =>
              "Stable ID returned by a previous write; omit or pass null for new tasks"
          }
        },
        "required" => ["content"]
      }
    }
  end

  @doc """
  Execute the TodoWrite tool, validating and storing the todo list.
  """
  @spec execute(
          tool_call_id :: String.t(),
          params :: map(),
          signal :: reference() | nil,
          on_update :: (AgentToolResult.t() -> :ok) | nil,
          session_id :: String.t()
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, signal, _on_update, session_id) do
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      todos = Map.get(params, "todos")

      cond do
        not is_list(todos) ->
          {:error, "Todos must be an array"}

        session_id == "" ->
          {:error, "Session id not available"}

        true ->
          todos =
            Enum.map(todos, fn
              todo when is_map(todo) ->
                todo = if is_nil(Map.get(todo, "id")), do: Map.delete(todo, "id"), else: todo
                todo |> Map.put_new("status", "pending") |> Map.put_new("priority", "medium")

              todo ->
                todo
            end)

          with :ok <- validate_todos(todos) do
            todos = assign_ids(todos, TodoStore.get(session_id))
            :ok = TodoStore.put(session_id, todos)

            output = Jason.encode!(todos, pretty: true)
            open_count = Enum.count(todos, fn todo -> Map.get(todo, "status") != "completed" end)

            %AgentToolResult{
              content: [%TextContent{text: output}],
              details: Map.put(TodoStore.result_details(todos), :title, "#{open_count} todos")
            }
          end
      end
    end
  end

  defp validate_todos(todos) when is_list(todos) do
    with :ok <- validate_entries(todos),
         :ok <- validate_unique_ids(todos) do
      :ok
    end
  end

  defp validate_entries(todos) do
    Enum.reduce_while(Enum.with_index(todos, 1), :ok, fn
      {todo, idx}, :ok when is_map(todo) ->
        case validate_todo(todo, idx) do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end

      {_todo, idx}, :ok ->
        {:halt, {:error, "Todo #{idx} must be an object"}}
    end)
  end

  defp validate_todo(todo, idx) do
    with :ok <- validate_optional_id(todo, idx),
         :ok <- validate_non_empty_string(todo, "content", idx),
         :ok <- validate_status(todo, idx),
         :ok <- validate_priority(todo, idx) do
      :ok
    end
  end

  defp validate_optional_id(todo, idx) do
    if Map.has_key?(todo, "id"), do: validate_non_empty_string(todo, "id", idx), else: :ok
  end

  defp validate_non_empty_string(todo, key, idx) do
    case Map.get(todo, key) do
      value when is_binary(value) ->
        if byte_size(String.trim(value)) > 0 do
          :ok
        else
          {:error, "Todo #{idx} #{key} must be a non-empty string"}
        end

      _ ->
        {:error, "Todo #{idx} #{key} must be a non-empty string"}
    end
  end

  defp validate_status(todo, idx) do
    allowed = ["pending", "in_progress", "completed"]

    case Map.get(todo, "status") do
      value when is_binary(value) ->
        if value in allowed do
          :ok
        else
          {:error, "Todo #{idx} status must be pending, in_progress, or completed"}
        end

      _ ->
        {:error, "Todo #{idx} status must be pending, in_progress, or completed"}
    end
  end

  defp validate_priority(todo, idx) do
    allowed = ["high", "medium", "low"]

    case Map.get(todo, "priority") do
      value when is_binary(value) ->
        if value in allowed do
          :ok
        else
          {:error, "Todo #{idx} priority must be high, medium, or low"}
        end

      _ ->
        {:error, "Todo #{idx} priority must be high, medium, or low"}
    end
  end

  defp validate_unique_ids(todos) do
    ids = for todo <- todos, Map.has_key?(todo, "id"), do: todo["id"]

    if Enum.uniq(ids) == ids do
      :ok
    else
      {:error, "todo ids must be unique"}
    end
  end

  defp assign_ids(todos, previous) do
    previous_ids =
      previous
      |> Enum.group_by(&(Map.get(&1, "content") || Map.get(&1, :content)))
      |> Map.new(fn {content, entries} ->
        {content, Enum.map(entries, &(Map.get(&1, "id") || Map.get(&1, :id)))}
      end)

    reserved = MapSet.new(for todo <- todos, Map.has_key?(todo, "id"), do: todo["id"])

    {todos, _used} =
      Enum.map_reduce(todos, reserved, fn todo, used ->
        if Map.has_key?(todo, "id") do
          {todo, used}
        else
          id =
            Enum.find(Map.get(previous_ids, todo["content"], []), fn id ->
              is_binary(id) and String.trim(id) != "" and not MapSet.member?(used, id)
            end) || generated_id(todo["content"], used)

          {Map.put(todo, "id", id), MapSet.put(used, id)}
        end
      end)

    todos
  end

  defp generated_id(content, used) do
    base = "todo_" <> Base.encode16(:crypto.hash(:sha256, content), case: :lower)

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> base
      index -> "#{base}_#{index}"
    end)
    |> Enum.find(&(not MapSet.member?(used, &1)))
  end
end
