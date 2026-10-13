defmodule Mix.Tasks.Lemon.Secrets.RotateKey do
  use Mix.Task

  alias LemonCore.Secrets.KeyRotation

  @shortdoc "Rotate the secrets master key and re-encrypt stored secrets"
  @moduledoc """
  Replaces the secrets master key and re-encrypts every stored secret under it.

  Without options the task only previews: it checks that every stored secret
  decrypts with the current key and prints a confirmation token bound to the
  exact set of secrets. Apply with that token:

      mix lemon.secrets.rotate_key
      mix lemon.secrets.rotate_key --confirm <token>

  The token is refused when any secret changed since the preview. Stop any
  running Lemon runtime first: it keeps using the key it loaded at boot. See
  `LemonCore.Secrets.KeyRotation` for the crash-safety guarantees.
  """

  @impl true
  def run(args) do
    {parsed, rest, invalid} = OptionParser.parse(args, strict: [confirm: :string])

    if rest != [] or invalid != [] do
      Mix.raise("Usage: mix lemon.secrets.rotate_key [--confirm <token>]")
    end

    start_lemon_core!()

    case parsed[:confirm] do
      nil -> preview()
      token -> rotate(token)
    end
  end

  defp preview do
    case KeyRotation.preview() do
      {:ok, preview} ->
        Mix.shell().info("""
        Secrets master key rotation preview (nothing changed)
        key source: #{format_source(preview)}
        secrets to re-encrypt: #{preview.count}
        expired secrets to delete: #{preview.expired}
        resumed from an interrupted rotation: #{preview.resumed}
        confirmation token: #{preview.confirmation_token}

        Apply with: mix lemon.secrets.rotate_key --confirm #{preview.confirmation_token}\
        """)

      {:error, reason} ->
        Mix.raise(error_message(reason))
    end
  end

  defp rotate(token) do
    case KeyRotation.rotate(token) do
      {:ok, result} ->
        Mix.shell().info(
          "Rotated secrets master key in #{format_source(result)}: " <>
            "#{result.rotated} secrets re-encrypted, #{result.pruned} expired deleted"
        )

      {:error, reason} ->
        Mix.raise(error_message(reason))
    end
  end

  defp format_source(%{source: :file, key_file: path}) when is_binary(path), do: "file (#{path})"
  defp format_source(%{source: source}), do: to_string(source)

  defp error_message(reason),
    do: "Secrets key rotation failed: " <> KeyRotation.describe_error(reason)

  defp start_lemon_core! do
    Mix.Task.run("loadpaths")

    case Application.ensure_all_started(:lemon_core) do
      {:ok, _} -> :ok
      {:error, {app, reason}} -> Mix.raise("Failed to start #{app}: #{inspect(reason)}")
    end
  end
end
