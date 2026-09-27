defmodule AgentCoreTest do
  use ExUnit.Case
  doctest LemonAgent

  alias LemonAgent.Test.Mocks

  describe "new_agent/1" do
    test "accepts top-level initial state options" do
      model = Mocks.mock_model(id: "agentcore-top-level")

      {:ok, agent} =
        LemonAgent.new_agent(
          model: model,
          system_prompt: "Top-level prompt",
          tools: [Mocks.echo_tool()]
        )

      state = LemonAgent.get_state(agent)

      assert state.model.id == "agentcore-top-level"
      assert state.system_prompt == "Top-level prompt"
      assert length(state.tools) == 1
    end
  end

  describe "wait_for_idle/2" do
    test "accepts numeric timeout" do
      response = Mocks.assistant_message("Hello")

      {:ok, agent} =
        LemonAgent.new_agent(
          model: Mocks.mock_model(),
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      :ok = LemonAgent.prompt(agent, "Hi")

      assert :ok = LemonAgent.wait_for_idle(agent, 1000)
    end
  end
end
