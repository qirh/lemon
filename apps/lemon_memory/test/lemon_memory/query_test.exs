defmodule LemonMemory.QueryTest do
  use ExUnit.Case, async: true

  alias LemonMemory.Query

  doctest LemonMemory.Query

  test "terms drop stopwords, filler, and memory meta-words" do
    assert Query.terms("Do you remember what I said last time about the Helix editor?") ==
             ["helix", "editor"]
  end

  test "a long prompt keeps its most specific terms, in order" do
    filler = Enum.map_join(1..40, " ", &"w#{&1}")
    terms = Query.terms("kubernetes " <> filler <> " observability")

    assert length(terms) == 24
    assert List.first(terms) == "kubernetes"
    assert List.last(terms) == "observability"
  end
end
