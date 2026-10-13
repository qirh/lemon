defmodule LemonSkills.Doctor.Checks.Skills do
  @moduledoc """
  Checks the global skills directory (`LemonSkills.Config.global_skills_dir/0`).

  Registered with the `LemonCore.Doctor` framework via
  `config :lemon_core, :doctor_checks, [__MODULE__]`.
  """

  alias LemonCore.Doctor.Check

  @doc """
  Returns a list of Check results covering the global skills directory.
  """
  @spec run(keyword()) :: [Check.t()]
  def run(_opts \\ []) do
    [
      check_skills_dir(LemonSkills.Config.global_skills_dir())
    ]
  end

  defp check_skills_dir(path) do
    cond do
      not File.exists?(path) ->
        Check.skip(
          "skills.directory",
          "Skills directory does not exist yet: #{path} (created on first install)."
        )

      not File.dir?(path) ->
        Check.fail(
          "skills.directory",
          "Expected a directory at #{path} but found a file.",
          "Remove or rename #{path} so Lemon can create the skills directory."
        )

      true ->
        case File.ls(path) do
          {:ok, entries} ->
            skill_dirs = Enum.count(entries, fn e -> File.dir?(Path.join(path, e)) end)

            Check.pass(
              "skills.directory",
              "Skills directory OK: #{skill_dirs} skill(s) installed."
            )

          {:error, reason} ->
            Check.warn(
              "skills.directory",
              "Could not list skills directory #{path}: #{inspect(reason)}.",
              "Check directory permissions."
            )
        end
    end
  end
end
