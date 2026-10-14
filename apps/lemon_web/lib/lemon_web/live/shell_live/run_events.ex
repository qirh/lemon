defmodule LemonWeb.ShellLive.RunEvents do
  @moduledoc """
  Global run start/stop feed for the web shell's notifications.

  Run lifecycle events are published per run (`run:<id>`) and per session
  (`session:<key>`); nothing on the Bus announces every run. The runtime does
  emit `[:lemon, :run, :start]` (with `run_id`/`session_key`) and
  `[:lemon, :run, :stop]` telemetry for every run, so one process-wide handler
  (fixed id, attached idempotently) re-publishes those two facts on the
  web-internal Bus topic `"lemon_web:runs"` as
  `{:lemon_web_run, :started | :stopped, %{run_id, session_key, ok, duration_ms}}`.
  The shell then subscribes to the exact `run:<id>` topic for the projected
  completion.

  The handler only copies ids, a boolean and an integer and never raises, so
  telemetry never detaches it.
  """

  alias LemonCore.Bus

  @topic "lemon_web:runs"
  @handler_id "lemon_web.shell.run_events"
  @events [[:lemon, :run, :start], [:lemon, :run, :stop]]

  @doc "Bus topic carrying `{:lemon_web_run, phase, info}` messages."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Attaches the telemetry handler once per VM; safe to call repeatedly."
  @spec attach() :: :ok
  def attach do
    case :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  def handle_event([:lemon, :run, phase], measurements, metadata, _config)
      when phase in [:start, :stop] and is_map(metadata) do
    with run_id when is_binary(run_id) <- Map.get(metadata, :run_id) do
      info = %{
        run_id: run_id,
        session_key: string(Map.get(metadata, :session_key)),
        ok: if(is_map(measurements), do: Map.get(measurements, :ok)),
        duration_ms: if(is_map(measurements), do: integer(Map.get(measurements, :duration_ms)))
      }

      Bus.broadcast(@topic, {:lemon_web_run, phase_name(phase), info})
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  defp phase_name(:start), do: :started
  defp phase_name(:stop), do: :stopped

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_), do: nil

  defp integer(value) when is_integer(value), do: value
  defp integer(_), do: nil
end
