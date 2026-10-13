defmodule LemonControlPlane.ImageInputsTest do
  use ExUnit.Case, async: true

  alias LemonAi.Types.ImageContent
  alias LemonControlPlane.ImageInputs

  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="
  @png_header <<137, "PNG", 13, 10, 26, 10>>
  @max_bytes 10_485_760

  test "accepts empty arrays and retains encoded bytes in whitelisted typed images" do
    assert {:ok, []} = ImageInputs.validate([])

    input = Map.merge(image(@png), %{"url" => "ignored", "extra" => %{}})

    assert {:ok, [%ImageContent{type: :image, mime_type: "image/png", data: @png} = normalized]} =
             ImageInputs.validate([input])

    assert Enum.sort(Map.keys(Map.from_struct(normalized))) == [:data, :mime_type, :type]
    assert {:ok, images} = ImageInputs.validate(List.duplicate(input, 5))
    assert length(images) == 5
  end

  test "checks array shape and count before inspecting or decoding entries" do
    for input <- [nil, %{}, "images", [image(@png) | :invalid]] do
      assert {:error, {:invalid_request, "images must be an array", nil}} =
               ImageInputs.validate(input)
    end

    assert {:error, {:invalid_request, "images must contain at most 5 entries", nil}} =
             ImageInputs.validate(List.duplicate(nil, 6))
  end

  test "rejects malformed fields with bounded static errors" do
    for input <- [
          nil,
          [],
          %{},
          %ImageContent{data: @png},
          Map.put(image(@png), "type", "text"),
          Map.put(image(@png), "mime_type", "image/svg+xml"),
          Map.put(image(@png), "mime_type", "image/jpg"),
          Map.put(image(@png), "data", nil),
          Map.put(image(@png), "data", %{"secret" => "private"})
        ] do
      assert {:error, {:invalid_request, message, nil}} = ImageInputs.validate([input])
      assert message == "each image must have type image, a supported mime_type and binary data"
    end
  end

  test "requires strict standard Base64 with canonical padding" do
    for data <- [
          "",
          "!!!!",
          "_9j_",
          "iVBORw0KGgo",
          "iVBORw0KGgo=\n",
          "iVBORw0KGgp=",
          "/9j/AB==",
          "====",
          "iVBO Rw0KGgo"
        ] do
      assert {:error, {:invalid_request, message, nil}} = ImageInputs.validate([image(data)])

      assert message in [
               "image data must be strict standard Base64",
               "image data must be strict standard Base64 with a matching image header"
             ]
    end
  end

  test "accepts supported MIME headers and rejects fake or mismatched content" do
    fixtures = [
      {"image/png", @png_header},
      {"image/jpeg", <<255, 216, 255, 224>>},
      {"image/gif", "GIF87a"},
      {"image/gif", "GIF89a"},
      {"image/webp", <<"RIFF", 12, 0, 0, 0, "WEBP">>}
    ]

    for {mime, header} <- fixtures do
      encoded = Base.encode64(header)

      assert {:ok, [%ImageContent{mime_type: ^mime, data: ^encoded}]} =
               ImageInputs.validate([image(encoded, mime)])
    end

    for input <- [
          image(Base.encode64("not an image")),
          image(@png, "image/jpeg"),
          image(Base.encode64("GIF89a"), "image/webp"),
          image(Base.encode64("RIFF0000NOTP"), "image/webp"),
          image(Base.encode64(<<255, 216>>), "image/jpeg")
        ] do
      assert {:error, {:invalid_request, message, nil}} = ImageInputs.validate([input])
      assert message == "image data must be strict standard Base64 with a matching image header"
    end
  end

  test "checks encoded size before decoding and applies the aggregate decoded limit" do
    assert {:error, {:invalid_request, "images exceed the 10 MiB decoded size limit", nil}} =
             ImageInputs.validate([image(String.duplicate("!", div(@max_bytes + 2, 3) * 4 + 4))])

    boundary = image(png_data(@max_bytes))
    assert {:ok, [%ImageContent{}]} = ImageInputs.validate([boundary])

    assert {:error, {:invalid_request, "images exceed the 10 MiB decoded size limit", nil}} =
             ImageInputs.validate([image(png_data(@max_bytes + 1))])

    half = image(png_data(div(@max_bytes, 2)))
    assert {:ok, [%ImageContent{}, %ImageContent{}]} = ImageInputs.validate([half, half])

    assert {:error, {:invalid_request, "images exceed the 10 MiB decoded size limit", nil}} =
             ImageInputs.validate([half, half, image(@png)])

    # Aggregate preflight wins before attempting to decode even the first entry.
    malformed = image(String.duplicate("!", byte_size(half["data"])))

    assert {:error, {:invalid_request, "images exceed the 10 MiB decoded size limit", nil}} =
             ImageInputs.validate([malformed, half, image(@png)])
  end

  defp image(data, mime_type \\ "image/png"),
    do: %{"type" => "image", "mime_type" => mime_type, "data" => data}

  defp png_data(size) do
    Base.encode64(@png_header <> :binary.copy(<<0>>, size - byte_size(@png_header)))
  end
end
