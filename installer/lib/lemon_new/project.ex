defmodule LemonNew.Project do
  @moduledoc """
  Everything the templates need to know about the project being generated.

  Built once from the parsed command line so that template rendering is a pure
  function of this struct.
  """

  defstruct [
    :base_path,
    :app,
    :app_module,
    :app_path,
    :package_root,
    unpacked?: false,
    channel?: false,
    memory?: false
  ]

  @type t :: %__MODULE__{
          base_path: String.t(),
          app: String.t(),
          app_module: String.t(),
          app_path: String.t(),
          package_root: String.t(),
          unpacked?: boolean(),
          channel?: boolean(),
          memory?: boolean()
        }

  @doc """
  Build a project from the target path and parsed switches.

  `:app` defaults to the basename of the path, `:module` to its camel case.

  The platform packages come from exactly one of:

    * `:lemon_path` — a lemon checkout; each package is `apps/<package>`.
    * `:packages_path` — a directory of unpacked Hex tarballs, one
      `<package>/` per package (what `mix hex.build --unpack` produces). Only
      published packages are there, so `:channel` — which needs the unpublished
      `lemon_channels` — is rejected.
  """
  @spec new(String.t(), keyword()) :: t()
  def new(base_path, opts) do
    base_path = Path.expand(base_path)
    app = opts[:app] || Path.basename(base_path)
    module = opts[:module] || camelize(app)
    channel? = !!opts[:channel]
    {package_root, unpacked?} = package_source!(opts, channel?)

    %__MODULE__{
      base_path: base_path,
      app: app,
      app_module: module,
      app_path: app,
      package_root: package_root,
      unpacked?: unpacked?,
      channel?: channel?,
      memory?: !!opts[:memory]
    }
  end

  defp package_source!(opts, channel?) do
    case {opts[:lemon_path], opts[:packages_path]} do
      {nil, nil} ->
        raise ArgumentError, "expected a :lemon_path or a :packages_path"

      {lemon_path, nil} ->
        {Path.join(lemon_path, "apps"), false}

      {nil, _packages_path} when channel? ->
        raise ArgumentError, """
        --channel cannot be combined with --packages-path: the channel adapter \
        depends on lemon_channels, which is not a published package. Generate \
        it against a lemon checkout with --lemon-path instead.
        """

      {nil, packages_path} ->
        {packages_path, true}

      {_lemon_path, _packages_path} ->
        raise ArgumentError, "--lemon-path and --packages-path are mutually exclusive"
    end
  end

  @doc """
  Assigns passed to every template.

  Kept as a keyword list because that is what `EEx` binds under `@`.
  """
  @spec assigns(t()) :: keyword()
  def assigns(%__MODULE__{} = project) do
    [
      app: project.app,
      app_module: project.app_module,
      package_root: project.package_root,
      unpacked?: project.unpacked?,
      channel?: project.channel?,
      memory?: project.memory?
    ]
  end

  @doc """
  Validates an application name, raising with the reason if it is unusable.

  The rules are Mix's own: an atom-safe lowercase name that is also a valid
  Erlang application name.
  """
  @spec validate_app!(String.t()) :: :ok
  def validate_app!(app) do
    cond do
      not (app =~ ~r/^[a-z][a-z0-9_]*$/) ->
        raise ArgumentError, """
        application name must start with a lowercase letter and contain only \
        lowercase letters, numbers and underscores, got: #{inspect(app)}

        Pass --app to choose a different one, for example:

            mix lemon.new #{app} --app my_agent
        """

      app in ~w(mix elixir eex ex_unit iex logger) ->
        raise ArgumentError, "application name #{inspect(app)} collides with an OTP application"

      true ->
        :ok
    end
  end

  @doc """
  Validates a module name, raising with the reason if it is unusable.
  """
  @spec validate_module!(String.t()) :: :ok
  def validate_module!(module) do
    if module =~ ~r/^[A-Z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)*$/ do
      :ok
    else
      raise ArgumentError, """
      module name must be a valid Elixir alias, got: #{inspect(module)}

      Pass --module to choose a different one, for example:

          --module MyAgent
      """
    end
  end

  defp camelize(app) do
    app
    |> String.split("_")
    |> Enum.map_join("", &String.capitalize/1)
  end
end
