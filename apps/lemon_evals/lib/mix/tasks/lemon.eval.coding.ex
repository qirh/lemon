defmodule Mix.Tasks.Lemon.Eval.Coding do
  use Mix.Task

  @shortdoc "Run the opt-in live production-CLI coding benchmark"
  @moduledoc """
  Runs eight real coding tasks in temporary git repositories through `lemon -p`.
  Requires a configured model and a healthy daemon (or the standard launcher).
  Does not start umbrella applications in this Mix VM.

      mix lemon.eval.coding --output /tmp/lemon-coding-benchmark.json

  Options: --model PROVIDER:MODEL, --lemon PATH, --output PATH, --timeout SECONDS.
  This is a paid, opt-in lane, deliberately excluded from fast checks.
  """

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          model: :string,
          lemon: :string,
          output: :string,
          timeout: :integer,
          failure_dir: :string,
          compare_omp: :boolean,
          omp: :string,
          omp_model: :string,
          tasks: :string
        ]
      )

    if rest != [] or invalid != [], do: Mix.raise("Invalid coding benchmark arguments")
    timeout = opts[:timeout] || 660
    if timeout <= 0, do: Mix.raise("--timeout must be positive")
    python = System.find_executable("python3") || Mix.raise("python3 is required")
    launcher = Path.expand(opts[:lemon] || "bin/lemon")
    script = Path.join(:code.priv_dir(:lemon_evals), "coding_benchmark.py")

    argv = [
      script,
      "--lemon",
      launcher,
      "--model",
      opts[:model] || "openai-codex:gpt-6.1-sol",
      "--output",
      Path.expand(opts[:output] || "/tmp/lemon-coding-benchmark.json"),
      "--timeout",
      Integer.to_string(timeout)
    ]

    argv =
      if opts[:failure_dir],
        do: argv ++ ["--failure-dir", Path.expand(opts[:failure_dir])],
        else: argv

    argv = if opts[:compare_omp], do: argv ++ ["--compare-omp"], else: argv

    argv =
      Enum.reduce(
        [{:omp, "--omp"}, {:omp_model, "--omp-model"}, {:tasks, "--tasks"}],
        argv,
        fn {key, flag}, current ->
          if opts[key], do: current ++ [flag, opts[key]], else: current
        end
      )

    {_output, status} =
      System.cmd(python, argv, into: IO.stream(:stdio, :line), stderr_to_stdout: true)

    if status != 0, do: Mix.raise("Live coding benchmark failed; inspect its result artifact")
  end
end
