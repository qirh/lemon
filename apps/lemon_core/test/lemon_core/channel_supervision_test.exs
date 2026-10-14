defmodule LemonCore.ChannelSupervisionTest do
  use ExUnit.Case, async: false

  alias LemonCore.ChannelSupervision

  defmodule Provider do
    @behaviour LemonCore.ChannelSupervision

    @impl true
    def bind_run(run_id, session_key, target),
      do: answer(:bind_run, [run_id, session_key, target])

    @impl true
    def target_for_run(run_id, session_key), do: answer(:target_for_run, [run_id, session_key])

    @impl true
    def notify(target, notice), do: answer(:notify, [target, notice])

    defp answer(function, args) do
      send(self(), {:provider_call, function, args})
      Process.get({__MODULE__, :answer}).()
    end
  end

  defmodule PartialProvider do
    def bind_run(_, _, _), do: :ok
  end

  setup do
    original = Application.fetch_env(:lemon_core, :channel_supervision_provider)
    Application.delete_env(:lemon_core, :channel_supervision_provider)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:lemon_core, :channel_supervision_provider, value)
        :error -> Application.delete_env(:lemon_core, :channel_supervision_provider)
      end
    end)

    :ok
  end

  test "missing providers and callbacks are explicitly unavailable" do
    for provider <- [nil, __MODULE__.MissingProvider, "not a module"] do
      Application.put_env(:lemon_core, :channel_supervision_provider, provider)
      assert ChannelSupervision.bind_run("run", "session", target()) == unavailable()
      assert ChannelSupervision.target_for_run("run", "session") == unavailable()
      assert ChannelSupervision.notify(target(), %{}) == unavailable()
    end

    Application.put_env(:lemon_core, :channel_supervision_provider, PartialProvider)
    assert :ok = ChannelSupervision.bind_run("run", "session", target())
    assert ChannelSupervision.target_for_run("run", "session") == unavailable()
    assert ChannelSupervision.notify(target(), %{}) == unavailable()
  end

  test "registration rejects missing and partial providers without replacing the provider" do
    assert :ok = ChannelSupervision.register(Provider)

    for provider <- [nil, "not a module", __MODULE__.MissingProvider, PartialProvider] do
      assert {:error, :not_a_provider} = ChannelSupervision.register(provider)
      assert ChannelSupervision.provider() == Provider
    end
  end

  test "forwards exact arguments and results without requiring a registered process" do
    assert :ok = ChannelSupervision.register(Provider)
    assert Process.whereis(Provider) == nil
    target = target()
    notice = %{kind: :cron, id: "job", run_id: "run", status: :completed}

    answer(fn -> :ok end)
    assert :ok = ChannelSupervision.bind_run("run", "session", target)
    assert_received {:provider_call, :bind_run, ["run", "session", ^target]}
    assert :ok = ChannelSupervision.notify(target, notice)
    assert_received {:provider_call, :notify, [^target, ^notice]}

    answer(fn -> {:ok, target} end)
    assert {:ok, ^target} = ChannelSupervision.target_for_run("run", "session")
    assert_received {:provider_call, :target_for_run, ["run", "session"]}

    answer(fn -> :none end)
    assert :none = ChannelSupervision.target_for_run("run", "session")
  end

  test "explicit provider rejections and unknown outcomes remain unchanged" do
    assert :ok = ChannelSupervision.register(Provider)

    for reason <- [
          :binding_conflict,
          :store_unavailable,
          :supervision_unavailable,
          :outcome_unknown
        ] do
      answer(fn -> {:error, reason} end)
      assert {:error, ^reason} = ChannelSupervision.bind_run("run", "session", target())
      assert {:error, ^reason} = ChannelSupervision.target_for_run("run", "session")
      assert {:error, ^reason} = ChannelSupervision.notify(target(), %{})
    end
  end

  test "failed and malformed calls cannot turn into absence or definite mutation rejection" do
    assert :ok = ChannelSupervision.register(Provider)

    for failure <- [
          fn -> raise "private callback detail" end,
          fn -> exit({:noproc, "private callback detail"}) end,
          fn -> exit({:timeout, "private callback detail"}) end,
          fn -> throw("private callback detail") end,
          fn -> {:unexpected, "private callback detail"} end,
          fn -> {:error, {:private, "callback detail"}} end
        ] do
      answer(failure)
      assert {:error, :outcome_unknown} = ChannelSupervision.bind_run("run", "session", target())
      assert {:error, :outcome_unknown} = ChannelSupervision.notify(target(), %{})
      assert {:error, :query_failed} = ChannelSupervision.target_for_run("run", "session")
    end

    answer(fn -> :none end)
    assert {:error, :outcome_unknown} = ChannelSupervision.notify(target(), %{})
    answer(fn -> :ok end)
    assert {:error, :query_failed} = ChannelSupervision.target_for_run("run", "session")

    for malformed <- [{:ok, nil}, {:ok, %{}}] do
      answer(fn -> malformed end)
      assert {:error, :query_failed} = ChannelSupervision.target_for_run("run", "session")
      assert {:error, :outcome_unknown} = ChannelSupervision.bind_run("run", "session", target())
    end
  end

  defp answer(fun), do: Process.put({Provider, :answer}, fun)
  defp unavailable, do: {:error, :channels_unavailable}

  defp target do
    %{channel_id: "telegram", account_id: "work", peer: %{kind: :group, id: "-100"}}
  end
end
