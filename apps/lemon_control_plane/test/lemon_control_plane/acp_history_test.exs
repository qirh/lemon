defmodule LemonControlPlane.ACP.HistoryTest do
  use ExUnit.Case, async: true
  alias LemonControlPlane.ACP.History

  test "retained cancelled prose is inserted in its user turn, not after a later empty run" do
    partial = String.duplicate("violet ", 296) <> "essay"

    entries = [
      user("u1", "first", 101),
      assistant("a1", "DONE", 102),
      user("u2", "essay", 201),
      user("u3", "sleep", 301),
      assistant("a3", "LATEST", 302)
    ]

    runs = [
      run("r3", "sleep", "LATEST", 300),
      run("r2", "essay", partial, 200),
      run("r1", "first", "DONE", 100)
    ]

    repaired = History.reconcile_answers(entries, runs)
    assert Enum.map(repaired, & &1.id) == ["u1", "a1", "u2", "r2:retained-answer", "u3", "a3"]
    assert get_in(Enum.at(repaired, 3), [:message, :content]) == [%{type: :text, text: partial}]
    assert repaired == History.reconcile_answers(repaired, runs)
  end

  test "only the missing exact suffix is recovered" do
    entries = [user("u", "request", 101), assistant("a", "known prefix ", 102)]

    repaired =
      History.reconcile_answers(entries, [run("r", "request", "known prefix missing tail", 100)])

    assert List.last(repaired).message.content == [%{type: :text, text: "missing tail"}]

    assert entries ==
             History.reconcile_answers(entries, [run("r", "request", "different answer", 100)])
  end

  test "repeated prompts are bound by recorded start intervals and ambiguous runs are not guessed" do
    entries = [user("u1", "same", 101), assistant("a1", "one", 102), user("u2", "same", 201)]

    repaired =
      History.reconcile_answers(entries, [
        run("r2", "same", "two", 200),
        run("r1", "same", "one", 100)
      ])

    assert List.last(repaired).message.content == [%{type: :text, text: "two"}]

    assert entries ==
             History.reconcile_answers(entries, [
               run("r", "same", "unknown", 100),
               run("other", "same", "unknown", 99)
             ])
  end

  test "retained model prose precedes an actually active cancelled tool call" do
    call = %{type: :tool_call, id: "call", name: "bash", arguments: %{command: "sleep 90"}}

    entries = [
      user("u", "request", 101),
      %{
        type: :message,
        id: "a",
        message: %{
          role: :assistant,
          content: [%{type: :text, text: "known "}, call],
          timestamp: 102
        }
      }
    ]

    {id, data} = run("r", "request", "known retained", 100)

    data =
      Map.put(data, :events, [
        %{phase: :updated, action: %{id: "tool_call", detail: %{tool_call_id: "call"}}}
      ])

    repaired = History.reconcile_answers(entries, [{id, data}])

    assert List.last(repaired).message.content == [
             %{type: :text, text: "known "},
             %{type: :text, text: "retained"},
             call
           ]
  end

  defp user(id, text, time),
    do: %{type: :message, id: id, message: %{role: :user, content: text, timestamp: time}}

  defp assistant(id, text, time),
    do: %{
      type: :message,
      id: id,
      message: %{role: :assistant, content: [%{type: :text, text: text}], timestamp: time}
    }

  defp run(id, prompt, answer, started),
    do:
      {id,
       %{
         started_at: started,
         events: [],
         summary: %{prompt: prompt, completed: %{answer: answer, ok: false, error: :acp_cancel}}
       }}
end
