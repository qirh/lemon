defmodule LemonControlPlane.ImageInputs do
  @moduledoc """
  Validates RPC image arrays before submission to the router.

  Accepts at most five PNG, JPEG, GIF or WebP images totaling at most 10 MiB
  decoded. Each entry must have string keys `type`, `mime_type` and `data`,
  with type `image` and strictly padded standard Base64 data matching the MIME
  header. Successful values are `LemonAi.Types.ImageContent` structs retaining
  the original encoded data; additional input fields are discarded.
  """

  alias LemonAi.Types.ImageContent

  @max_images 5
  @max_decoded_bytes 10_485_760
  @max_encoded_bytes div(@max_decoded_bytes + 2, 3) * 4
  @mime_types ["image/png", "image/jpeg", "image/gif", "image/webp"]

  @type validation_error :: {:invalid_request, String.t(), nil}

  @spec validate(term()) :: {:ok, [ImageContent.t()]} | {:error, validation_error()}
  def validate(images) do
    with :ok <- validate_count(images, 0),
         :ok <- validate_sizes(images, 0) do
      normalize(images, [])
    end
  end

  defp validate_count([], _count), do: :ok

  defp validate_count([_image | _rest], @max_images),
    do: invalid("images must contain at most 5 entries")

  defp validate_count([_image | rest], count), do: validate_count(rest, count + 1)
  defp validate_count(_images, _count), do: invalid("images must be an array")

  defp validate_sizes([], _total), do: :ok

  defp validate_sizes([image | rest], total) do
    with {:ok, decoded_size} <- image_size(image) do
      total = total + decoded_size

      if total <= @max_decoded_bytes do
        validate_sizes(rest, total)
      else
        invalid("images exceed the 10 MiB decoded size limit")
      end
    end
  end

  defp image_size(%{"type" => "image", "mime_type" => mime_type, "data" => data})
       when mime_type in @mime_types and is_binary(data) do
    size = byte_size(data)

    cond do
      size > @max_encoded_bytes ->
        invalid("images exceed the 10 MiB decoded size limit")

      size == 0 or rem(size, 4) != 0 ->
        invalid("image data must be strict standard Base64")

      true ->
        padding = padding_bytes(data, size)
        {:ok, div(size, 4) * 3 - padding}
    end
  end

  defp image_size(_image),
    do: invalid("each image must have type image, a supported mime_type and binary data")

  defp padding_bytes(data, size) do
    cond do
      :binary.at(data, size - 1) != ?= -> 0
      :binary.at(data, size - 2) == ?= -> 2
      true -> 1
    end
  end

  defp normalize([], images), do: {:ok, Enum.reverse(images)}

  defp normalize([%{"mime_type" => mime_type, "data" => data} | rest], images) do
    with true <- canonical_padding?(data),
         {:ok, decoded} <- Base.decode64(data, padding: true),
         true <- image_header_matches?(decoded, mime_type) do
      image = %ImageContent{type: :image, data: data, mime_type: mime_type}
      normalize(rest, [image | images])
    else
      :error -> invalid("image data must be strict standard Base64")
      false -> invalid("image data must be strict standard Base64 with a matching image header")
    end
  end

  # Checking the unused bits avoids re-encoding the whole decoded image merely
  # to reject noncanonical padding. Base.decode64 rejects other alphabet errors.
  defp canonical_padding?(data) do
    size = byte_size(data)

    case padding_bytes(data, size) do
      0 -> true
      1 -> rem(base64_value(:binary.at(data, size - 2)), 4) == 0
      2 -> rem(base64_value(:binary.at(data, size - 3)), 16) == 0
    end
  end

  defp base64_value(char) when char in ?A..?Z, do: char - ?A
  defp base64_value(char) when char in ?a..?z, do: char - ?a + 26
  defp base64_value(char) when char in ?0..?9, do: char - ?0 + 52
  defp base64_value(?+), do: 62
  defp base64_value(?/), do: 63
  defp base64_value(_char), do: -1

  defp image_header_matches?(<<137, "PNG", 13, 10, 26, 10, _rest::binary>>, "image/png"),
    do: true

  defp image_header_matches?(<<255, 216, 255, _rest::binary>>, "image/jpeg"), do: true
  defp image_header_matches?(<<"GIF87a", _rest::binary>>, "image/gif"), do: true
  defp image_header_matches?(<<"GIF89a", _rest::binary>>, "image/gif"), do: true

  defp image_header_matches?(
         <<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>,
         "image/webp"
       ),
       do: true

  defp image_header_matches?(_decoded, _mime_type), do: false

  defp invalid(message), do: {:error, {:invalid_request, message, nil}}
end
