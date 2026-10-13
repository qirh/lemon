# lemon_new

`mix lemon.new` — the project generator for the Lemon agent platform.

This is a standalone Mix project, not an umbrella app. It is installed as a Mix
archive, which is why it has no dependencies: an archive cannot carry any. The
templates under `templates/` are read at compile time and embedded in the beam
files. Its `mix.exs` is self-contained (package metadata, nothing read from
outside this directory), so the same source builds as a Hex package; it has not
been published yet.

## Install it

From a lemon checkout:

    cd installer
    MIX_ENV=prod mix archive.build
    mix archive.install lemon_new-0.1.0.ez

Once `lemon_new` is published to Hex, no checkout is needed:

    mix archive.install hex lemon_new

## Use it

    mix lemon.new my_agent
    cd my_agent
    mix test

There are three ways to say where the platform packages come from:

| Flag | `mix.exs` gets | Needs |
|---|---|---|
| `--hex` | `{:lemon_core, "~> 0.2"}` … Hex requirements | nothing local; resolves once 0.2.0 is on hex.pm |
| *(default)*, `--lemon-path DIR` | path dependencies on a lemon checkout, with the Hex requirement commented beneath each | a checkout: `DIR`, `$LEMON_PATH`, or the one the archive was built from |
| `--packages-path DIR` | path dependencies on unpacked Hex tarballs (`DIR/lemon_core`, …) | what `mix hex.build --unpack` writes; `scripts/verify_packages` uses it |

With no flag and no known checkout (an archive installed from Hex) the
generator uses `--hex`. The three are mutually exclusive.

`--channel` generates an adapter for `LemonChannels.Plugin`, and `lemon_channels`
is not a published package, so `--channel` needs a checkout (`--lemon-path`) and
is refused with `--hex` and `--packages-path` rather than generating a project
that cannot resolve.

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
