defmodule LemonChannels.Adapters.Telegram.Transport.RuntimeState do
  @moduledoc """
  Small helper over Telegram transport runtime state.

  This keeps adapter-owned runtime state explicit without turning the transport
  into a large struct migration in the middle of the PR5 seam refactor.
  """

  @unpaired_notice_interval_ms 10 * 60 * 1000

  @default_fields %{
    buffers: %{},
    media_groups: %{},
    pending_new: %{},
    reaction_runs: %{},
    model_pickers: %{},
    unpaired_notices: %{},
    last_poll_error: nil,
    last_poll_error_log_ts: nil,
    last_webhook_clear_ts: nil
  }

  @spec new(map()) :: map()
  def new(attrs) when is_map(attrs) do
    Map.merge(@default_fields, attrs)
  end

  @spec parse_allowed_chat_ids(term()) :: [integer()] | nil
  def parse_allowed_chat_ids(nil), do: nil

  def parse_allowed_chat_ids(list) when is_list(list) do
    parsed =
      list
      |> Enum.map(&parse_int/1)
      |> Enum.filter(&is_integer/1)

    if parsed == [], do: [], else: parsed
  end

  def parse_allowed_chat_ids(_), do: nil

  @doc """
  Record that an unpaired chat was told how to pair the bot.

  Returns `{state, true}` when the notice should be sent now, or
  `{state, false}` when this chat was already notified within the rate-limit
  window. Expired entries are pruned on every call so strangers cannot grow the
  map without bound.
  """
  @spec claim_unpaired_notice(map(), integer(), integer()) :: {map(), boolean()}
  def claim_unpaired_notice(state, chat_id, now_ms)
      when is_map(state) and is_integer(chat_id) and is_integer(now_ms) do
    notices =
      state
      |> Map.get(:unpaired_notices, %{})
      |> Map.reject(fn {_chat_id, sent_ms} ->
        now_ms - sent_ms >= @unpaired_notice_interval_ms
      end)

    if Map.has_key?(notices, chat_id) do
      {Map.put(state, :unpaired_notices, notices), false}
    else
      {Map.put(state, :unpaired_notices, Map.put(notices, chat_id, now_ms)), true}
    end
  end

  def claim_unpaired_notice(state, _chat_id, _now_ms), do: {state, false}

  @spec initial_offset(integer() | nil, integer() | nil, boolean()) :: integer()
  def initial_offset(config_offset, stored_offset, drop_pending_updates?) do
    if drop_pending_updates? do
      0
    else
      cond do
        is_integer(config_offset) -> config_offset
        is_integer(stored_offset) -> stored_offset
        true -> 0
      end
    end
  end

  @spec take_current_buffer(map(), term(), reference()) :: {map(), map() | nil}
  def take_current_buffer(state, scope_key, debounce_ref) when is_map(state) do
    take_current_entry(state, :buffers, scope_key, debounce_ref)
  end

  @spec take_current_media_group(map(), term(), reference()) :: {map(), map() | nil}
  def take_current_media_group(state, group_key, debounce_ref) when is_map(state) do
    take_current_entry(state, :media_groups, group_key, debounce_ref)
  end

  defp take_current_entry(state, key, entry_key, debounce_ref) do
    entries = Map.get(state, key, %{})
    {entry, rest} = Map.pop(entries, entry_key)

    cond do
      is_map(entry) and entry[:debounce_ref] == debounce_ref ->
        {Map.put(state, key, rest), entry}

      is_map(entry) ->
        {Map.put(state, key, Map.put(entries, entry_key, entry)), nil}

      true ->
        {state, nil}
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(i) when is_integer(i), do: i

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp parse_int(_), do: nil
end
