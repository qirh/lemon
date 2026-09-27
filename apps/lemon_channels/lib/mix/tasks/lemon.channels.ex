defmodule Mix.Tasks.Lemon.Channels do
  @moduledoc """
  Show redacted Telegram and Discord configuration status.

  ## Usage

      mix lemon.channels
      mix lemon.channels --project-dir /path/to/project
      mix lemon.channels --json

  ## Options

    * `--project-dir` - Project root to read config from. Defaults to the current directory.
    * `--json` - Emit the raw redacted channel diagnostics JSON.
  """

  use Mix.Task

  alias LemonChannels.Doctor.Diagnostics

  @impl true
  def run(args) do
    {opts, _rest, invalid} =
      OptionParser.parse(args,
        strict: [
          project_dir: :string,
          json: :boolean
        ]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    project_dir = opts[:project_dir] || File.cwd!()
    status = Diagnostics.status(project_dir: project_dir)

    if opts[:json] do
      Mix.shell().info(Jason.encode!(status, pretty: true))
    else
      status |> Diagnostics.format_text() |> Enum.each(&Mix.shell().info/1)
    end
  end
end
