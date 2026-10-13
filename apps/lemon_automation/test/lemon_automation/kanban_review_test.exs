defmodule LemonAutomation.KanbanReviewTest do
  use ExUnit.Case, async: true
  alias LemonAutomation.KanbanReview

  test "accepts only an explicit bounded JSON verdict" do
    assert {:ok, %{"approved" => true}} =
             KanbanReview.parse(~s({"approved":true,"findings":"No blockers"}))

    assert {:ok, %{"approved" => false}} =
             KanbanReview.parse("```json\n{\"approved\":false,\"findings\":\"Fix the bug\"}\n```")

    for output <- [
          "Looks good",
          ~s({"approved":"true","findings":"ok"}),
          ~s({"approved":true}),
          ~s({"approved":true,"findings":"ok","skip":true}),
          Jason.encode!(%{approved: true, findings: String.duplicate("x", 8193)}),
          nil
        ] do
      assert {:error, :invalid_review_result} = KanbanReview.parse(output)
    end
  end

  test "missing reviewer cannot waive independent review" do
    assert {:error, :reviewer_unavailable} =
             KanbanReview.params(%{}, %{"cwd" => "/repo"}, %{}, %{}, "run",
               reviewer_resolver: fn _, _ -> {:error, :missing} end
             )
  end
end
