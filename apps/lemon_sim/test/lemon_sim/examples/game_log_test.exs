defmodule LemonSim.Examples.GameLogTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.GameLog

  @domains [
    {LemonSim.Examples.Poker.GameLog, :log_game_over,
     %{"status" => "complete", "current_actor_id" => "seat-2", "completed_hands" => 3},
     %{"winner" => "actor-2"}}
  ]

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_sim_game_log_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  test "scenario loggers preserve their public APIs and JSONL entry shapes", %{tmp_dir: tmp_dir} do
    world = %{
      current_actor_id: "seat-2",
      completed_hands: 3,
      status: "complete",
      winner: "actor-2"
    }

    events = [
      %{kind: "action", payload: %{position: {2, 3}}},
      %{"kind" => "result", "payload" => %{"ok" => true}},
      %{custom: "preserved"},
      :ignored
    ]

    Enum.each(@domains, fn {module, terminal_function, step_metadata, terminal_metadata} ->
      path = Path.join(tmp_dir, "#{inspect(module)}.jsonl")
      log = module.start(path)

      assert :ok = module.log_init(log, world)
      assert :ok = module.log_step(log, 3, world, events)
      assert :ok = apply(module, terminal_function, [log, 4, world])
      assert :ok = module.stop(log)

      [init_entry, step_entry, terminal_entry] = module.read_log(path)

      assert_entry(init_entry, %{"type" => "init", "step" => 0, "events" => []}, module)

      assert_entry(
        step_entry,
        Map.merge(
          %{
            "type" => "step",
            "step" => 3,
            "events" => [
              %{"kind" => "action", "payload" => %{"position" => [2, 3]}},
              %{"kind" => "result", "payload" => %{"ok" => true}},
              %{"custom" => "preserved"}
            ]
          },
          step_metadata
        ),
        module
      )

      assert_entry(
        terminal_entry,
        terminal_metadata
        |> Map.put_new("type", "game_over")
        |> Map.merge(%{"step" => 4, "events" => []}),
        module
      )

      assert :ok = module.log_init(nil, :not_a_world)
      assert :ok = module.log_step(nil, 3, :not_a_world, :not_events)
      assert :ok = apply(module, terminal_function, [nil, 4, :not_a_world])
      assert :ok = module.stop(nil)
    end)
  end

  test "shared encoding recursively sanitizes tuples and map sets", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "shared.jsonl")
    log = GameLog.start(path)

    assert :ok =
             GameLog.write_entry(log, %{
               type: "custom",
               tuple: {:ok, 2},
               set: MapSet.new(["beta", "alpha"])
             })

    assert :ok = GameLog.stop(log)
    [entry] = GameLog.read_log(path)

    assert entry["tuple"] == ["ok", 2]
    assert Enum.sort(entry["set"]) == ["alpha", "beta"]
    assert_timestamp(entry)
  end

  defp assert_entry(entry, expected_metadata, module) do
    assert Map.drop(entry, ["timestamp", "world"]) == expected_metadata,
           "unexpected JSONL shape for #{inspect(module)}"

    assert is_map(entry["world"])
    assert_timestamp(entry)
  end

  defp assert_timestamp(entry) do
    assert {:ok, _datetime, 0} = DateTime.from_iso8601(entry["timestamp"])
  end
end
