# lemon_new

`mix lemon.new` — the project generator for the Lemon agent platform.

This is a standalone Mix project, not an umbrella app. It is built and
installed as a Mix archive, which is why it has no dependencies: an archive
cannot carry any. The templates under `templates/` are read at compile time and
embedded in the generated beam files.

## Install it

    cd installer
    MIX_ENV=prod mix archive.build
    mix archive.install lemon_new-0.1.0.ez

## Use it

    mix lemon.new my_agent
    cd my_agent
    mix test

The generated project depends on the platform packages by path on a lemon
checkout, with the matching Hex requirement commented beneath each. The path is
baked in from the checkout the archive was built from; override it with
`--lemon-path` or `$LEMON_PATH`. `lemon_new` itself is not on Hex: build the
archive from a checkout as above.

`--packages-path DIR` points the project at unpacked Hex tarballs instead
(`DIR/lemon_core`, `DIR/lemon_ai`, …). `scripts/verify_packages` uses it to
build a generated project from exactly what ships; it cannot be combined with
`--channel`, because `lemon_channels` is not a published package.

Run `mix help lemon.new` for the full option list.

## Work on it

    cd installer
    mix test

The suite generates projects into a temporary directory and asserts on their
contents. It does not compile them — that would mean fetching the platform's
whole dependency tree per test. Two scripts compile generated projects and run
their tests: `scripts/verify_generator` against this checkout (both shapes,
including `--channel`), and `scripts/verify_packages` against the unpacked Hex
tarballs of the five published packages. The `packaging.yml` workflow runs both.

## Adding a template

1. Put the `.eex` file under `templates/base`, `templates/channel` or
   `templates/memory`.
2. Add a `{template, destination}` pair to the matching list in
   `LemonNew.Generator`. Destinations may contain `:app`, which is replaced with
   the application name.

Generated `.ex` and `.exs` files are run through `Code.format_string!/1`, so a
template that no longer parses fails generation instead of producing a broken
project.
