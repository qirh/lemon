defmodule LemonCore.Doctor.ChecksTest do
  use ExUnit.Case, async: false

  alias LemonCore.Doctor.Check

  alias LemonCore.Doctor.Checks.{
    Config,
    Memory,
    NodeTools,
    Providers,
    Runtime,
    Skills,
    Usage
  }

  describe "Config.run/1" do
    test "returns a list of Check structs" do
      checks = Config.run()
      assert is_list(checks)
      assert Enum.all?(checks, &match?(%Check{}, &1))
    end

    test "check names are unique" do
      names = Config.run() |> Enum.map(& &1.name)
      assert length(names) == length(Enum.uniq(names))
    end
  end

  describe "Runtime.run/1" do
    test "returns a list of Check structs" do
      checks = Runtime.run()
      assert is_list(checks)
      assert Enum.all?(checks, &match?(%Check{}, &1))
    end
  end

  describe "Providers.run/1" do
    test "returns a list of Check structs" do
      checks = Providers.run()
      assert is_list(checks)
      assert Enum.all?(checks, &match?(%Check{}, &1))
    end

    test "a named missing secret is not a usable default credential" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "doctor_missing_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(tmp_dir, ".lemon"))

      File.write!(Path.join(tmp_dir, ".lemon/config.toml"), """
      [defaults]
      provider = "doctor_test_provider"
      model = "doctor_test_provider:model"
      [providers.doctor_test_provider]
      api_key_secret = "doctor_missing_secret_#{System.unique_integer([:positive])}"
      """)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      check =
        Providers.run(project_dir: tmp_dir) |> Enum.find(&(&1.name == "providers.credentials"))

      assert check.status == :fail
      refute check.message =~ "doctor_missing_secret_"
    end

    test "provider routing check reports a ready fallback without leaking credentials" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "provider_routing_check_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(Path.join(tmp_dir, ".lemon"))

      File.write!(
        Path.join([tmp_dir, ".lemon", "config.toml"]),
        """
        [providers.zai]
        api_key = "private-zai-key"

        [defaults]
        provider = "openai"
        model = "glm-5-turbo"

        [runtime.provider_routing]
        fallback_providers = ["zai"]
        """
      )

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checks = Providers.run(project_dir: tmp_dir)
      routing_check = Enum.find(checks, &(&1.name == "providers.routing"))

      assert routing_check.status == :pass
      assert routing_check.message =~ "Default provider is not credential-ready"
      assert routing_check.message =~ "zai"
      refute inspect(routing_check) =~ "private-zai-key"
    end
  end

  describe "Usage.run/1" do
    test "returns a list of Check structs" do
      checks = Usage.run()
      assert is_list(checks)
      assert Enum.all?(checks, &match?(%Check{}, &1))
    end

    test "reports safe aggregate usage without leaking stored prompt or credential fields" do
      checks =
        Usage.run(
          summary: %{
            total_cost: 0.42,
            total_requests: 3,
            total_tokens: %{input: 1_000, output: 500},
            breakdown: %{"openai" => 0.42},
            requests: %{"openai" => 3},
            tokens: %{"openai" => %{input: 1_000, output: 500}},
            prompt: "private usage prompt",
            api_key: "usage-secret-key"
          },
          today: %{date: Date.to_iso8601(Date.utc_today()), total_cost: 0.42},
          quotas: %{runs_limit: 10, tokens_limit: 2_000, cost_limit: 1.0}
        )

      usage = Enum.find(checks, &(&1.name == "usage.status"))

      assert usage.status == :pass
      assert usage.message =~ "3 request(s)"
      assert usage.message =~ "1500 token(s)"
      assert usage.message =~ "1 provider(s)"
      refute inspect(usage) =~ "private usage prompt"
      refute inspect(usage) =~ "usage-secret-key"
    end

    test "warns when configured usage quotas are exceeded" do
      checks =
        Usage.run(
          summary: %{
            total_cost: 1.5,
            total_requests: 3,
            total_tokens: %{input: 1_000, output: 500}
          },
          quotas: %{runs_limit: 2, tokens_limit: 1_000, cost_limit: 1.0}
        )

      usage = Enum.find(checks, &(&1.name == "usage.status"))

      assert usage.status == :warn
      assert usage.message =~ "over a configured quota"
      assert usage.remediation =~ "`usage.status`"
    end
  end

  describe "NodeTools.run/1" do
    test "returns a check per binary" do
      checks = NodeTools.run()
      assert is_list(checks)
      assert checks != []
    end

    test "git check is present" do
      checks = NodeTools.run()
      assert Enum.any?(checks, &String.contains?(&1.name, "git"))
    end

    test "git check passes when git is on PATH" do
      # In CI/dev environments git is always available
      if System.find_executable("git") do
        checks = NodeTools.run()
        git_check = Enum.find(checks, &String.contains?(&1.name, "git"))
        assert git_check.status == :pass
      end
    end
  end

  describe "Skills.run/1" do
    test "returns a list of Check structs" do
      checks = Skills.run()
      assert is_list(checks)
      assert Enum.all?(checks, &match?(%Check{}, &1))
    end

    test "skills directory check has expected name" do
      checks = Skills.run()
      assert Enum.any?(checks, &(&1.name == "skills.directory"))
    end
  end

  defmodule StubMemoryStore do
    def stats do
      %{total: 3, oldest_ms: 1, newest_ms: System.system_time(:millisecond) - 120_000}
    end
  end

  describe "Memory.run/1" do
    alias LemonCore.Config.Features

    test "returns a list of Check structs" do
      checks = Memory.run(features: %Features{session_search: :off})
      assert is_list(checks)
      assert Enum.all?(checks, &match?(%Check{}, &1))
    end

    test "reports inactive memory when session_search is off" do
      checks = Memory.run(features: %Features{session_search: :off})
      check = Enum.find(checks, &(&1.name == "memory.session_search"))

      assert check.status == :pass
      assert check.message =~ "session_search is off"
      assert check.message =~ "inactive"
    end

    test "reports inactive memory when session_search is opt-in" do
      checks = Memory.run(features: %Features{session_search: :"opt-in"})
      check = Enum.find(checks, &(&1.name == "memory.session_search"))

      assert check.status == :pass
      assert check.message =~ "session_search is opt-in"
    end

    test "warns with the kill switch when default-on but exqlite is unavailable" do
      checks =
        Memory.run(
          features: %Features{session_search: :"default-on"},
          exqlite_loaded: false
        )

      check = Enum.find(checks, &(&1.name == "memory.session_search"))

      assert check.status == :warn
      assert check.message =~ "exqlite SQLite NIF is not loaded"
      assert check.remediation =~ "LEMON_FEATURE_SESSION_SEARCH=off"
    end

    test "warns when default-on but the store module is missing" do
      checks =
        Memory.run(
          features: %Features{session_search: :"default-on"},
          exqlite_loaded: true,
          store_module: LemonCore.Doctor.ChecksTest.NoSuchStore
        )

      check = Enum.find(checks, &(&1.name == "memory.session_search"))

      assert check.status == :warn
      assert check.message =~ "store module is not loaded"
      assert check.remediation =~ "LEMON_FEATURE_SESSION_SEARCH=off"
    end

    test "warns when default-on but the store process is not running" do
      checks =
        Memory.run(
          features: %Features{session_search: :"default-on"},
          exqlite_loaded: true,
          store_module: StubMemoryStore
        )

      check = Enum.find(checks, &(&1.name == "memory.session_search"))

      assert check.status == :warn
      assert check.message =~ "store process is not running"
      assert check.remediation =~ "LEMON_FEATURE_SESSION_SEARCH=off"
    end

    test "does not infer external runtime memory failure from an absent CLI-local process" do
      [check] =
        Memory.run(
          features: %Features{session_search: :"default-on"},
          exqlite_loaded: true,
          store_module: StubMemoryStore,
          external_runtime?: true
        )

      assert check.status == :skip
      assert check.remediation == nil
    end

    test "an external runtime does not conceal missing local memory dependencies" do
      for opts <- [
            [exqlite_loaded: false],
            [exqlite_loaded: true, store_module: LemonCore.Doctor.ChecksTest.NoSuchStore]
          ] do
        [check] =
          Memory.run(
            [features: %Features{session_search: :"default-on"}, external_runtime?: true] ++ opts
          )

        assert check.status == :warn
      end
    end

    test "passes with document count, db size, and ingest recency when the store is up" do
      {:ok, agent} = Agent.start_link(fn -> :ok end, name: StubMemoryStore)
      on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

      db_path = Path.join(tmp_dir("memory_check_db"), "memory.sqlite3")
      File.mkdir_p!(Path.dirname(db_path))
      File.write!(db_path, String.duplicate("x", 2048))
      on_exit(fn -> File.rm_rf!(Path.dirname(db_path)) end)

      checks =
        Memory.run(
          features: %Features{session_search: :"default-on"},
          exqlite_loaded: true,
          store_module: StubMemoryStore,
          store_path: db_path
        )

      check = Enum.find(checks, &(&1.name == "memory.session_search"))

      assert check.status == :pass
      assert check.message =~ "session_search is default-on"
      assert check.message =~ "3 document(s)"
      assert check.message =~ "db 2.0 KB"
      assert check.message =~ "last ingest 2m ago"
    end
  end

  defp tmp_dir(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
  end
end
