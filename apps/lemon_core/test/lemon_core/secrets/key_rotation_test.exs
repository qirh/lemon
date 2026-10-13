defmodule LemonCore.Secrets.KeyRotationTest do
  # Shares the global Store's secrets table with other suites.
  use ExUnit.Case, async: false

  alias LemonCore.Clock
  alias LemonCore.Secrets
  alias LemonCore.Secrets.{Crypto, KeyProvider, KeyRotation}
  alias LemonCore.Store

  # Reads the real key file, then "crashes" before the new key is stored.
  defmodule CrashBeforeSwitch do
    use LemonCore.Secrets.KeyProvider

    @impl true
    def name, do: :file

    @impl true
    def fetch(opts), do: KeyProvider.File.fetch(opts)

    @impl true
    def put(_value, _opts), do: raise("simulated crash before the key switch")
  end

  # Stores the new key, then "crashes" before any record is promoted.
  defmodule CrashAfterSwitch do
    use LemonCore.Secrets.KeyProvider

    @impl true
    def name, do: :file

    @impl true
    def fetch(opts), do: KeyProvider.File.fetch(opts)

    @impl true
    def put(value, opts) do
      :ok = KeyProvider.File.put(value, opts)
      raise "simulated crash after the key switch"
    end
  end

  setup do
    case Store.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    clear_secrets_table()

    dir = Path.join(System.tmp_dir!(), "lemon-key-rotation-#{System.unique_integer([:positive])}")
    key_file = Path.join(dir, "secrets_master_key")
    File.mkdir_p!(dir)
    File.write!(key_file, Base.encode64(:crypto.strong_rand_bytes(32)))
    File.chmod!(key_file, 0o600)

    on_exit(fn ->
      clear_secrets_table()
      File.rm_rf!(dir)
    end)

    # Never the real Keychain or LEMON_SECRETS_MASTER_KEY: only the temp file.
    {:ok, key_file: key_file, opts: [key_providers: [:file], key_file: key_file]}
  end

  test "rotation re-encrypts every secret under a new key and retires the old one", ctx do
    old_key = read_key(ctx.key_file)

    values = %{
      {"default", "ALPHA"} => "alpha-value",
      {"default", "BETA"} => "beta-value",
      {"other", "GAMMA"} => "gamma-value"
    }

    for {{owner, name}, value} <- values do
      assert {:ok, _} = Secrets.set(name, value, [owner: owner] ++ ctx.opts)
    end

    assert {:ok, preview} = KeyRotation.preview(ctx.opts)
    assert %{source: :file, count: 3, expired: 0, resumed: 0} = preview
    assert preview.key_file == ctx.key_file
    assert preview.confirmation_token =~ ~r/\A[0-9a-f]{64}\z/
    assert read_key(ctx.key_file) == old_key

    assert {:ok, %{rotated: 3, pruned: 0, source: :file}} =
             KeyRotation.rotate(preview.confirmation_token, ctx.opts)

    new_key = read_key(ctx.key_file)
    assert byte_size(new_key) == 32
    refute new_key == old_key
    assert Bitwise.band(File.stat!(ctx.key_file).mode, 0o777) == 0o600

    for {{owner, name}, value} <- values do
      assert {:ok, ^value} = Secrets.get(name, [owner: owner] ++ ctx.opts)
    end

    for {_ref, entry} <- Store.list(Secrets.table()) do
      refute Map.has_key?(entry, :staged)
      assert {:ok, _} = Crypto.decrypt(entry, new_key)
      assert {:error, _} = Crypto.decrypt(entry, old_key)
    end
  end

  test "expired secrets are deleted rather than re-encrypted", ctx do
    assert {:ok, _} = Secrets.set("LIVE", "live-value", ctx.opts)

    assert {:ok, _} =
             Secrets.set("STALE", "stale-value", [expires_at: Clock.now_ms() - 1_000] ++ ctx.opts)

    assert {:ok, %{count: 1, expired: 1} = preview} = KeyRotation.preview(ctx.opts)

    assert {:ok, %{rotated: 1, pruned: 1}} =
             KeyRotation.rotate(preview.confirmation_token, ctx.opts)

    assert Store.get(Secrets.table(), {"default", "STALE"}) == nil
    assert {:ok, "live-value"} = Secrets.get("LIVE", ctx.opts)
  end

  test "a stale or missing confirmation is refused without changing anything", ctx do
    assert {:ok, _} = Secrets.set("ALPHA", "alpha-value", ctx.opts)
    assert {:ok, %{confirmation_token: token}} = KeyRotation.preview(ctx.opts)

    # The value changed after the preview: same names, new revision.
    assert {:ok, _} = Secrets.set("ALPHA", "alpha-value-2", ctx.opts)
    key_before = File.read!(ctx.key_file)
    alpha_before = Store.get(Secrets.table(), {"default", "ALPHA"})

    assert {:error, :confirmation_mismatch} = KeyRotation.rotate(token, ctx.opts)
    assert {:error, :confirmation_required} = KeyRotation.rotate("", ctx.opts)

    # A secret added after a fresh preview also invalidates it.
    assert {:ok, %{confirmation_token: fresh}} = KeyRotation.preview(ctx.opts)
    assert {:ok, _} = Secrets.set("BETA", "beta-value", ctx.opts)
    assert {:error, :confirmation_mismatch} = KeyRotation.rotate(fresh, ctx.opts)

    assert File.read!(ctx.key_file) == key_before
    assert Store.get(Secrets.table(), {"default", "ALPHA"}) == alpha_before

    refute Enum.any?(Store.list(Secrets.table()), fn {_ref, entry} ->
             Map.has_key?(entry, :staged)
           end)

    assert {:ok, "alpha-value-2"} = Secrets.get("ALPHA", ctx.opts)
  end

  test "a secret the current key cannot decrypt blocks rotation with no change", ctx do
    assert {:ok, _} = Secrets.set("GOOD", "good-value", ctx.opts)

    {:ok, foreign} = Crypto.encrypt("foreign-value", :crypto.strong_rand_bytes(32))
    record = Map.merge(foreign, %{provider: "manual", created_at: 1, updated_at: 1})
    :ok = Store.put(Secrets.table(), {"default", "FOREIGN"}, record)

    key_before = File.read!(ctx.key_file)
    rows_before = Enum.sort(Store.list(Secrets.table()))

    assert {:error, {:undecryptable_secrets, [%{owner: "default", name: "FOREIGN"}]} = reason} =
             KeyRotation.preview(ctx.opts)

    assert KeyRotation.rotate(String.duplicate("0", 64), ctx.opts) == {:error, reason}

    message = KeyRotation.describe_error(reason)
    assert message =~ "1 stored secret(s)"
    assert message =~ "default/FOREIGN"
    refute message =~ "foreign-value"
    refute message =~ "good-value"

    assert File.read!(ctx.key_file) == key_before
    assert Enum.sort(Store.list(Secrets.table())) == rows_before
  end

  test "a crash after re-encryption but before the key switch leaves the store readable",
       ctx do
    old_key = read_key(ctx.key_file)
    assert {:ok, _} = Secrets.set("ALPHA", "alpha-value", ctx.opts)
    assert {:ok, _} = Secrets.set("BETA", "beta-value", ctx.opts)

    crashing = Keyword.put(ctx.opts, :key_providers, [CrashBeforeSwitch])
    assert {:ok, %{confirmation_token: token}} = KeyRotation.preview(crashing)

    assert_raise RuntimeError, ~r/before the key switch/, fn ->
      KeyRotation.rotate(token, crashing)
    end

    # Every record was re-encrypted (staged) but the old key is still the one
    # loaded next, and it still opens everything.
    assert read_key(ctx.key_file) == old_key
    assert Enum.all?(Store.list(Secrets.table()), fn {_ref, entry} -> is_map(entry.staged) end)
    assert {:ok, "alpha-value"} = Secrets.get("ALPHA", ctx.opts)
    assert {:ok, "beta-value"} = Secrets.get("BETA", ctx.opts)

    # A later rotation starts from that state and completes.
    assert {:ok, %{count: 2, resumed: 0} = preview} = KeyRotation.preview(ctx.opts)
    assert {:ok, %{rotated: 2}} = KeyRotation.rotate(preview.confirmation_token, ctx.opts)
    refute read_key(ctx.key_file) == old_key
    assert {:ok, "alpha-value"} = Secrets.get("ALPHA", ctx.opts)
    assert {:ok, "beta-value"} = Secrets.get("BETA", ctx.opts)
  end

  test "a crash after the key switch but before promotion leaves the store readable", ctx do
    old_key = read_key(ctx.key_file)
    assert {:ok, _} = Secrets.set("ALPHA", "alpha-value", ctx.opts)
    assert {:ok, _} = Secrets.set("BETA", "beta-value", ctx.opts)

    crashing = Keyword.put(ctx.opts, :key_providers, [CrashAfterSwitch])
    assert {:ok, %{confirmation_token: token}} = KeyRotation.preview(crashing)

    assert_raise RuntimeError, ~r/after the key switch/, fn ->
      KeyRotation.rotate(token, crashing)
    end

    # The new key is loaded next; records still hold old-key ciphertext and
    # are read through their staged copy.
    new_key = read_key(ctx.key_file)
    refute new_key == old_key
    assert {:ok, "alpha-value"} = Secrets.get("ALPHA", ctx.opts)
    assert {:ok, "beta-value"} = Secrets.get("BETA", ctx.opts)

    assert {:ok, %{count: 2, resumed: 2} = preview} = KeyRotation.preview(ctx.opts)
    assert {:ok, %{rotated: 2}} = KeyRotation.rotate(preview.confirmation_token, ctx.opts)

    final_key = read_key(ctx.key_file)

    for {_ref, entry} <- Store.list(Secrets.table()) do
      refute Map.has_key?(entry, :staged)
      assert {:ok, _} = Crypto.decrypt(entry, final_key)
    end

    assert {:ok, "alpha-value"} = Secrets.get("ALPHA", ctx.opts)
    assert {:ok, "beta-value"} = Secrets.get("BETA", ctx.opts)
  end

  test "a key supplied by the environment is not rotated", ctx do
    assert {:ok, _} = Secrets.set("ALPHA", "alpha-value", ctx.opts)
    encoded = File.read!(ctx.key_file)

    env_opts = [
      key_providers: [:env],
      env_getter: fn
        "LEMON_SECRETS_MASTER_KEY" -> encoded
        _ -> nil
      end
    ]

    assert {:error, {:read_only_key_source, :env}} = KeyRotation.preview(env_opts)

    assert {:error, {:read_only_key_source, :env}} =
             KeyRotation.rotate(String.duplicate("0", 64), env_opts)

    assert File.read!(ctx.key_file) == encoded
    assert {:ok, "alpha-value"} = Secrets.get("ALPHA", env_opts)
  end

  defp read_key(path), do: path |> File.read!() |> String.trim() |> Base.decode64!()

  defp clear_secrets_table do
    Secrets.table()
    |> Store.list()
    |> Enum.each(fn {key, _value} -> Store.delete(Secrets.table(), key) end)
  end
end
