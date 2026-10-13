defmodule LemonControlPlane.Methods.ModelsListTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.ModelsList

  setup do
    previous = Application.fetch_env(:lemon_control_plane, :model_catalog)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:lemon_control_plane, :model_catalog, value)
        :error -> Application.delete_env(:lemon_control_plane, :model_catalog)
      end
    end)

    :ok
  end

  test "returns only account-available models with their advertised capabilities" do
    parent = self()

    fixture = %LemonAi.Types.Model{
      provider: :"openai-codex",
      id: "fixture-account-model",
      name: "Available account model",
      context_window: 64_000,
      max_tokens: 4_096,
      reasoning: true,
      input: [:text, :image]
    }

    Application.put_env(:lemon_control_plane, :model_catalog, fn opts ->
      send(parent, {:catalog_options, opts})
      [fixture]
    end)

    assert {:ok,
            %{
              "models" => [model],
              "summary" => summary,
              "includesCredentials" => false,
              "includesSecretValues" => false
            }} = ModelsList.handle(%{"discoverOpenAI" => false, "forceRefresh" => true}, %{})

    assert_receive {:catalog_options, [discover_openai: false, force_refresh: true]}
    assert model["id"] == fixture.id
    assert model["provider"] == "openai-codex"
    assert model["contextWindow"] == fixture.context_window
    assert model["maxOutput"] == fixture.max_tokens
    assert model["supportsThinking"]
    assert model["supportsVision"]
    assert model["supportsStreaming"]
    assert summary["total"] == 1
    assert summary["providers"] == ["openai-codex"]
    assert summary["visionModelCount"] == 1
    assert summary["thinkingModelCount"] == 1
  end

  test "an empty available catalog never reintroduces static or default models" do
    Application.put_env(:lemon_control_plane, :model_catalog, fn _opts -> [] end)
    assert {:ok, %{"models" => [], "summary" => summary}} = ModelsList.handle(%{}, %{})
    assert summary["total"] == 0
    assert summary["providerCount"] == 0
  end
end
