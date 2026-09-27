defmodule LemonSimUi.DemoTest do
  @moduledoc """
  `mix lemon.sim.demo` start path: an offline Werewolf game started through
  the real SimManager with no provider API keys plays to a recorded finish.
  """

  use ExUnit.Case, async: false

  alias LemonCore.MapHelpers
  alias LemonSim.Kernel.Store
  alias LemonSimUi.{Demo, SimManager}

  setup do
    scrubbed =
      System.get_env()
      |> Enum.filter(fn {name, _value} -> String.ends_with?(name, "_API_KEY") end)

    Enum.each(scrubbed, fn {name, _value} -> System.delete_env(name) end)
    on_exit(fn -> Enum.each(scrubbed, fn {name, value} -> System.put_env(name, value) end) end)
    :ok
  end

  test "starts a keyless offline werewolf game that plays to a completed finish" do
    sim_id = start_demo!(seed: 42)

    assert Demo.watch_path(sim_id) == "/watch/#{sim_id}"

    stored = await_finish!(sim_id)
    run = stored.meta.run

    assert LemonSim.Examples.terminal?(stored)
    assert MapHelpers.get_key(stored.world, :winner) in ["villagers", "werewolves"]
    assert run.status == "completed"
    refute run.resumable
    assert run.model == nil
    assert MapHelpers.get_key(run.start_opts, :offline_strategy) == "heuristic"
    assert run.turns_completed > 0
    assert stored.plan_history != []
  end

  test "the same seed replays the same game" do
    [first, second] = Enum.map(1..2, fn _ -> 7 |> seeded_demo!() |> await_finish!() end)

    assert first.meta.run.turns_completed == second.meta.run.turns_completed
    assert outcome(first) == outcome(second)
  end

  defp seeded_demo!(seed), do: start_demo!(seed: seed)

  defp start_demo!(opts) do
    sim_id = "ww_demo_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      SimManager.stop_sim(sim_id)
      Store.delete_state(sim_id)
    end)

    assert {:ok, ^sim_id} =
             Demo.start_werewolf(Keyword.merge([sim_id: sim_id, step_delay_ms: 0], opts))

    sim_id
  end

  defp await_finish!(sim_id, attempts \\ 1_500) do
    cond do
      sim_id not in SimManager.list_running() ->
        Store.get_state(sim_id)

      attempts == 0 ->
        flunk("offline demo game #{sim_id} did not finish in time")

      true ->
        Process.sleep(20)
        await_finish!(sim_id, attempts - 1)
    end
  end

  defp outcome(state) do
    players =
      state.world
      |> MapHelpers.get_key(:players)
      |> Map.new(fn {id, player} ->
        {id, {MapHelpers.get_key(player, :role), MapHelpers.get_key(player, :status)}}
      end)

    {MapHelpers.get_key(state.world, :winner), players}
  end
end
