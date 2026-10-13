defmodule LemonAi.Models.CurrentCatalogTest do
  use ExUnit.Case, async: true

  alias LemonAi.Models

  test "only reference-supported Claude models enable summarized thinking display" do
    supported =
      ~w(claude-fable-5 claude-fable-5-1 claude-mythos-5 claude-opus-4-7
         claude-opus-4-8 claude-opus-5 claude-sonnet-5)

    for model <- Models.get_models(:anthropic) do
      assert Map.get(model.compat || %{}, :anthropic_thinking_display, false) ==
               model.id in supported
    end
  end

  test "Codex lists only supported OAuth models with surface-specific limits" do
    expected = %{
      "gpt-5.3-codex-spark" => {128_000, 2},
      "gpt-5.4" => {272_000, 2},
      "gpt-5.4-mini" => {272_000, 2},
      "gpt-5.5" => {272_000, 2.5},
      "gpt-5.6-luna" => {1_000_000, 2},
      "gpt-5.6-sol" => {1_000_000, 2},
      "gpt-5.6-terra" => {1_000_000, 2},
      "gpt-6-astra" => {272_000, 2.5},
      "gpt-daybreak-blue-latest" => {272_000, 2}
    }

    models = Models.get_models(:"openai-codex")
    assert Enum.sort(Enum.map(models, & &1.id)) == Enum.sort(Map.keys(expected))

    for model <- models do
      {context, priority} = Map.fetch!(expected, model.id)
      assert model.context_window == context
      assert model.max_tokens == 128_000
      assert model.api == :openai_codex_responses
      assert model.service_tier_cost == %{"flex" => 0.5, "priority" => priority}
      assert model.reasoning_efforts == [:low, :medium, :high, :xhigh]
      assert model.cost.input > 0
    end

    assert Models.get_model(:"openai-codex", "gpt-5.3-codex-spark").input == [:text]
    assert Models.get_model(:openai, "gpt-6-astra") == nil
    assert Models.get_model(:"openai-codex", "gpt-daybreak-blue-latest").cost.long_context == nil
  end

  test "GPT 5.6 retains reference long-context rates and direct API identity" do
    model = Models.get_model(:openai, "gpt-5.6")
    assert model.api == :openai_responses
    assert model.context_window == 1_050_000
    assert model.max_tokens == 128_000
    assert model.cost.input == 4
    assert model.cost.output == 20
    assert model.cost.cache_read == 0.4
    assert model.cost.cache_write == 5

    assert model.cost.long_context == %{
             input_threshold: 272_000,
             input: 10,
             output: 45,
             cache_read: 1,
             cache_write: 12.5
           }
  end

  test "current Gemini models retain each wire API and reference prices" do
    for {provider, api} <- [google: :google_generative_ai, google_vertex: :google_vertex],
        {id, input, output, cache_read} <- [
          {"gemini-3.1-flash-lite", 0.25, 1.5, 0.025},
          {"gemini-3.5-flash", 1.5, 9, 0.15},
          {"gemini-3.5-flash-lite", 0.3, 2.5, 0.03},
          {"gemini-3.6-flash", 0.75, 3.75, 0.075},
          {"gemini-3.7-flash", 0.75, 3.75, 0.075},
          {"gemini-3.8-flash", 0.75, 3.75, 0.075}
        ] do
      model = Models.get_model(provider, id)
      assert model.api == api
      assert model.provider == provider
      assert model.context_window == 1_048_576
      assert model.max_tokens == 65_536
      assert model.cost.input == input
      assert model.cost.output == output
      assert model.cost.cache_read == cache_read
      assert model.cost.cache_write == 0
      assert :high in model.reasoning_efforts
    end

    cli = Models.get_model(:google_gemini_cli, "gemini-3.1-pro-preview")
    assert cli.api == :google_gemini_cli
    assert cli.context_window == 1_048_576
    assert cli.max_tokens == 65_536
    assert cli.cost.input == 0
    assert cli.reasoning_efforts == [:low, :high]
  end

  test "unsupported live, image-output and alternate Vertex protocols stay excluded" do
    assert Models.get_model(:openai, "gpt-realtime-2.1") == nil

    for id <- ~w(gemini-live-2.5-flash gemini-live-2.5-flash-preview-native-audio
                 gemini-3.1-flash-live-preview gemini-3.1-flash-lite-image
                 deep-research-preview-04-2026 deep-research-max-preview-04-2026) do
      assert Models.get_model(:google, id) == nil
    end

    assert Enum.all?(Models.get_models(:google_vertex), &(&1.api == :google_vertex))
  end
end
