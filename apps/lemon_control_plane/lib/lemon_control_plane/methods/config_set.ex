defmodule LemonControlPlane.Methods.ConfigSet do
  @moduledoc """
  Handler for the config.set control plane method.

  Sets a configuration value.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.ConfigStore
  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "config.set"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    key = params["key"]
    value = params["value"]

    cond do
      is_nil(key) or key == "" ->
        {:error, Errors.invalid_request("key is required")}

      is_nil(value) ->
        {:error, Errors.invalid_request("value is required")}

      true ->
        ConfigStore.put(key, value)

        {:ok,
         %{
           "key" => key,
           "value" => response_value(key, value),
           "success" => true,
           "summary" => summary(key, value)
         }}
    end
  end

  defp summary(key, value) do
    sensitive? = LemonCore.Redact.sensitive_key?(key)

    %{
      "key" => key,
      "valueStored" => not is_nil(value),
      "sensitive" => sensitive?,
      "cleanup" => %{
        "includesValue" => not sensitive?,
        "includesCredentialValues" => false,
        "includesSecretValues" => false
      }
    }
  end

  defp response_value(key, value) do
    if LemonCore.Redact.sensitive_key?(key) and not is_nil(value) do
      %{"redacted" => true, "kind" => "secret"}
    else
      value
    end
  end

  
end
