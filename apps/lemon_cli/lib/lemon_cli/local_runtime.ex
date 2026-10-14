defmodule LemonCli.LocalRuntime do
  @moduledoc """
  Starts the local Lemon runtime for one-shot commands that talk to it.

  Only the launcher knows how to start a runtime (release daemon vs. source
  `mix run`), so both launchers export `LEMON_LAUNCHER` with their own path
  before handing argv to `LemonCli.CLI`. When the control plane is not healthy,
  this runs `$LEMON_LAUNCHER daemon`, which starts the runtime with the managed
  operator credential and waits for health. Launcher progress goes to stderr
  so `--json` stdout stays machine-clean.

  Without `LEMON_LAUNCHER` (tests, direct `eval`), nothing is started and the
  command reports its own connection error.
  """

  @spec ensure_running(keyword()) :: :ok | {:error, String.t()}
  def ensure_running(opts \\ []) do
    launcher = Keyword.get(opts, :launcher, System.get_env("LEMON_LAUNCHER"))
    healthy? = Keyword.get(opts, :healthy?, &healthy?/0)

    cond do
      not is_binary(launcher) or launcher == "" -> :ok
      healthy?.() -> :ok
      true -> start(launcher)
    end
  end

  @doc """
  Whether the control plane on `LEMON_CONTROL_PLANE_PORT` (default 4040)
  answers `/healthz` with the documented `{"ok":true}` body. Any other
  listener on the port is not treated as Lemon.
  """
  @spec healthy?() :: boolean()
  def healthy? do
    port = System.get_env("LEMON_CONTROL_PLANE_PORT") || "4040"
    url = String.to_charlist("http://127.0.0.1:#{port}/healthz")

    with {:ok, _started} <- Application.ensure_all_started(:inets),
         {:ok, {{_version, 200, _reason}, _headers, body}} <-
           :httpc.request(:get, {url, []}, [timeout: 2_000, connect_timeout: 1_000],
             body_format: :binary
           ) do
      body =~ ~r/"ok"\s*:\s*true/
    else
      _ -> false
    end
  end

  defp start(launcher) do
    IO.puts(:stderr, "[lemon] runtime not running; starting it")

    case System.cmd(launcher, ["daemon"],
           into: IO.stream(:stderr, :line),
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {_output, status} -> {:error, "`lemon daemon` exited with status #{status}"}
    end
  rescue
    error in ErlangError ->
      {:error, "could not run #{launcher} daemon: #{Exception.message(error)}"}
  end
end
