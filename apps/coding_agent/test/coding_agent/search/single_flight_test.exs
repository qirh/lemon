defmodule CodingAgent.Search.SingleFlightTest do
  use ExUnit.Case, async: false

  import CodingAgent.AsyncHelpers

  alias CodingAgent.Search.SingleFlight

  test "coalesces concurrent work and returns one result to every caller" do
    counter = :counters.new(1, [:atomics])
    test_pid = self()

    # Hold the operation open until every caller has joined the flight, so the
    # result does not depend on how quickly the callers are scheduled.
    operation = fn ->
      :counters.add(counter, 1, 1)
      send(test_pid, {:operation_started, self()})

      receive do
        :finish -> {:ok, :shared}
      after
        10_000 -> {:error, :never_released}
      end
    end

    tasks =
      for _ <- 1..12 do
        Task.async(fn -> SingleFlight.run(:same_query, operation, 15_000) end)
      end

    assert_receive {:operation_started, operation_pid}, 5_000

    assert_eventually(
      fn ->
        case :sys.get_state(SingleFlight).by_key do
          %{same_query: %{callers: callers}} -> length(callers) == 12
          _ -> false
        end
      end,
      timeout: 5_000,
      message: "not every caller joined the flight"
    )

    send(operation_pid, :finish)
    results = Task.await_many(tasks, 5_000)

    assert Enum.uniq(results) == [{:ok, :shared}]
    assert :counters.get(counter, 1) == 1
  end

  test "contains task exceptions" do
    assert {:error, {:single_flight_exception, "boom"}} =
             SingleFlight.run(make_ref(), fn -> raise "boom" end, 1_000)
  end
end
