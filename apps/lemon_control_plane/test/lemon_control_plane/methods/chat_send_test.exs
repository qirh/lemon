defmodule LemonControlPlane.Methods.ChatSendTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.ChatSend
  alias LemonControlPlane.Protocol.Schemas

  defmodule RouterStub do
    def submit(params) do
      send(self(), {:submitted, params})
      {:ok, "run_chat_cwd"}
    end
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "chat-send-cwd-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    config = Path.join(root, "config.toml")
    File.write!(config, "[profiles.workspace]\nname = \"Workspace\"\n")
    previous_paths = Application.get_env(:lemon_core, :paths)

    Application.put_env(
      :lemon_core,
      :paths,
      Keyword.put(previous_paths || [], :global_config, config)
    )

    on_exit(fn ->
      if is_nil(previous_paths) do
        Application.delete_env(:lemon_core, :paths)
      else
        Application.put_env(:lemon_core, :paths, previous_paths)
      end

      File.rm_rf!(root)
    end)

    %{root: root, ctx: %{router_mod: RouterStub}}
  end

  test "valid absolute cwd reaches the router request unchanged", %{root: root, ctx: ctx} do
    assert {:ok, %{"runId" => "run_chat_cwd"}} =
             ChatSend.handle(params(%{"cwd" => root}), ctx)

    assert_received {:submitted, request}
    assert request.cwd == root
    assert request.session_key == "agent:chat-workspace:main"
    assert request.prompt == "hello"
  end

  test "omission does not add a cwd override", %{ctx: ctx} do
    assert {:ok, _} = ChatSend.handle(params(), ctx)
    assert_received {:submitted, request}
    refute Map.has_key?(request, :cwd)
  end

  test "invalid cwd is rejected before submission", %{root: root, ctx: ctx} do
    file = Path.join(root, "file.txt")
    File.write!(file, "not a directory")

    for cwd <- ["relative", "", nil, 123, %{}, [], Path.join(root, "missing"), file] do
      assert {:error, {:invalid_request, _, nil}} =
               ChatSend.handle(params(%{"cwd" => cwd}), ctx)

      refute_received {:submitted, _}
    end
  end

  test "canonical profile session rejects caller cwd", %{root: root, ctx: ctx} do
    assert {:ok, profile} = LemonCore.ProfileStore.get("workspace")

    assert {:error, {:invalid_request, "cwd cannot override a canonical profile session", nil}} =
             ChatSend.handle(
               params(%{"sessionKey" => profile["canonicalSessionKey"], "cwd" => root}),
               ctx
             )

    refute_received {:submitted, _}
  end

  test "canonical profile session without cwd retains existing submission", %{ctx: ctx} do
    assert {:ok, profile} = LemonCore.ProfileStore.get("workspace")

    assert {:ok, _} =
             ChatSend.handle(params(%{"sessionKey" => profile["canonicalSessionKey"]}), ctx)

    assert_received {:submitted, request}
    refute Map.has_key?(request, :cwd)
  end

  test "noncanonical session for a profile can use caller cwd", %{root: root, ctx: ctx} do
    assert {:ok, _} =
             ChatSend.handle(
               params(%{"sessionKey" => "agent:workspace:thread:workspace-test", "cwd" => root}),
               ctx
             )

    assert_received {:submitted, %{cwd: ^root}}
  end

  test "schema advertises optional string cwd" do
    assert Schemas.get("chat.send").optional["cwd"] == :string
    assert :ok = Schemas.validate("chat.send", params())
    assert :ok = Schemas.validate("chat.send", params(%{"cwd" => "/workspace"}))
    assert {:error, _} = Schemas.validate("chat.send", params(%{"cwd" => 123}))
  end

  defp params(extra \\ %{}) do
    Map.merge(%{"sessionKey" => "agent:chat-workspace:main", "prompt" => "hello"}, extra)
  end
end
