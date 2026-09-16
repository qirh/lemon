defmodule LemonSkills.HttpClient.Httpc do
  @moduledoc "Default HTTP client, backed by Req."
  @behaviour LemonSkills.HttpClient

  @impl true
  def fetch(url, headers) do
    case Req.get(url, headers: headers) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, to_string(body)}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
