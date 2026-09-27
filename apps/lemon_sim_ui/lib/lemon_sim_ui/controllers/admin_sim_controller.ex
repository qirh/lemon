defmodule LemonSimUi.AdminSimController do
  use LemonSimUi, :controller

  alias LemonSimUi.SimManager

  @watchable_domains ~w(werewolf vending_bench)a

  def create(conn, params) do
    with {:ok, domain} <- parse_domain(params["domain"]),
         {:ok, opts} <- build_start_opts(domain, params),
         {:ok, sim_id} <- SimManager.start_sim(domain, opts) do
      payload = %{
        "sim_id" => sim_id,
        "domain" => Atom.to_string(domain),
        "admin_url" => url(~p"/admin/sims/#{sim_id}"),
        "watch_url" => watch_url(domain, sim_id)
      }

      conn
      |> put_status(:created)
      |> json(payload)
    else
      {:error, :invalid_domain} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => "invalid_domain"})

      {:error, :already_exists} ->
        conn
        |> put_status(:conflict)
        |> json(%{"error" => "already_exists"})

      {:error, :capacity_exceeded} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{"error" => "capacity_exceeded"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => format_reason(reason)})
    end
  end

  def stop(conn, %{"sim_id" => sim_id}) do
    case SimManager.stop_sim(sim_id) do
      :ok ->
        json(conn, %{"sim_id" => sim_id, "status" => "stopped"})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => "not_found"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => format_reason(reason)})
    end
  end

  defp parse_domain(domain) when is_binary(domain) do
    case String.trim(domain) do
      "" ->
        {:error, :invalid_domain}

      trimmed ->
        atom = String.to_existing_atom(trimmed)

        if domain_supported?(atom) do
          {:ok, atom}
        else
          {:error, :invalid_domain}
        end
    end
  rescue
    ArgumentError -> {:error, :invalid_domain}
  end

  defp parse_domain(_), do: {:error, :invalid_domain}

  defp domain_supported?(domain) do
    domain in [:tic_tac_toe, :werewolf, :vending_bench]
  end

  defp build_start_opts(:tic_tac_toe, params) do
    {:ok,
     []
     |> maybe_put_string(:sim_id, params["sim_id"])
     |> maybe_put_int(:max_turns, params["max_turns"])}
  end

  defp build_start_opts(:vending_bench, params) do
    {:ok,
     []
     |> maybe_put_string(:sim_id, params["sim_id"])
     |> maybe_put_int(:max_days, params["max_days"])
     |> maybe_put_int(:max_turns, params["max_turns"])
     |> maybe_put_int(:driver_max_turns, params["driver_max_turns"])
     |> maybe_put_string(:operator_model_spec, params["operator_model_spec"])
     |> maybe_put_string(:physical_worker_model_spec, params["physical_worker_model_spec"])
     |> maybe_put_string(:model_spec, params["model_spec"])
     |> maybe_put_string(:worker_model_spec, params["worker_model_spec"])}
  end

  defp build_start_opts(:werewolf, params) do
    with {:ok, sim_id} <- parse_optional_sim_id(params["sim_id"]),
         {:ok, player_count} <- parse_optional_int(params["player_count"], 5..8, 6),
         {:ok, model_specs} <- parse_model_specs(params["model_specs"]),
         :ok <- validate_model_count(model_specs, player_count) do
      opts =
        [player_count: player_count]
        |> maybe_put_string(:sim_id, sim_id)

      opts = if model_specs == [], do: opts, else: Keyword.put(opts, :model_specs, model_specs)
      {:ok, opts}
    end
  end

  defp maybe_put_int(opts, _key, nil), do: opts

  defp maybe_put_int(opts, key, value) do
    case parse_int(value) do
      nil -> opts
      parsed -> Keyword.put(opts, key, parsed)
    end
  end

  defp maybe_put_string(opts, _key, nil), do: opts

  defp maybe_put_string(opts, key, value) do
    case normalize_string(value) do
      nil -> opts
      parsed -> Keyword.put(opts, key, parsed)
    end
  end

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

  defp parse_optional_int(nil, _range, default), do: {:ok, default}

  defp parse_optional_int(value, range, _default) do
    case parse_int(value) do
      parsed when is_integer(parsed) ->
        if parsed in range, do: {:ok, parsed}, else: {:error, :invalid_player_count}

      _ ->
        {:error, :invalid_player_count}
    end
  end

  defp parse_optional_sim_id(nil), do: {:ok, nil}

  defp parse_optional_sim_id(value) do
    case normalize_string(value) do
      id when is_binary(id) and byte_size(id) <= 80 ->
        if Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]*\z/, id),
          do: {:ok, id},
          else: {:error, :invalid_sim_id}

      _ ->
        {:error, :invalid_sim_id}
    end
  end

  defp parse_model_specs(nil), do: {:ok, []}

  defp parse_model_specs(specs) when is_list(specs) do
    Enum.reduce_while(specs, {:ok, []}, fn raw, {:ok, acc} ->
      case normalize_model_spec(raw) do
        {:ok, spec} -> {:cont, {:ok, acc ++ [spec]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_model_specs(_), do: {:error, :invalid_model_specs}

  defp normalize_model_spec(value) when is_binary(value) and byte_size(value) <= 200 do
    case value |> String.split(":", parts: 2) |> Enum.map(&String.trim/1) do
      [provider, model] when provider != "" and model != "" -> {:ok, "#{provider}:#{model}"}
      _ -> {:error, :invalid_model_specs}
    end
  end

  defp normalize_model_spec(_), do: {:error, :invalid_model_specs}

  defp validate_model_count([], _player_count), do: :ok

  defp validate_model_count(model_specs, player_count) do
    if length(model_specs) == player_count,
      do: :ok,
      else: {:error, :invalid_model_count}
  end

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_), do: nil

  defp watch_url(domain, sim_id) when domain in @watchable_domains, do: url(~p"/watch/#{sim_id}")
  defp watch_url(_domain, _sim_id), do: nil

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)
end
