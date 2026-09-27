defmodule LemonChannels.Doctor.Diagnostics do
  @moduledoc """
  Redacted Telegram and Discord configuration diagnostics for support bundles.
  """

  alias LemonChannels.Adapters.Telegram.Transport.RuntimeState
  alias LemonCore.Config

  # The transports this diagnostic knows how to report on. "Supported" below
  # means "reported here", not "registered in the channel runtime" — the two
  # differ, and the binding counts have always meant the former. Adding a
  # transport means adding a status builder, so this list stays the single
  # source of truth for both the report and the counts.
  @reported_transports [:telegram, :discord]

  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())
    gateway = Config.load(project_dir, cache: false).gateway || %{}
    bindings = Map.get(gateway, :bindings, [])

    %{
      transports: Enum.map(@reported_transports, &transport_status(&1, gateway, bindings)),
      registered_transports: registered_transports(),
      binding_count: Enum.count(bindings, &(transport(&1) in @reported_transports)),
      unsupported_binding_count:
        Enum.count(bindings, &(transport(&1) not in @reported_transports)),
      cleanup: %{
        includes_raw_bot_tokens: false,
        includes_secret_names: false,
        includes_chat_ids: false,
        includes_channel_ids: false,
        includes_guild_ids: false,
        includes_message_bodies: false
      }
    }
  end

  @doc """
  Renders a `status/1` map as the human-readable lines shared by
  `mix lemon.channels` and `lemon channels`.
  """
  @spec format_text(map()) :: [String.t()]
  def format_text(status) do
    registered =
      case Map.get(status, :registered_transports, []) do
        [] -> "none"
        ids -> Enum.join(ids, ", ")
      end

    [
      "Lemon Channels",
      "Registered transports: #{registered}",
      "Bindings: #{Map.get(status, :binding_count, 0)} (unsupported: #{Map.get(status, :unsupported_binding_count, 0)})"
      | Enum.map(Map.get(status, :transports, []), &format_transport/1)
    ]
  end

  defp format_transport(%{transport: "telegram"} = t) do
    "telegram: " <>
      format_fields([
        {"enabled", t.enabled},
        {"credentials", credentials_label(t)},
        {"bindings", t.binding_count},
        {"allowed_peers", t.allowed_peer_count},
        {"deny_unbound", t.deny_unbound_peers},
        {"voice_transcription", get_in(t, [:voice_transcription, :enabled])}
      ])
  end

  defp format_transport(%{transport: "discord"} = t) do
    "discord: " <>
      format_fields([
        {"enabled", t.enabled},
        {"credentials", credentials_label(t)},
        {"bindings", t.binding_count},
        {"allowed_guilds", t.allowed_guild_count},
        {"allowed_channels", t.allowed_channel_count},
        {"deny_unbound", t.deny_unbound_channels},
        {"message_content_intent", get_in(t, [:free_response, :message_content_intent_declared])}
      ])
  end

  defp format_fields(fields), do: Enum.map_join(fields, " ", fn {k, v} -> "#{k}=#{v}" end)

  defp credentials_label(t) do
    if t.token_configured or t.token_secret_configured, do: "configured", else: "missing"
  end

  defp transport_status(:telegram, gateway, bindings), do: telegram_status(gateway, bindings)
  defp transport_status(:discord, gateway, bindings), do: discord_status(gateway, bindings)

  # What the channel runtime actually has registered. The registry lives in this
  # app, so it is called directly; an unstarted registry reports an empty list.
  defp registered_transports do
    LemonChannels.Registry.list()
    |> Enum.map(fn {id, _info} -> to_string(id) end)
    |> Enum.sort()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp telegram_status(gateway, bindings) do
    telegram = Map.get(gateway, :telegram, %{}) || %{}
    files = map_value(telegram, :files, %{}) || %{}

    %{
      transport: "telegram",
      enabled: Map.get(gateway, :enable_telegram) == true,
      token_configured:
        configured_string?(map_value(telegram, :token)) or
          configured_string?(map_value(telegram, :bot_token)),
      token_secret_configured: configured_string?(map_value(telegram, :bot_token_secret)),
      allowed_peer_count:
        telegram
        |> map_value(:allowed_chat_ids)
        |> RuntimeState.parse_allowed_chat_ids()
        |> List.wrap()
        |> length(),
      allow_all_peers: map_value(telegram, :allow_all_chats, false) == true,
      deny_unbound_peers: map_value(telegram, :deny_unbound_chats, false) == true,
      binding_count: Enum.count(bindings, &(transport(&1) == :telegram)),
      topic_binding_count:
        Enum.count(bindings, &(transport(&1) == :telegram and present?(&1[:topic_id]))),
      files: file_status(files),
      compaction: compaction_status(map_value(telegram, :compaction, %{})),
      voice_transcription: %{
        enabled: map_value(telegram, :voice_transcription, false) == true,
        provider: telegram_voice_provider(telegram),
        model_configured: configured_string?(map_value(telegram, :voice_transcription_model)),
        base_url_configured:
          configured_string?(map_value(telegram, :voice_transcription_base_url)),
        api_key_required: telegram_voice_provider(telegram) != "local_transcript",
        api_key_configured: configured_string?(map_value(telegram, :voice_transcription_api_key))
      }
    }
  end

  defp telegram_voice_provider(telegram) do
    case map_value(telegram, :voice_transcription_provider, "openai_transcribe") do
      provider when is_binary(provider) and provider != "" -> provider
      _ -> "openai_transcribe"
    end
  end

  defp discord_status(gateway, bindings) do
    discord = Map.get(gateway, :discord, %{}) || %{}
    files = map_value(discord, :files, %{}) || %{}

    %{
      transport: "discord",
      enabled: Map.get(gateway, :enable_discord) == true,
      token_configured: configured_string?(map_value(discord, :bot_token)),
      token_secret_configured: configured_string?(map_value(discord, :bot_token_secret)),
      allowed_guild_count: length(List.wrap(map_value(discord, :allowed_guild_ids, []))),
      allowed_channel_count: length(List.wrap(map_value(discord, :allowed_channel_ids, []))),
      deny_unbound_channels: map_value(discord, :deny_unbound_channels, false) == true,
      binding_count: Enum.count(bindings, &(transport(&1) == :discord)),
      files: file_status(files),
      bot_message_policy: discord_bot_message_policy(),
      direct_messages: discord_direct_message_status(),
      free_response: discord_free_response_status(discord),
      inbound_replay: discord_inbound_replay_status(),
      slash_commands: discord_slash_command_status()
    }
  end

  defp discord_bot_message_policy do
    %{
      ignores_self_messages: true,
      ignores_webhooks: true,
      external_bot_messages_allowed: true,
      external_bot_messages_stable: false
    }
  end

  defp discord_direct_message_status do
    %{
      prompt_round_trip_supported: true,
      requires_reachable_dm_channel: true,
      bot_to_bot_dm_stable: false
    }
  end

  defp discord_free_response_status(discord) do
    %{
      trigger_command_supported: true,
      default_mode: "mentions",
      all_messages_mode_supported: true,
      requires_message_content_intent: true,
      runtime_requests_message_content_intent: true,
      message_content_intent_declared:
        truthy?(map_value(discord, :message_content_intent_enabled, false)) or
          truthy?(map_value(discord, :message_content_intent, false))
    }
  end

  defp discord_inbound_replay_status do
    %{
      duplicate_message_suppression_supported: true,
      persisted_idempotency_supported: true
    }
  end

  defp discord_slash_command_status do
    commands =
      LemonChannels.Adapters.Discord.SlashCommands.slash_commands()
      |> Enum.map(& &1.name)

    %{
      schema_export_supported: true,
      expected_command_count: length(commands),
      expected_commands: commands,
      compatibility_commands: %{
        checkpoint: "checkpoint" in commands,
        rollback: "rollback" in commands,
        kanban: "kanban" in commands,
        media: "media" in commands
      }
    }
  end

  defp file_status(files) when is_map(files) do
    %{
      enabled: truthy?(map_value(files, :enabled, false)),
      auto_put: truthy?(map_value(files, :auto_put, false)),
      auto_send_generated_files: auto_send_generated_files?(files),
      auto_send_generated_max_files:
        positive_integer(map_value(files, :auto_send_generated_max_files)),
      max_upload_bytes_configured: present?(map_value(files, :max_upload_bytes)),
      max_download_bytes_configured: present?(map_value(files, :max_download_bytes)),
      deny_glob_count: length(List.wrap(map_value(files, :deny_globs, []))),
      allowed_user_count: length(List.wrap(map_value(files, :allowed_user_ids, [])))
    }
  end

  defp file_status(_), do: file_status(%{})

  defp compaction_status(compaction) when is_map(compaction) do
    %{
      enabled: map_value(compaction, :enabled, false) == true,
      context_window_configured: present?(map_value(compaction, :context_window_tokens)),
      reserve_configured: present?(map_value(compaction, :reserve_tokens)),
      trigger_ratio_configured: present?(map_value(compaction, :trigger_ratio))
    }
  end

  defp compaction_status(_), do: compaction_status(%{})

  defp transport(%{transport: transport}) when transport in @reported_transports,
    do: transport

  defp transport(%{transport: transport}) when is_binary(transport), do: safe_transport(transport)
  defp transport(_), do: nil

  defp safe_transport("telegram"), do: :telegram
  defp safe_transport("discord"), do: :discord
  defp safe_transport(_), do: nil

  defp auto_send_generated_files?(files) do
    truthy?(map_value(files, :auto_send_generated_files, false)) or
      truthy?(map_value(files, :auto_send_generated_images, false))
  end

  defp truthy?(value), do: value in [true, "true", 1]
  defp configured_string?(value), do: is_binary(value) and String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_), do: nil

  defp map_value(map, key, default \\ nil)

  defp map_value(map, key, default) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key)) || default
  end

  defp map_value(_, _, default), do: default
end
