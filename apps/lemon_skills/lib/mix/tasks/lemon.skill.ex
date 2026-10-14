defmodule Mix.Tasks.Lemon.Skill do
  use Mix.Task

  @shortdoc "Manage Lemon skills"
  @moduledoc "Source wrapper for `lemon skill`. Run `lemon skill --help` for options."
  @requirements ["loadpaths"]

  @impl true
  def run(args) do
    LemonSkills.CLI.run(args)
  rescue
    error in LemonCore.CLI.Error -> Mix.raise(error.message)
  end
end
