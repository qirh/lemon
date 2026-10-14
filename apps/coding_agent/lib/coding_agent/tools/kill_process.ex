defmodule CodingAgent.Tools.KillProcess do
  @moduledoc """
  `kill_process` tool: stop a background process started by `bash` with
  `run_in_background: true`. The whole process tree is killed. A session can
  only kill processes it started.
  """

  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias CodingAgent.ProcessManager
  alias CodingAgent.Tools.BashOutput

  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "kill_process",
      description:
        "Kill a background process (and its children) started with bash run_in_background.",
      label: "Kill Process",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "process_id" => %{
            "type" => "string",
            "description" => "The process_id returned by bash with run_in_background"
          }
        },
        "required" => ["process_id"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @spec execute(String.t(), map(), reference() | nil, function() | nil, String.t(), keyword()) ::
          AgentToolResult.t() | {:error, String.t()}
  def execute(_tool_call_id, params, _signal, _on_update, _cwd, opts) do
    with {:ok, process_id} <- BashOutput.fetch_process_id(params),
         :ok <- BashOutput.authorize(process_id, opts) do
      kill(process_id)
    end
  end

  defp kill(process_id) do
    case ProcessManager.kill(process_id, :sigkill) do
      :ok ->
        %AgentToolResult{
          content: [%TextContent{text: "Killed background process #{process_id}."}],
          details: %{process_id: process_id, status: :killed, exit_code: nil}
        }

      {:error, :process_not_running} ->
        {:error, "Process #{process_id} is not running (status: #{current_status(process_id)})."}

      {:error, :not_found} ->
        {:error, "No background process with id #{process_id}"}

      {:error, reason} ->
        {:error, "Failed to kill process #{process_id}: #{inspect(reason)}"}
    end
  end

  defp current_status(process_id) do
    case ProcessManager.poll(process_id, lines: 0) do
      {:ok, %{status: status, exit_code: exit_code}} ->
        BashOutput.describe_status(status, exit_code)

      _ ->
        "unknown"
    end
  end
end
