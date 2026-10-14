defmodule LemonWeb.ProviderManagementLiveTest do
  use ExUnit.Case, async: false

  @endpoint LemonWeb.Endpoint

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import LemonWeb.Test.OperatorAuth
  import ExUnit.CaptureLog

  setup :configure_operator_token

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "provider_management_live_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    project = Path.join(root, "project")
    config_path = Path.join(root, "config.toml")
    File.mkdir_p!(Path.join(project, ".lemon"))
    File.write!(config_path, initial_config())

    web_keys = [
      :provider_configuration_fun,
      :provider_configuration_project_dir,
      :provider_snapshot_fun,
      :provider_status_fun
    ]

    previous_web = Map.new(web_keys, &{&1, Application.fetch_env(:lemon_web, &1)})
    previous_paths = Application.get_env(:lemon_core, :paths)
    previous_catalog = Application.fetch_env(:lemon_control_plane, :model_catalog)

    Application.put_env(:lemon_web, :provider_configuration_project_dir, project)
    Application.delete_env(:lemon_web, :provider_configuration_fun)
    Application.delete_env(:lemon_web, :provider_snapshot_fun)
    Application.put_env(:lemon_web, :provider_status_fun, fn -> provider_status() end)
    Application.put_env(:lemon_core, :paths, global_config: config_path)
    Application.put_env(:lemon_control_plane, :model_catalog, fn _opts -> catalog() end)

    on_exit(fn ->
      Enum.each(previous_web, fn
        {key, :error} -> Application.delete_env(:lemon_web, key)
        {key, {:ok, value}} -> Application.put_env(:lemon_web, key, value)
      end)

      case previous_catalog do
        {:ok, value} -> Application.put_env(:lemon_control_plane, :model_catalog, value)
        :error -> Application.delete_env(:lemon_control_plane, :model_catalog)
      end

      if is_nil(previous_paths),
        do: Application.delete_env(:lemon_core, :paths),
        else: Application.put_env(:lemon_core, :paths, previous_paths)

      File.rm_rf!(root)
    end)

    %{config_path: config_path, project: project, root: root}
  end

  test "route requires operator auth and never renders the token or config paths", ctx do
    conn = get(build_conn(), "/models")
    assert redirected_to(conn, 302) =~ "/login"

    html = ctx.conn |> get("/models") |> html_response(200)
    assert html =~ "Models"
    assert Regex.match?(~r/<meta name="csrf-token" content="[^"]+"\s*\/?>/, html)
    refute html =~ ctx.token
    refute html =~ ctx.root
  end

  test "catalog lists models with capabilities and pricing, searchable and filterable", ctx do
    {:ok, view, _html} = live(ctx.conn, "/models")
    html = render_async(view)

    assert html =~ "Fast Model"
    assert html =~ "fast-model"
    assert html =~ "Thinking"
    assert html =~ "Vision"
    assert html =~ "$2.50 · $10.00"
    assert html =~ "128k"
    assert html =~ "3 models"
    assert html =~ "openai:gpt-5-mini"

    html = view |> form("#catalog-filter", catalog: %{q: "deep"}) |> render_change()
    assert html =~ "Deep Thinker"
    refute html =~ "Fast Model"

    html =
      view
      |> form("#catalog-filter", catalog: %{q: "", provider: "", capability: "vision"})
      |> render_change()

    assert html =~ "Fast Model"
    refute html =~ "Deep Thinker"
  end

  test "set as default previews, writes nothing, then applies the exact revision", ctx do
    original = File.read!(ctx.config_path)
    {:ok, view, _html} = live(ctx.conn, "/models")
    render_async(view)

    html =
      render_click(view, "preview-default-model", %{
        "provider" => "anthropic",
        "model" => "deep-thinker"
      })

    assert html =~ "Set default model to anthropic:deep-thinker"
    assert html =~ "New sessions default to anthropic:deep-thinker"
    assert html =~ "currently openai:gpt-5-mini"
    assert File.read!(ctx.config_path) == original

    html = render_submit(view, "apply-preview", %{"apply" => %{}})
    assert html =~ "Default model change applied"
    assert File.read!(ctx.config_path) =~ ~s(model = "anthropic:deep-thinker")
    assert File.read!(ctx.config_path) =~ "# retained operator note"
    assert has_element?(view, "#catalog-table tr", "Deep Thinker")
    assert render(view) =~ "anthropic:deep-thinker"
  end

  test "set as default refuses models outside the current catalog", ctx do
    {:ok, view, _html} = live(ctx.conn, "/models")
    render_async(view)

    html =
      render_click(view, "preview-default-model", %{
        "provider" => "openai",
        "model" => "not-listed"
      })

    assert html =~ "That model is not in the current catalog."
    refute html =~ ~s(id="provider-change-preview")
  end

  test "providers tab shows credential readiness as booleans only", ctx do
    {:ok, view, _html} = live(ctx.conn, "/models?tab=providers")
    html = render_async(view)

    assert html =~ "1 of 2"
    assert has_element?(view, "#provider-openai", "Ready")
    assert has_element?(view, "#provider-anthropic", "Not set up")
    assert html =~ "API key"
    refute html =~ "OPENAI_API_KEY"
    refute html =~ "secret-name-should-not-render"
  end

  test "catalog and provider failures show unavailable states, not empty ones", ctx do
    Application.put_env(:lemon_control_plane, :model_catalog, fn _opts -> raise "boom sk-leak" end)

    Application.put_env(:lemon_web, :provider_status_fun, fn -> raise "boom" end)

    {:ok, view, _html} = live(ctx.conn, "/models")
    html = render_async(view)
    assert html =~ "Model catalog unavailable"
    refute html =~ "No models available"
    refute html =~ "sk-leak"

    {:ok, view, _html} = live(ctx.conn, "/models?tab=providers")
    assert render_async(view) =~ "Provider status unavailable"
  end

  test "an empty catalog explains how to add a provider", ctx do
    Application.put_env(:lemon_control_plane, :model_catalog, fn _opts -> [] end)
    {:ok, view, _html} = live(ctx.conn, "/models")
    assert render_async(view) =~ "No models available"
  end

  test "fallback preview writes nothing and apply uses the exact revision", ctx do
    original = File.read!(ctx.config_path)
    {:ok, view, html} = live(ctx.conn, "/models?tab=routing")

    assert html =~ "1 ordered"
    assert html =~ "zai"

    rendered =
      render_submit(view, "preview-fallback-add", %{"fallback" => %{"provider" => "anthropic"}})

    assert rendered =~ "Preview ready"
    assert rendered =~ "Append fallback anthropic"
    assert rendered =~ "2 fallback(s)"
    assert File.read!(ctx.config_path) == original

    rendered = render_submit(view, "apply-preview", %{"apply" => %{}})
    assert rendered =~ "change applied"
    assert rendered =~ "2 ordered"
    assert File.read!(ctx.config_path) =~ ~s(fallback_providers = ["zai","anthropic"])
  end

  test "destructive fallback removal refuses a mismatch and accepts exact confirmation", ctx do
    {:ok, view, _html} = live(ctx.conn, "/models?tab=routing")

    rendered = render_click(view, "preview-fallback-remove", %{"provider" => "zai"})
    assert rendered =~ "Destructive change"
    assert rendered =~ ~s(<code class="font-mono text-fg">zai</code>)

    rendered = render_submit(view, "apply-preview", %{"apply" => %{"confirmation" => "wrong"}})
    assert rendered =~ "Exact confirmation did not match"
    assert rendered =~ "Remove fallback zai"
    assert File.read!(ctx.config_path) =~ "zai"

    rendered = render_submit(view, "apply-preview", %{"apply" => %{"confirmation" => "zai"}})
    assert rendered =~ "change applied"
    assert File.read!(ctx.config_path) =~ "fallback_providers = []"
  end

  test "pool create, update, activate, and delete flow stays preview-first", ctx do
    {:ok, view, _html} = live(ctx.conn, "/models?tab=routing")

    rendered =
      render_submit(view, "preview-pool-upsert", %{
        "pool" => %{
          "pool" => "burst",
          "providers" => "openai, anthropic",
          "strategy" => "round_robin",
          "activate" => "true"
        }
      })

    assert rendered =~ "Create or update pool burst"
    refute rendered =~ "Destructive change"
    rendered = render_submit(view, "apply-preview", %{"apply" => %{}})
    assert rendered =~ "burst"
    assert has_element?(view, "#pool-burst", "Active")

    rendered =
      render_submit(view, "preview-pool-upsert", %{
        "pool" => %{
          "pool" => "burst",
          "providers" => "anthropic, openai",
          "strategy" => "priority"
        }
      })

    assert rendered =~ "Destructive change"
    assert rendered =~ ~s(<code class="font-mono text-fg">burst</code>)

    rendered = render_submit(view, "apply-preview", %{"apply" => %{"confirmation" => "burst"}})
    assert rendered =~ "change applied"
    assert File.read!(ctx.config_path) =~ ~s(providers = ["anthropic","openai"])

    rendered = render_click(view, "preview-pool-activate", %{"pool" => "primary"})
    assert rendered =~ "Create or update pool primary"

    rendered = render_submit(view, "apply-preview", %{"apply" => %{"confirmation" => "primary"}})
    assert rendered =~ "change applied"

    rendered = render_click(view, "preview-pool-delete", %{"pool" => "burst"})
    assert rendered =~ "Delete pool burst"

    rendered = render_submit(view, "apply-preview", %{"apply" => %{"confirmation" => "burst"}})
    assert rendered =~ "change applied"
    refute rendered =~ ~s(id="pool-burst")
  end

  test "credential references are never retained or rendered", ctx do
    secret_ref = "secret:web_secondary_#{System.unique_integer([:positive])}"
    {:ok, view, html} = live(ctx.conn, "/models?tab=routing")
    refute html =~ secret_ref

    {rendered, log} =
      with_log(fn ->
        render_submit(view, "preview-credential", %{
          "credential" => %{
            "pool" => "primary",
            "provider" => "openai",
            "operation" => "add",
            "credential_ref" => secret_ref
          }
        })
      end)

    assert rendered =~ "never retained or rendered"
    assert log =~ "[FILTERED]"
    refute log =~ secret_ref
    refute rendered =~ secret_ref
    refute rendered =~ String.replace_prefix(secret_ref, "secret:", "")
    refute :sys.get_state(view.pid) |> inspect() =~ secret_ref
    refute File.read!(ctx.config_path) =~ secret_ref

    rendered =
      render_submit(view, "apply-preview", %{"apply" => %{"credential_ref" => "secret:different"}})

    assert rendered =~ "Re-enter the same credential reference"
    refute rendered =~ secret_ref

    rendered =
      render_submit(view, "apply-preview", %{"apply" => %{"credential_ref" => secret_ref}})

    assert rendered =~ "1 opaque reference"
    refute rendered =~ secret_ref
    assert File.read!(ctx.config_path) =~ secret_ref

    rendered =
      render_submit(view, "preview-credential", %{
        "credential" => %{
          "pool" => "primary",
          "provider" => "openai",
          "operation" => "remove",
          "credential_ref" => secret_ref
        }
      })

    assert rendered =~ ~s(<code class="font-mono text-fg">primary</code>)
    refute rendered =~ secret_ref

    rendered =
      render_submit(view, "apply-preview", %{
        "apply" => %{"confirmation" => "primary", "credential_ref" => secret_ref}
      })

    refute rendered =~ secret_ref
    refute File.read!(ctx.config_path) =~ secret_ref
  end

  test "stale apply fails closed while preserving the non-secret draft", ctx do
    {:ok, view, _html} = live(ctx.conn, "/models?tab=routing")

    render_submit(view, "preview-fallback-add", %{"fallback" => %{"provider" => "anthropic"}})
    File.write!(ctx.config_path, File.read!(ctx.config_path) <> "\n# external edit\n")

    rendered = render_submit(view, "apply-preview", %{"apply" => %{}})
    assert rendered =~ "changed after preview"
    assert rendered =~ "drafts were kept"
    assert rendered =~ ~s(value="anthropic")
    refute rendered =~ ~s(id="provider-change-preview")
    refute File.read!(ctx.config_path) =~ ~s("anthropic")
  end

  test "runtime failures are bounded and redact callback details", ctx do
    secret = "sk-runtime-secret"

    Application.put_env(:lemon_web, :provider_snapshot_fun, fn ->
      {:error, {:failed, secret, ctx.root}}
    end)

    Application.put_env(:lemon_web, :provider_configuration_fun, fn _params ->
      {:error, :configuration_failed,
       "#{secret} https://private.example #{ctx.root} OPENAI_API_KEY"}
    end)

    {:ok, view, html} = live(ctx.conn, "/models?tab=routing")
    assert html =~ "Provider routing status is temporarily unavailable"
    refute html =~ secret
    refute html =~ ctx.root

    rendered =
      render_submit(view, "preview-fallback-add", %{"fallback" => %{"provider" => "anthropic"}})

    assert rendered =~ "Provider configuration is temporarily unavailable"
    refute rendered =~ secret
    refute rendered =~ ctx.root
    refute rendered =~ "OPENAI_API_KEY"
    refute rendered =~ "private.example"
  end

  defp catalog do
    [
      %LemonAi.Types.Model{
        provider: :openai,
        id: "gpt-5-mini",
        name: "GPT-5 mini",
        context_window: 400_000,
        max_tokens: 128_000,
        input: [:text]
      },
      %LemonAi.Types.Model{
        provider: :openai,
        id: "fast-model",
        name: "Fast Model",
        context_window: 128_000,
        max_tokens: 16_000,
        input: [:text, :image],
        cost: %LemonAi.Types.ModelCost{input: 2.5, output: 10.0}
      },
      %LemonAi.Types.Model{
        provider: :anthropic,
        id: "deep-thinker",
        name: "Deep Thinker",
        context_window: 200_000,
        max_tokens: 64_000,
        reasoning: true,
        input: [:text]
      }
    ]
  end

  defp provider_status do
    %{
      "providers" => [
        %{
          "provider" => "openai",
          "configured" => true,
          "credentialReady" => true,
          "config" => %{
            "apiKeySecretConfigured" => true,
            "secretName" => "secret-name-should-not-render",
            "envVar" => "OPENAI_API_KEY"
          },
          "ambient" => %{"envConfigured" => false}
        },
        %{"provider" => "anthropic", "configured" => false, "credentialReady" => false}
      ]
    }
  end

  defp initial_config do
    """
    # retained operator note
    [defaults]
    provider = "openai"
    model = "gpt-5-mini"

    [runtime.provider_routing]
    fallback_providers = ["zai"]
    default_pool = "primary"

    [runtime.provider_routing.credential_pools.primary]
    providers = ["openai"]
    strategy = "priority"
    """
  end
end
