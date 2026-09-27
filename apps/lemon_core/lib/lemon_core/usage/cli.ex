defmodule LemonCore.Usage.CLI do
  @moduledoc """
  Show redacted usage, cost, token, and quota diagnostics.

  ## Usage

      lemon usage
      lemon usage --json

  ## Options

    * `--json` - Emit the raw redacted usage diagnostics JSON.
  """

  alias LemonCore.UsageDiagnostics

  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    if invalid != [] or rest != [] do
      LemonCore.CLI.fail!("Invalid arguments. Run `lemon usage --help`.", 2)
    end

    LemonCore.CLI.start!(:lemon_core)

    status = UsageDiagnostics.status()

    if opts[:json] do
      LemonCore.CLI.info(Jason.encode!(status, pretty: true))
    else
      print_text(status)
    end
  end

  defp print_text(status) do
    cleanup = Map.get(status, :cleanup, %{})
    tokens = Map.get(status, :total_tokens, %{})
    today = Map.get(status, :today, %{})

    LemonCore.CLI.info("Lemon Usage")
    LemonCore.CLI.info("Status: #{Map.get(status, :status, "unknown")}")
    LemonCore.CLI.info("Period: #{Map.get(status, :period, "current")}")
    LemonCore.CLI.info("Requests: #{Map.get(status, :total_requests, 0)}")
    LemonCore.CLI.info("Cost: #{format_money(Map.get(status, :total_cost, 0.0))}")
    LemonCore.CLI.info("Tokens input: #{Map.get(tokens, :input, 0)}")
    LemonCore.CLI.info("Tokens output: #{Map.get(tokens, :output, 0)}")
    LemonCore.CLI.info("Tokens total: #{Map.get(tokens, :total, 0)}")

    LemonCore.CLI.info("Today: #{Map.get(today, :date, "unknown")} requests=#{Map.get(today, :requests, 0)} cost=#{format_money(Map.get(today, :cost, 0.0))}")

    LemonCore.CLI.info("Includes prompts: #{truthy?(cleanup[:includes_prompts])}")
    LemonCore.CLI.info("Includes responses: #{truthy?(cleanup[:includes_responses])}")
    LemonCore.CLI.info("Includes message bodies: #{truthy?(cleanup[:includes_message_bodies])}")
    LemonCore.CLI.info("Includes credentials: #{truthy?(cleanup[:includes_credentials])}")
    LemonCore.CLI.info("Includes secret values: #{truthy?(cleanup[:includes_secret_values])}")
    print_quotas(Map.get(status, :quotas, %{}))
    print_providers(Map.get(status, :providers, []))
  end

  defp print_quotas(quotas) do
    LemonCore.CLI.info("Quotas:")
    LemonCore.CLI.info("  runs_limit: #{display_limit(quotas[:runs_limit])}")
    LemonCore.CLI.info("  tokens_limit: #{display_limit(quotas[:tokens_limit])}")
    LemonCore.CLI.info("  cost_limit: #{display_limit(quotas[:cost_limit])}")
  end

  defp print_providers([]) do
    LemonCore.CLI.info("Providers: none")
  end

  defp print_providers(providers) do
    LemonCore.CLI.info("Providers:")

    Enum.each(providers, fn provider ->
      LemonCore.CLI.info("  #{provider.provider}: requests=#{provider.requests} cost=#{format_money(provider.cost)} input_tokens=#{provider.input_tokens} output_tokens=#{provider.output_tokens}")
    end)
  end

  defp display_limit(nil), do: "unlimited"
  defp display_limit(limit), do: to_string(limit)

  defp format_money(value) when is_number(value),
    do: :erlang.float_to_binary(value * 1.0, decimals: 4)

  defp format_money(_), do: "0.0000"

  defp truthy?(value), do: if(value, do: "true", else: "false")
end
