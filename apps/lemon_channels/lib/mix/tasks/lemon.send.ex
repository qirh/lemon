defmodule Mix.Tasks.Lemon.Send do
  use Mix.Task

  @shortdoc "Send a Telegram or Discord notification from a script"
  @moduledoc "Source wrapper for `lemon send`. Run `lemon send --help` for options."
  @requirements ["loadpaths"]

  @impl true
  def run(args) do
    LemonChannels.ScriptSend.CLI.run(args)
  rescue
    error in LemonCore.CLI.Error ->
      Mix.shell().error(error.message)
      System.halt(error.exit_code)
  end
end
