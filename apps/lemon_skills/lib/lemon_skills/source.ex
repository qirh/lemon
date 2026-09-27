defmodule LemonSkills.Source do
  @moduledoc """
  Behaviour for skill sources.

  A source is a place from which skills can be discovered, inspected, and
  fetched. Each source kind implements this behaviour.

  ## Source kinds

  | Kind | Module | Trust |
  |------|--------|-------|
  | `:builtin` | `LemonSkills.Sources.Builtin` | `:builtin` |
  | `:local` | `LemonSkills.Sources.Local` | `:trusted` |
  | `:git` | `LemonSkills.Sources.Git` | `:community` |
  | `:git` | `LemonSkills.Sources.Github` | `:community` |
  | `:git` | `LemonSkills.Sources.Hermes` | `:official` |
  | `:registry` | `LemonSkills.Sources.Registry` | `:official` or `:community`, by namespace |

  ## Usage

      {:ok, mod, id} = LemonSkills.SourceRouter.resolve("https://github.com/acme/k8s-skill")
      # => {:ok, LemonSkills.Sources.Git, "https://github.com/acme/k8s-skill"}

      {:ok, dest} = mod.fetch(id, "/target/dir", [])
      trust        = mod.trust_for_ref(id)
  """

  alias LemonSkills.Entry

  @type source_id :: String.t() | nil
  @type search_result :: %{
          entry: Entry.t(),
          source: atom(),
          validated: boolean(),
          url: String.t()
        }

  @doc """
  Search for skills matching a query.

  Returns a list of search result maps. Each map has the same shape as
  `LemonSkills.Discovery.discovery_result/0`.
  """
  @callback search(query :: String.t(), opts :: keyword()) :: [search_result()]

  @doc """
  Fetch metadata about a skill without installing it.

  `id` is the canonical identifier returned by `LemonSkills.SourceRouter.resolve/1`.
  Returns `{:ok, info_map}` or `{:error, reason}`.
  """
  @callback inspect(id :: source_id(), opts :: keyword()) :: {:ok, map()} | {:error, term()}

  @doc """
  Download or copy a skill from `id` into `dest_dir`.

  Returns `{:ok, dest_dir}` on success so callers can chain into manifest loading.
  """
  @callback fetch(id :: source_id(), dest_dir :: String.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  Return the content hash of the latest upstream version of a skill.

  Used to detect when an installed skill is behind its source.
  Returns `{:ok, hash}` or `{:error, :unsupported}` for sources that do not
  support remote hash queries.
  """
  @callback upstream_hash(id :: source_id(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  Return the trust level assigned to this canonical source identifier.

  Registry sources derive trust from the identifier's namespace. Other sources
  assign the same trust to every identifier. Install and update use this same
  contract; a missing stored trust value must not promote a community ref.
  """
  @callback trust_for_ref(id :: source_id()) :: Entry.trust_level()
end
