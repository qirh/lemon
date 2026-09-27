defmodule Mix.Tasks.Lemon.Policy do
  use Mix.Task

  @shortdoc "Manage channel model policies"
  @moduledoc "Source wrapper for `lemon policy`. Run `lemon policy --help` for options."
  @requirements ["loadpaths"]

  @impl true
  def run(args) do
    LemonChannels.ModelPolicy.CLI.run(args)
  rescue
    error in LemonCore.CLI.Error -> Mix.raise(error.message)
  end
end
