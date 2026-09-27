defmodule CodingAgent.Session.RunTranslatorTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session.RunTranslator
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  defmodule TestEmitter do
    @behaviour CodingAgent.Session.RunTranslator.Emitter

    @impl true
    def emit_started(pid, _fields), do: pid

    @impl true
    def emit_action_event(pid, fields) do
      send(pid, {:action_event, fields})
      pid
    end

    @impl true
    def emit_delta(pid, _text, _meta), do: pid

    @impl true
    def emit_completed(pid, _fields), do: pid
  end

  defp translator do
    RunTranslator.new(
      emitter: TestEmitter,
      emitter_state: self(),
      engine: "lemon",
      label: "test",
      cwd: "/tmp"
    )
  end

  defp completed_detail(name, args, result) do
    translator()
    |> RunTranslator.handle_event({:tool_execution_start, "c1", name, args})
    |> RunTranslator.handle_event({:tool_execution_end, "c1", name, result, false})

    assert_receive {:action_event, %{phase: :started}}
    assert_receive {:action_event, %{phase: :completed, detail: detail}}
    detail
  end

  describe "completed tool actions" do
    test "keep the 500-char preview for channels and add a bounded full result and structured details for operators" do
      body = Enum.map_join(1..400, "\n", &"line #{&1}")
      diff = " 119\told\n-120\tbefore\n+120\tafter\n 121\tnext"

      result = %AgentToolResult{
        content: [%TextContent{text: body}],
        details: %{
          diff: diff,
          first_changed_line: 120,
          acp_client: true,
          checkpoint: %{id: "cp_1", files: ["lib/a.ex"]},
          session: self()
        }
      }

      detail = completed_detail("edit", %{"path" => "lib/a.ex"}, result)

      assert String.length(detail.result) <= 503
      assert detail.result_full == body
      assert detail.details.diff == diff
      assert detail.details.first_changed_line == 120
      assert detail.details.checkpoint == %{id: "cp_1", files: ["lib/a.ex"]}
      refute Map.has_key?(detail.details, :acp_client)
      refute Map.has_key?(detail.details, :session)
      assert Jason.encode!(detail.details)
    end

    test "bound the operator copy of very large results" do
      body = String.duplicate("x", 100_000)
      result = %AgentToolResult{content: [%TextContent{text: body}], details: %{exit_code: 0}}

      detail = completed_detail("bash", %{"command" => "yes x"}, result)

      assert byte_size(detail.result_full) <= 32_768
      assert detail.result_full =~ "bytes omitted"
      assert detail.details == %{exit_code: 0}
    end

    test "omit result_full when the preview already is the whole result" do
      result = %AgentToolResult{content: [%TextContent{text: "ok"}], details: nil}

      detail = completed_detail("read", %{"path" => "a"}, result)

      assert detail.result == "ok"
      refute Map.has_key?(detail, :result_full)
      refute Map.has_key?(detail, :details)
    end
  end

  describe "reasoning actions" do
    test "carry a bounded full text next to the channel preview" do
      thinking = String.duplicate("think ", 1_000)

      translator()
      |> RunTranslator.handle_event({:message_update, %{}, {:thinking_start, 0, nil}})
      |> RunTranslator.handle_event({:message_update, %{}, {:thinking_end, 0, thinking, nil}})

      assert_receive {:action_event, %{kind: :reasoning, phase: :started}}

      assert_receive {:action_event,
                      %{kind: :reasoning, phase: :completed, detail: %{reasoning: reasoning}}}

      assert String.length(reasoning.text) <= 503
      assert reasoning.full_text == thinking
    end

    test "cap the operator reasoning copy at 16 KB" do
      thinking = String.duplicate("y", 40_000)

      translator()
      |> RunTranslator.handle_event({:message_update, %{}, {:thinking_end, 0, thinking, nil}})

      assert_receive {:action_event,
                      %{kind: :reasoning, phase: :completed, detail: %{reasoning: reasoning}}}

      assert byte_size(reasoning.full_text) < 16_384 + 100
      assert reasoning.full_text =~ "bytes of reasoning omitted"
    end
  end
end
