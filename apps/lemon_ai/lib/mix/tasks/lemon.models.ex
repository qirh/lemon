defmodule Mix.Tasks.Lemon.Models do
  use Mix.Task

  @shortdoc "List known Lemon AI models"
  @moduledoc "Source wrapper for `lemon models`. Run `lemon models --help` for options."
  @requirements ["loadpaths"]

  @impl true
  def run(args) do
    LemonAi.Models.CLI.run(args)
  rescue
    error in LemonAi.Models.CLI.Error -> Mix.raise(error.message)
  end
end
