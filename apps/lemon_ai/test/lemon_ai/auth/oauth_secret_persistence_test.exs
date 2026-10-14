defmodule LemonAi.Auth.OAuthSecretPersistenceTest do
  # Swaps Req's global default plug and OAuth client env vars.
  use ExUnit.Case, async: false

  alias LemonAi.Auth.{
    AnthropicOAuth,
    GitHubCopilotOAuth,
    GoogleAntigravityOAuth,
    GoogleGeminiCliOAuth
  }

  @env ~w(GOOGLE_ANTIGRAVITY_OAUTH_CLIENT_ID GOOGLE_ANTIGRAVITY_OAUTH_CLIENT_SECRET)

  setup do
    previous_defaults = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})
    previous_env = Map.new(@env, &{&1, System.get_env(&1)})
    System.put_env("GOOGLE_ANTIGRAVITY_OAUTH_CLIENT_ID", "test-client-id")
    System.put_env("GOOGLE_ANTIGRAVITY_OAUTH_CLIENT_SECRET", "test-client-secret")

    # One body every provider's refresh endpoint accepts.
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "access_token" => "fresh-token",
        "refresh_token" => "fresh-refresh-token",
        "expires_in" => 3600,
        "token" => "fresh-copilot-token",
        "expires_at" => div(System.system_time(:millisecond), 1000) + 3600
      })
    end)

    on_exit(fn ->
      Req.default_options(previous_defaults)
      Req.Test.set_req_test_to_private(%{})

      Enum.each(previous_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  for {module, type} <- [
        {AnthropicOAuth, "anthropic_oauth"},
        {GitHubCopilotOAuth, "github_copilot_oauth"},
        {GoogleAntigravityOAuth, "google_antigravity_oauth"},
        {GoogleGeminiCliOAuth, "google_gemini_cli_oauth"}
      ] do
    test "#{inspect(module)} reports a refreshed secret it could not store" do
      secret = expired_secret(unquote(type))

      # e.g. `LemonCore.Secrets.set/3` answering `{:error, :secrets_locked}`
      # while a key rotation holds the secrets lock.
      assert {:error, :oauth_secret_persistence_failed} =
               unquote(module).resolve_api_key_from_secret("llm_secret", secret,
                 persist_secret: fn _name, _value -> {:error, :secrets_locked} end
               )

      assert {:ok, _api_key} =
               unquote(module).resolve_api_key_from_secret("llm_secret", secret,
                 persist_secret: fn _name, _value -> {:ok, %{}} end
               )
    end
  end

  defp expired_secret(type) do
    now = System.system_time(:millisecond)

    Jason.encode!(%{
      "type" => type,
      "refresh_token" => "refresh-token",
      "access_token" => "stale-token",
      "expires_at_ms" => now - 1_000,
      "project_id" => "proj-123",
      "managed_project_id" => "proj-123",
      "projectId" => "proj-123",
      "created_at_ms" => now,
      "updated_at_ms" => now
    })
  end
end
