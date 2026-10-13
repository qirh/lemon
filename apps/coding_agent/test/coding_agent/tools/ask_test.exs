defmodule CodingAgent.Tools.AskTest do
  use ExUnit.Case, async: true
  alias CodingAgent.Tools.Ask
  alias LemonCore.ACPClientBridge

  setup do
    run_id = "ask-test-#{System.unique_integer([:positive])}"
    :ok = ACPClientBridge.register(run_id)
    on_exit(fn -> ACPClientBridge.unregister(run_id) end)
    {:ok, opts: [run_id: run_id, acp_client_elicitation_form: true]}
  end

  test "only negotiated live clients advertise ask", %{opts: opts} do
    assert Ask.available?(opts)
    refute Ask.available?(Keyword.put(opts, :acp_client_elicitation_form, false))
    refute Ask.available?(Keyword.put(opts, :run_id, "not-registered"))
  end

  test "real bridge request uses the rendered form shape and returns the actual accepted choice",
       %{opts: opts} do
    questions = [
      %{
        "id" => "color",
        "question" => "Choose a color:",
        "options" => [%{"label" => "BLUE"}, %{"label" => "ORANGE"}],
        "recommended" => 1
      }
    ]

    task = Task.async(fn -> Ask.execute("call", %{"questions" => questions}, nil, nil, opts) end)
    assert_receive {:acp_client_request, payload}
    assert payload.method == "elicitation/create"
    assert payload.params["mode"] == "form"
    assert payload.params["requestedSchema"]["properties"]["q0"]["default"] == "ORANGE"
    assert payload.params["requestedSchema"]["properties"]["q0__other"]["type"] == "string"

    send(
      payload.reply_to,
      {:acp_client_response, payload.ref,
       %{"result" => %{"action" => "accept", "content" => %{"q0" => "BLUE"}}}}
    )

    result = Task.await(task)
    refute result.is_error
    assert hd(result.details.results)["selectedOptions"] == ["BLUE"]
  end

  test "declining never selects a recommendation", %{opts: opts} do
    task =
      Task.async(fn ->
        Ask.execute(
          "call",
          %{
            "questions" => [
              %{
                "id" => "q",
                "question" => "Question",
                "options" => [%{"label" => "YES"}],
                "recommended" => 0
              }
            ]
          },
          nil,
          nil,
          opts
        )
      end)

    assert_receive {:acp_client_request, payload}

    send(
      payload.reply_to,
      {:acp_client_response, payload.ref, %{"result" => %{"action" => "decline"}}}
    )

    result = Task.await(task)
    assert result.is_error
    assert result.details.status == "declined"
    refute Map.has_key?(result.details, :results)
  end

  test "free text and multiple choices preserve actual custom answers", %{opts: opts} do
    questions = [
      %{"id" => "text", "question" => "Explain", "options" => []},
      %{
        "id" => "multi",
        "question" => "Choose",
        "options" => [%{"label" => "A"}, %{"label" => "B"}],
        "multi" => true
      }
    ]

    task = Task.async(fn -> Ask.execute("call", %{"questions" => questions}, nil, nil, opts) end)
    assert_receive {:acp_client_request, payload}

    send(
      payload.reply_to,
      {:acp_client_response, payload.ref,
       %{
         "action" => "accept",
         "content" => %{"q0" => "Real free text", "q1" => ["B"], "q1__other" => "Custom"}
       }}
    )

    result = Task.await(task)
    refute result.is_error
    assert [text, multi] = result.details.results
    assert text["customInput"] == "Real free text"
    assert text["selectedOptions"] == []
    assert multi["selectedOptions"] == ["B"]
    assert multi["customInput"] == "Custom"
  end
end
