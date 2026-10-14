defmodule LemonMCP do
  @moduledoc """
  LemonMCP is Lemon's Model Context Protocol (MCP) client library.

  MCP is an open protocol that enables seamless integration between LLM applications
  and external data sources and tools. This library connects Lemon to external MCP
  servers; `LemonSkills.McpSource` loads it to expose their tools to agents.

  ## Components

  - `LemonMCP.Protocol` - MCP message types and JSON-RPC handling
  - `LemonMCP.Transport.Stdio` - Stdio transport for MCP servers
  - `LemonMCP.Client` - GenServer client for stdio MCP servers
  - `LemonMCP.Client.HTTP` - Streamable HTTP client
  - `LemonMCP.Client.SSE` - Legacy HTTP+SSE client
  - `LemonMCP.Sampling` - Policy-gated handling of server `sampling/createMessage` requests

  ## Quick Start

      # Start a client connection to an MCP server
      {:ok, client} = LemonMCP.Client.start_link(
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/files"]
      )

      # List available tools
      {:ok, tools} = LemonMCP.Client.list_tools(client)

      # Call a tool
      {:ok, result} = LemonMCP.Client.call_tool(client, "read_file", %{"path" => "/path/to/file.txt"})

  ## Protocol Version

  This implementation targets MCP protocol version "2024-11-05".
  """

  alias LemonMCP.Protocol

  @doc """
  Returns the supported MCP protocol version.
  """
  @spec protocol_version() :: String.t()
  def protocol_version, do: Protocol.protocol_version()

  @doc """
  Creates a JSON-RPC success response.

  ## Examples

      iex> LemonMCP.create_response("1", %{tools: []})
      %LemonMCP.Protocol.JSONRPCResponse{...}

  """
  @spec create_response(Protocol.request_id(), any()) :: Protocol.JSONRPCResponse.t()
  def create_response(id, result) do
    Protocol.create_response(id, result)
  end

  @doc """
  Encodes an MCP message to JSON string.

  ## Examples

      iex> response = LemonMCP.create_response("1", %{tools: []})
      iex> LemonMCP.encode!(response)
      ~s|{"jsonrpc":"2.0","id":"1","result":{"tools":[]}}|

  """
  @spec encode!(struct()) :: String.t()
  def encode!(message) do
    Protocol.encode!(message)
  end
end
