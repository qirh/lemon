defmodule LemonMemory.Query do
  @moduledoc """
  Turns free text into search terms and an SQLite FTS5 match expression.

  Memory search is lexical, so what a query *means* is decided here. The rules:

    * **Terms, not words.** Text is split on anything that is not a Unicode
      letter or digit, lowercased, and deduplicated. Terms shorter than two
      characters and English stopwords (including conversational filler and
      memory meta-words such as "remember" or "last time") are dropped: they
      match nearly every stored conversation and only add noise to the ranking.
    * **Any term may match.** Terms are `OR`-joined, so a paraphrase that shares
      one keyword with a stored conversation still finds it. Ordering is left to
      BM25, which scores each matched term by its rarity, so a document sharing
      more (and rarer) terms with the query generally ranks above one sharing a
      single common term.
    * **Longer terms match as prefixes.** A term of four or more characters is a
      prefix query (`"deploy"*` also finds "deployment"), a cheap stand-in for
      stemming.
    * **Nothing is an operator.** Every term is double-quoted, so user text such
      as `NOT`, `NEAR`, or `-` is searched for rather than interpreted.

  A query with more than 24 distinct terms keeps the longest ones (in their
  original order), which bounds the cost of matching a long pasted prompt.
  """

  @prefix_min_length 4
  @max_terms 24

  @stopwords ~w(
    a about above after again against all also am an and any are as at be because
    been before being below between both but by can could did do does doing done
    down during each else etc even ever every few for from further get gets got had
    has have having he her here hers herself him himself his how however i if in
    into is it its itself just let lets like may me might mine more most much must
    my myself need no nor not now of off on once only or other our ours ourselves
    out over own per please same shall she should so some such than that the their
    theirs them themselves then there these they this those through thus to too
    under until up upon us very via was we were what whatever when where whether
    which while who whom whose why will with within without would yes yet you your
    yours yourself yourselves
    re ve ll don didn doesn isn wasn aren weren won wouldn couldn shouldn haven hasn
    hadn cant dont didnt doesnt isnt wasnt im ive youre thats whats
    hey hi hello ok okay thanks thank sure great cool nice yeah yep nope want wants
    know tell told say said says ask asked mention mentioned talk talked
    remember remembered recall recalled last time earlier previous previously
  )

  @stopword_set MapSet.new(@stopwords)

  @doc """
  The distinct search terms in `text`, in order of first appearance.

  ## Examples

      iex> LemonMemory.Query.terms("How do I deploy the Deploy-bot to production?")
      ["deploy", "bot", "production"]

      iex> LemonMemory.Query.terms("thanks, ok!")
      []
  """
  @spec terms(term()) :: [String.t()]
  def terms(text) when is_binary(text) do
    ~r/[\p{L}\p{N}]+/u
    |> Regex.scan(String.downcase(text))
    |> Enum.map(fn [term] -> term end)
    |> Enum.reject(&(String.length(&1) < 2 or MapSet.member?(@stopword_set, &1)))
    |> Enum.uniq()
    |> keep_most_specific()
  end

  def terms(_text), do: []

  @doc """
  The FTS5 `MATCH` expression for `text`, or `nil` when it has no search terms.

  ## Examples

      iex> LemonMemory.Query.fts_match("deploy the api")
      ~s("deploy"* OR "api")

      iex> LemonMemory.Query.fts_match("what is it?")
      nil
  """
  @spec fts_match(term()) :: String.t() | nil
  def fts_match(text) do
    case terms(text) do
      [] -> nil
      terms -> Enum.map_join(terms, " OR ", &fts_term/1)
    end
  end

  @doc """
  How many of `terms` occur in `text`, matched the way `fts_match/1` matches
  them: whole words, and word prefixes for terms of four or more characters.

  ## Examples

      iex> LemonMemory.Query.shared_term_count(["deploy", "prod", "helm"], "Deployment to production")
      2
  """
  @spec shared_term_count([String.t()], String.t()) :: non_neg_integer()
  def shared_term_count(terms, text) when is_list(terms) and is_binary(text) do
    words =
      ~r/[\p{L}\p{N}]+/u
      |> Regex.scan(String.downcase(text))
      |> Enum.map(fn [word] -> word end)
      |> Enum.uniq()

    word_set = MapSet.new(words)

    Enum.count(terms, fn term ->
      if String.length(term) >= @prefix_min_length do
        Enum.any?(words, &String.starts_with?(&1, term))
      else
        MapSet.member?(word_set, term)
      end
    end)
  end

  # Terms contain only letters and digits, so quoting needs no escaping.
  defp fts_term(term) do
    if String.length(term) >= @prefix_min_length, do: ~s("#{term}"*), else: ~s("#{term}")
  end

  defp keep_most_specific(terms) when length(terms) <= @max_terms, do: terms

  defp keep_most_specific(terms) do
    keep =
      terms
      |> Enum.with_index()
      |> Enum.sort_by(fn {term, index} -> {-String.length(term), index} end)
      |> Enum.take(@max_terms)
      |> MapSet.new(fn {_term, index} -> index end)

    terms
    |> Enum.with_index()
    |> Enum.filter(fn {_term, index} -> MapSet.member?(keep, index) end)
    |> Enum.map(fn {term, _index} -> term end)
  end
end
