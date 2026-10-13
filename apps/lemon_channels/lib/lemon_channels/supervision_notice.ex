defmodule LemonChannels.SupervisionNotice do
  @moduledoc false

  @kinds [:goal, :kanban, :cron]
  @statuses [:completed, :failed, :cancelled]

  @spec identity(term()) :: {:ok, LemonChannels.SupervisionStore.identity()} | {:error, atom()}
  def identity(%{kind: kind, id: id, run_id: run_id, status: status}),
    do: identity({kind, id, run_id, status})

  def identity({kind, id, run_id, status}) when kind in @kinds and status in @statuses do
    if identifier?(id) and identifier?(run_id),
      do: {:ok, {kind, id, run_id, status}},
      else: {:error, :invalid_notice}
  end

  def identity(_), do: {:error, :invalid_notice}

  @spec render(term()) :: {:ok, tuple(), binary()} | {:error, atom()}
  def render(notice) when is_map(notice) do
    with {:ok, {kind, id, run_id, status} = identity} <- identity(notice),
         {:ok, title} <- optional_text(notice[:title], 120),
         {:ok, summary} <- optional_text(notice[:summary], 640),
         {:ok, commit} <- commit(notice[:commit_sha]),
         {:ok, pr} <- pr(notice[:pr_url]) do
      text =
        [
          "#{kind |> Atom.to_string() |> String.capitalize()} `#{id}`: #{status}",
          "Run: `#{run_id}`",
          title,
          summary,
          if(commit, do: "Commit: #{commit}"),
          if(pr, do: "PR: #{pr}")
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")

      {:ok, identity, text}
    end
  end

  def render(_), do: {:error, :invalid_notice}

  @spec target(term()) :: {:ok, map()} | {:error, :invalid_target}
  def target(%{channel_id: channel, account_id: account, peer: %{kind: kind, id: id} = peer})
      when is_binary(channel) and kind in [:dm, :group, :channel] do
    thread = Map.get(peer, :thread_id)
    channels = Enum.map(LemonCore.Config.Gateway.Channel.ids(), &Atom.to_string/1)

    if channel in channels and component?(account) and component?(id) and
         (is_nil(thread) or component?(thread)) do
      {:ok,
       %{channel_id: channel, account_id: account, peer: %{kind: kind, id: id, thread_id: thread}}}
    else
      {:error, :invalid_target}
    end
  end

  def target(_), do: {:error, :invalid_target}

  defp identifier?(value) when is_binary(value) and byte_size(value) in 1..128,
    do: String.valid?(value) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.:-]*\z/, value)

  defp identifier?(_), do: false

  defp component?(value) when is_binary(value) and byte_size(value) in 1..256,
    do: String.valid?(value) and not Regex.match?(~r/[\s\p{C}]/u, value)

  defp component?(_), do: false

  defp optional_text(nil, _limit), do: {:ok, nil}

  defp optional_text(value, limit) when is_binary(value) do
    if String.valid?(value) do
      text =
        value
        |> LemonCore.Redact.text(strict: true)
        |> String.replace(~r/[\p{C}<>`*_~\\\[\]]/u, " ")
        |> String.replace(~r/\s+/u, " ")
        |> String.trim()
        |> bound(limit)

      {:ok, text}
    else
      {:error, :invalid_notice}
    end
  end

  defp optional_text(_, _), do: {:error, :invalid_notice}

  defp commit(nil), do: {:ok, nil}

  defp commit(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9a-fA-F]{7,64}\z/, value),
      do: {:ok, value},
      else: {:error, :invalid_notice}
  end

  defp commit(_), do: {:error, :invalid_notice}

  defp pr(nil), do: {:ok, nil}

  defp pr(value) when is_binary(value) and byte_size(value) <= 360 do
    case URI.new(value) do
      {:ok,
       %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil, path: path}}
      when is_binary(host) and host != "" and is_binary(path) ->
        if Regex.match?(~r/\A\/[A-Za-z0-9_.\/-]+\/(?:pull|merge_requests)\/[0-9]+\z/, path),
          do: {:ok, value},
          else: {:error, :invalid_notice}

      _ ->
        {:error, :invalid_notice}
    end
  end

  defp pr(_), do: {:error, :invalid_notice}

  # Bound bytes, not graphemes: the result fits in one Telegram or Discord send,
  # including Unicode astral characters, so one Outbox receipt covers it all.
  defp bound(value, limit) when byte_size(value) <= limit, do: value

  defp bound(value, limit) do
    prefix = binary_part(value, 0, limit - 3)
    valid_prefix(prefix) <> "..."
  end

  defp valid_prefix(value) do
    if String.valid?(value),
      do: value,
      else: valid_prefix(binary_part(value, 0, byte_size(value) - 1))
  end
end
