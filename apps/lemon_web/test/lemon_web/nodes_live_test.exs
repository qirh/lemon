defmodule LemonWeb.NodesLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import LemonWeb.Test.OperatorAuth

  alias LemonControlPlane.Auth.TokenStore
  alias LemonControlPlane.Methods.Registry
  alias LemonControlPlane.NodeStore

  @endpoint LemonWeb.Endpoint

  setup :configure_operator_token

  defp put_node(name) do
    id = "web-node-#{System.unique_integer([:positive])}"
    now = System.system_time(:millisecond)

    :ok =
      NodeStore.put_node(id, %{
        id: id,
        name: name,
        type: "coding_agent",
        capabilities: %{"coding_agent.run" => %{"version" => 1}},
        token_hash: "durable-token-hash-#{id}",
        paired_at_ms: now - 60_000,
        last_seen_ms: now - 30_000,
        status: :offline
      })

    on_exit(fn -> LemonCore.Store.delete(:nodes_registry, id) end)
    id
  end

  defp put_pairing(name) do
    id = "web-pair-#{System.unique_integer([:positive])}"
    now = System.system_time(:millisecond)

    :ok =
      NodeStore.put_pairing(id, %{
        id: id,
        code: "482913",
        node_type: "coding_agent",
        node_name: name,
        capabilities: %{"coding_agent.run" => %{}},
        status: :pending,
        created_at_ms: now,
        expires_at_ms: now + 120_000
      })

    on_exit(fn ->
      LemonCore.Store.delete(:nodes_pairing, id)

      case NodeStore.get_pairing(id) do
        %{node_id: node_id} when is_binary(node_id) ->
          LemonCore.Store.delete(:nodes_registry, node_id)
          NodeStore.release_node_name(name, node_id)

        _ ->
          :ok
      end
    end)

    id
  end

  test "lists paired nodes with status and capabilities, never credentials", %{conn: conn} do
    id = put_node("Render Farm")
    {:ok, view, html} = live(conn, "/nodes")

    assert has_element?(view, "#node-#{id}")
    assert html =~ "Render Farm"
    assert html =~ "Offline"
    assert html =~ "coding_agent.run"
    assert html =~ "lemon node join"
    refute html =~ "durable-token-hash"
  end

  test "approving a pending pairing never renders the issued credentials", %{conn: conn} do
    name = "Laptop #{System.unique_integer([:positive])}"
    pairing = put_pairing(name)
    {:ok, view, html} = live(conn, "/nodes")

    assert html =~ name
    assert html =~ "482913"

    html = view |> element("#pairing-#{pairing} button[phx-click=approve]") |> render_click()
    assert html =~ "Pairing approved"
    refute has_element?(view, "#pairing-#{pairing}")

    approved = NodeStore.get_pairing(pairing)
    assert approved.status == :approved
    refute html =~ approved.challenge_token
  end

  test "revoke is preview then exact-name confirmation", %{conn: conn} do
    id = put_node("Build Box")
    token = "web-node-session-#{System.unique_integer([:positive])}"
    {:ok, _} = TokenStore.replace_node_session(token, %{"type" => "node", "nodeId" => id})

    {:ok, view, html} = live(conn, "/nodes")
    assert html =~ "Session active"

    view |> element("#node-#{id} button[phx-click=revoke_preview]") |> render_click()
    assert has_element?(view, "#revoke-node")

    html = view |> form("#revoke-node-form", %{"confirmation" => "build box"}) |> render_submit()
    assert html =~ "Type the exact node name"
    assert {:ok, _} = TokenStore.validate(token)

    html = view |> form("#revoke-node-form", %{"confirmation" => "Build Box"}) |> render_submit()
    assert html =~ "Revoked Build Box"
    assert {:error, :invalid_token} = TokenStore.validate(token)
    assert render(view) =~ "Revoked"
    refute has_element?(view, "#revoke-node")
  end

  test "empty registry explains pairing", %{conn: conn} do
    {:ok, module} = Registry.lookup("nodes.list")
    on_exit(fn -> Registry.register(module) end)

    defmodule EmptyNodes do
      @behaviour LemonControlPlane.Method
      def name, do: "nodes.list"
      def scopes, do: [:read]

      def handle(_, _),
        do: {:ok, %{"nodes" => [], "pairings" => [], "summary" => %{"presenceAvailable" => true}}}
    end

    :ok = Registry.register(EmptyNodes)
    {:ok, _view, html} = live(conn, "/nodes")

    assert html =~ "No execution nodes paired"
    assert html =~ "Pair a node"
  end

  test "a failed query is an unavailable state", %{conn: conn} do
    {:ok, module} = Registry.lookup("nodes.list")
    :ok = Registry.unregister("nodes.list")
    on_exit(fn -> Registry.register(module) end)

    {:ok, _view, html} = live(conn, "/nodes")
    assert html =~ "Nodes are unavailable"
    refute html =~ "No execution nodes paired"
  end
end
