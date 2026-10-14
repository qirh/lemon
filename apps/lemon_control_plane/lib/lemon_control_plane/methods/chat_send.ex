defmodule LemonControlPlane.Methods.ChatSend do
  @moduledoc """
  Handler for the chat.send method.

  Sends a message to a session. An optional `cwd` must be an absolute existing
  directory. Canonical profile sessions do not accept caller workspace overrides.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.{ImageInputs, Protocol.Errors}

  @impl true
  def name, do: "chat.send"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, ctx) do
    with {:ok, images} <- ImageInputs.validate(Map.get(params, "images", [])) do
      submit(params, ctx, images)
    end
  end

  defp submit(params, ctx, images) do
    session_key = params["sessionKey"]
    prompt = params["prompt"] || params["message"]
    agent_id = params["agentId"]
    queue_mode = parse_queue_mode(params["queueMode"])
    router_mod = Map.get(ctx, :router_mod, LemonRouter)

    cond do
      is_nil(session_key) ->
        {:error, {:invalid_request, "sessionKey is required", nil}}

      is_nil(prompt) ->
        {:error, {:invalid_request, "prompt is required", nil}}

      Map.has_key?(params, "cwd") and not valid_cwd?(params["cwd"]) ->
        {:error, {:invalid_request, "cwd must be a nonempty absolute existing directory", nil}}

      Map.has_key?(params, "cwd") and profile_session?(session_key) ->
        {:error, {:invalid_request, "cwd cannot override a canonical profile session", nil}}

      true ->
        run_id = LemonCore.Id.run_id()

        submit_params = %{
          run_id: run_id,
          origin: :control_plane,
          session_key: session_key,
          agent_id: agent_id,
          prompt: prompt,
          images: images,
          queue_mode: queue_mode,
          meta: %{
            control_plane: true
          }
        }

        submit_params =
          if Map.has_key?(params, "cwd") do
            Map.put(submit_params, :cwd, params["cwd"])
          else
            submit_params
          end

        case router_mod.submit(submit_params) do
          {:ok, run_id} ->
            {:ok,
             %{
               "runId" => run_id,
               "sessionKey" => session_key,
               "summary" => summary(run_id, session_key, agent_id, prompt, queue_mode)
             }}

          {:error, :outcome_unknown} ->
            {:error,
             Errors.error(:unavailable, "Chat submission outcome is unknown", %{
               "code" => "SUBMISSION_OUTCOME_UNKNOWN",
               "runId" => run_id,
               "sessionKey" => session_key,
               "retrySafe" => false
             })}

          {:error, _reason} ->
            {:error, {:internal_error, "Chat submission failed", nil}}
        end
    end
  end

  defp valid_cwd?(cwd) when is_binary(cwd) and cwd != "" do
    Path.type(cwd) == :absolute and File.dir?(cwd)
  end

  defp valid_cwd?(_cwd), do: false

  defp profile_session?(session_key) when is_binary(session_key) do
    case LemonCore.SessionKey.parse(session_key) do
      %{kind: :main, agent_id: id} ->
        case LemonCore.ProfileStore.get(id) do
          {:ok, profile} -> profile["canonicalSessionKey"] == session_key
          {:error, :not_found} -> false
          {:error, _} -> true
        end

      _ ->
        false
    end
  end

  defp profile_session?(_session_key), do: false

  defp parse_queue_mode(nil), do: :collect
  defp parse_queue_mode("collect"), do: :collect
  defp parse_queue_mode("followup"), do: :followup
  defp parse_queue_mode("steer"), do: :steer
  defp parse_queue_mode("redirect"), do: :redirect
  defp parse_queue_mode("interrupt"), do: :interrupt
  defp parse_queue_mode(_), do: :collect

  defp summary(run_id, session_key, agent_id, prompt, queue_mode) do
    %{
      "runId" => run_id,
      "sessionKey" => session_key,
      "agentId" => agent_id,
      "queueMode" => to_string(queue_mode),
      "promptBytes" => byte_size(to_string(prompt)),
      "cleanup" => %{
        "includesPromptText" => false,
        "includesMessageBodies" => false,
        "includesCredentials" => false,
        "includesSecretValues" => false
      }
    }
  end
end
