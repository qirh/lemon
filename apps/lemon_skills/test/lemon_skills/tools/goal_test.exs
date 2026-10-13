defmodule LemonSkills.Tools.GoalTest do
  use ExUnit.Case, async: true

  alias LemonSkills.Tools.Goal

  test "schema exposes bounded session-scoped lifecycle operations" do
    tool = Goal.tool(System.tmp_dir!(), session_key: "agent:default:goal-test")
    assert tool.name == "goal"

    assert tool.parameters["properties"]["action"]["enum"] ==
             ~w(set status start stop pause resume run_once)

    assert tool.parameters["properties"]["max_ticks"]["maximum"] == 20
    refute Map.has_key?(tool.parameters["properties"], "session_key")
  end

  test "missing session context does not silently target another session" do
    tool = Goal.tool(System.tmp_dir!())

    assert {:error, "missing session_key in tool context"} =
             tool.execute.("call", %{"action" => "status"}, nil, nil)
  end

  test "set requires an objective and existing target directory before calling runtime" do
    tool = Goal.tool(System.tmp_dir!(), session_key: "agent:default:goal-test")

    assert {:error, "missing objective"} =
             tool.execute.("call", %{"action" => "set"}, nil, nil)

    assert {:error, "cwd must name an existing directory"} =
             tool.execute.(
               "call",
               %{
                 "action" => "set",
                 "objective" => "Work",
                 "cwd" =>
                   Path.join(
                     System.tmp_dir!(),
                     "missing-goal-#{System.unique_integer([:positive])}"
                   )
               },
               nil,
               nil
             )
  end

  test "start rejects unbounded tick counts before dispatch" do
    tool = Goal.tool(System.tmp_dir!(), session_key: "agent:default:goal-test")

    for ticks <- [0, 21, "3", nil] do
      assert {:error, "max_ticks must be 1..20"} =
               tool.execute.("call", %{"action" => "start", "max_ticks" => ticks}, nil, nil)
    end
  end
end
