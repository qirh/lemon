defmodule LemonAi.ProviderTest do
  use ExUnit.Case, async: true

  describe "provider metadata consistency" do
    test "all providers have unique api_ids" do
      providers = [
        LemonAi.Providers.Anthropic,
        LemonAi.Providers.OpenAIResponses,
        LemonAi.Providers.Google,
        LemonAi.Providers.GoogleVertex,
        LemonAi.Providers.GoogleGeminiCli,
        LemonAi.Providers.Bedrock,
        LemonAi.Providers.AzureOpenAIResponses,
        LemonAi.Providers.OpenAICompletions,
        LemonAi.Providers.OpenAICodexResponses
      ]

      api_ids = Enum.map(providers, & &1.api_id())

      assert length(api_ids) == length(Enum.uniq(api_ids)),
             "API IDs must be unique"
    end
  end
end
