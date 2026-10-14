defmodule Mix.Tasks.Lemon.Media do
  use Mix.Task

  @shortdoc "Show redacted generated-media diagnostics"
  @moduledoc "Source wrapper for `lemon media`. Run `lemon media --help` for options."
  @requirements ["loadpaths"]

  @impl true
  def run(args) do
    LemonMedia.CLI.run(args)
  rescue
    error in LemonCore.CLI.Error -> Mix.raise(error.message)
  end
end
