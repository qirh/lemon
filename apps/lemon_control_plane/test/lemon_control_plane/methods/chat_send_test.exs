defmodule LemonControlPlane.Methods.ChatSendTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.ChatSend
  alias LemonControlPlane.Protocol.Schemas
  alias LemonAi.Types.ImageContent

  @png_data "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="

  defmodule RouterStub do
    def submit(params) do
      send(self(), {:submitted, params})
      {:ok, "run_chat_cwd"}
    end
  end

  defmodule RejectingRouterStub do
    def submit(params), do: {:error, {:rejected, params}}
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
    assert request.images == []
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

  test "real image content is normalized and forwarded without extra fields", %{ctx: ctx} do
    image = Map.put(image(), "privateMetadata", "not forwarded")

    assert {:ok, result} = ChatSend.handle(params(%{"images" => [image]}), ctx)
    assert_received {:submitted, request}
    assert request.prompt == "hello"
    assert request.images == [%ImageContent{data: @png_data, mime_type: "image/png"}]
    assert result["summary"]["promptBytes"] == 5
    refute inspect(result) =~ @png_data
    refute inspect(result) =~ "privateMetadata"
  end

  test "image-only submission preserves the empty prompt", %{ctx: ctx} do
    assert {:ok, result} =
             ChatSend.handle(params(%{"prompt" => "", "images" => [image()]}), ctx)

    assert_received {:submitted, request}
    assert request.prompt == ""
    assert request.images == [%ImageContent{data: @png_data, mime_type: "image/png"}]
    assert result["summary"]["promptBytes"] == 0
  end

  test "empty prompt without images retains ordinary submission behavior", %{ctx: ctx} do
    assert {:ok, _} = ChatSend.handle(params(%{"prompt" => ""}), ctx)
    assert_received {:submitted, %{prompt: "", images: []}}
  end

  test "invalid images fail before router submission with bounded errors", %{ctx: ctx} do
    for images <- [
          nil,
          %{},
          "PRIVATE_IMAGE_PAYLOAD",
          [Map.put(image(), "data", "PRIVATE_IMAGE_PAYLOAD")],
          [Map.put(image(), "mime_type", "text/plain")],
          List.duplicate(image(), 6)
        ] do
      assert {:error, {:invalid_request, message, nil}} =
               ChatSend.handle(params(%{"images" => images}), ctx)

      assert byte_size(message) < 256
      refute message =~ "PRIVATE_IMAGE_PAYLOAD"
      refute message =~ @png_data
      refute_received {:submitted, _}
    end
  end

  test "router rejection cannot echo forwarded image data" do
    result =
      ChatSend.handle(params(%{"images" => [image()]}), %{router_mod: RejectingRouterStub})

    assert result == {:error, {:internal_error, "Chat submission failed", nil}}
    refute inspect(result) =~ @png_data
  end

  test "JSON image arrays pass the chat request validation boundary" do
    assert :ok = Schemas.validate("chat.send", params(%{"images" => [image()]}))
    assert :ok = Schemas.validate("chat.send", params(%{"images" => []}))
    assert :ok = Schemas.validate("chat.send", params(%{"prompt" => "", "images" => [image()]}))
    assert {:error, _} = Schemas.validate("chat.send", params(%{"images" => %{}}))
  end

  test "schema advertises optional string cwd" do
    assert Schemas.get("chat.send").optional["cwd"] == :string
    assert :ok = Schemas.validate("chat.send", params())
    assert :ok = Schemas.validate("chat.send", params(%{"cwd" => "/workspace"}))
    assert {:error, _} = Schemas.validate("chat.send", params(%{"cwd" => 123}))
  end

  defp image do
    %{"type" => "image", "mime_type" => "image/png", "data" => @png_data}
  end

  defp params(extra \\ %{}) do
    Map.merge(%{"sessionKey" => "agent:chat-workspace:main", "prompt" => "hello"}, extra)
  end
end
