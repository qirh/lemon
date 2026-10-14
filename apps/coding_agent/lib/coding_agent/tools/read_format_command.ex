defmodule CodingAgent.Tools.ReadFormatCommand do
  @moduledoc false

  import LemonAgent.Tools.AbortHelpers, only: [check_abort: 1]

  def run(executable, args, signal, opts \\ []) do
    with :ok <- check_abort(signal),
         {:ok, port} <- open(executable, args) do
      try do
        collect(
          port,
          [],
          0,
          signal,
          System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout_ms, 30_000),
          Keyword.get(opts, :max_bytes, 32 * 1024 * 1024)
        )
      after
        close(port)
      end
    end
  end

  defp open(executable, args) do
    {:ok,
     Port.open({:spawn_executable, executable}, [
       :binary,
       :exit_status,
       :stderr_to_stdout,
       args: args,
       env: [{~c"PYTHONIOENCODING", ~c"utf-8"}]
     ])}
  rescue
    error -> {:error, "Cannot start document backend: #{Exception.message(error)}"}
  end

  # The command can exit between any liveness check and the close, and closing
  # an already-closed port raises; either way the port is gone.
  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp collect(port, chunks, size, signal, deadline, max_bytes) do
    with :ok <- check_abort(signal) do
      if System.monotonic_time(:millisecond) >= deadline do
        {:error, "Document backend timed out. Select fewer pages or a smaller document."}
      else
        receive do
          {^port, {:data, bytes}} ->
            if size + byte_size(bytes) > max_bytes do
              {:error,
               "Document backend output exceeds #{max_bytes} bytes. Select fewer pages with page/page_limit."}
            else
              collect(
                port,
                [bytes | chunks],
                size + byte_size(bytes),
                signal,
                deadline,
                max_bytes
              )
            end

          {^port, {:exit_status, 0}} ->
            {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

          {^port, {:exit_status, status}} ->
            output = chunks |> Enum.reverse() |> IO.iodata_to_binary()

            {:error,
             "Document backend exited with status #{status}: #{String.slice(output, 0, 2000)}"}
        after
          50 -> collect(port, chunks, size, signal, deadline, max_bytes)
        end
      end
    end
  end
end
