defmodule LemonAi.Providers.SSEParser do
  @moduledoc """
  Shared SSE (Server-Sent Events) stream parser for OpenAI-compatible providers.
  """

  @doc """
  Parses an SSE chunk buffer into decoded JSON events and any remaining incomplete data.

  Returns `{events, incomplete}` where `events` is a list of decoded JSON maps
  and `incomplete` is the trailing partial data that should be prepended to the next chunk.
  """
  def parse_sse_chunk(buffer) do
    parts = String.split(buffer, ~r/\r?\n\r?\n/)

    {complete_parts, [incomplete]} =
      if length(parts) > 1 do
        Enum.split(parts, -1)
      else
        {[], parts}
      end

    events =
      complete_parts
      |> Enum.flat_map(fn part ->
        part
        |> String.split(~r/\r?\n/)
        |> Enum.filter(&String.starts_with?(&1, "data:"))
        |> Enum.map(fn line ->
          line |> String.replace_prefix("data:", "") |> String.replace_prefix(" ", "")
        end)
        |> Enum.join("\n")
        |> then(fn data ->
          case Jason.decode(data) do
            {:ok, event} when is_map(event) -> [event]
            _ -> []
          end
        end)
      end)

    {events, incomplete}
  end

  @doc """
  Consume only the asynchronous HTTP response's messages. Closing without a
  provider terminal event is checked by the protocol parser, not treated as a
  successful generation here. The trailing SSE frame is flushed on EOF.
  """
  def events(%Req.Response{body: %Req.Response.Async{ref: ref}} = response, timeout \\ 300_000) do
    Stream.resource(
      fn -> %{buffer: "", done: false} end,
      fn
        %{done: true} = state ->
          {:halt, state}

        state ->
          receive do
            {^ref, _} = message ->
              case Req.parse_message(response, message) do
                {:ok, parts} ->
                  Enum.reduce(parts, {[], state}, fn
                    {:data, chunk}, {events, state} ->
                      {parsed, buffer} = parse_sse_chunk(state.buffer <> chunk)
                      {events ++ parsed, %{state | buffer: buffer}}

                    :done, {events, state} ->
                      {parsed, _} = parse_sse_chunk(state.buffer <> "\n\n")
                      {events ++ parsed, %{state | done: true, buffer: ""}}

                    _, acc ->
                      acc
                  end)

                {:error, reason} ->
                  throw({:stream_error, reason})

                :unknown ->
                  {[], state}
              end
          after
            timeout -> throw({:stream_error, "Provider stream timed out"})
          end
      end,
      fn _ -> Req.cancel_async_response(response) end
    )
  end
end
