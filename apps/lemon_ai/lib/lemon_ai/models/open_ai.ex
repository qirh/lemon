defmodule LemonAi.Models.OpenAI do
  @moduledoc """
  Model definitions for the OpenAI provider.

  The catalog is data: `priv/models/open_ai.json`, loaded at compile time by
  `LemonAi.Models.Catalog`, one entry per model with its capabilities and
  per-million-token pricing. Edit the JSON to add a model or change a price;
  `mix lemon.models` lists what is currently defined.

  `codex_models/0` exposes only the ChatGPT OAuth models declared by the
  reference catalog, with their own limits and service-tier pricing. OAuth
  subscription access does not imply zero token cost in usage estimates.
  """

  alias LemonAi.Models.Catalog
  alias LemonAi.Types.Model

  @external_resource Catalog.path("open_ai.json")
  @models Catalog.load!("open_ai.json")

  # Source: oh-my-pi/packages/catalog/src/models.json, openai-codex.
  # Most entries share direct-API metadata, but not their context limits.
  @codex_specs [
    {"gpt-5.3-codex-spark", "gpt-5.3-codex", 128_000, 2},
    {"gpt-5.4", "gpt-5.4", 272_000, 2},
    {"gpt-5.4-mini", "gpt-5.4-mini", 272_000, 2},
    {"gpt-5.5", "gpt-5.5", 272_000, 2.5},
    {"gpt-5.6-luna", "gpt-5.6-luna", 1_000_000, 2},
    {"gpt-5.6-sol", "gpt-5.6-sol", 1_000_000, 2},
    {"gpt-5.6-terra", "gpt-5.6-terra", 1_000_000, 2},
    {"gpt-6-astra", "gpt-5.6-sol", 272_000, 2.5},
    {"gpt-daybreak-blue-latest", "daybreak-blue-latest", 272_000, 2}
  ]

  @codex_models Map.new(@codex_specs, fn {id, source, context_window, priority} ->
                  model = Map.fetch!(@models, source)

                  model = %Model{
                    model
                    | id: id,
                      api: :openai_codex_responses,
                      provider: :"openai-codex",
                      base_url: "https://chatgpt.com",
                      context_window: context_window,
                      max_tokens: 128_000,
                      service_tier_cost: %{"flex" => 0.5, "priority" => priority}
                  }

                  model =
                    case id do
                      "gpt-5.3-codex-spark" ->
                        %Model{model | name: "GPT-5.3 Codex Spark", input: [:text]}

                      "gpt-6-astra" ->
                        %Model{
                          model
                          | name: "GPT-6-Astra",
                            cost: %LemonAi.Types.ModelCost{
                              input: 10,
                              output: 50,
                              cache_read: 1,
                              cache_write: 0
                            }
                        }

                      "gpt-daybreak-blue-latest" ->
                        %Model{model | cost: %{model.cost | long_context: nil}}

                      _ ->
                        model
                    end

                  {id, model}
                end)

  @doc "Returns all OpenAI model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models

  @doc "Returns the supported ChatGPT OAuth model catalog."
  @spec codex_models() :: %{String.t() => Model.t()}
  def codex_models, do: @codex_models
end
