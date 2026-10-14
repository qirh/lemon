defmodule LemonControlPlane.Methods.SkillsMethodsTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.SkillsInstall

  setup do
    # Clean up any existing test data
    :ok
  end

  describe "SkillsInstall" do
    test "name returns correct method name" do
      assert SkillsInstall.name() == "skills.install"
    end

    test "scopes returns admin scope" do
      assert SkillsInstall.scopes() == [:admin]
    end

    test "returns error when skillKey is missing" do
      ctx = %{auth: %{role: :operator}}
      params = %{}

      {:error, error} = SkillsInstall.handle(params, ctx)

      assert error == {:invalid_request, "skillKey is required"}
    end

    test "returns error when skillKey is empty" do
      ctx = %{auth: %{role: :operator}}
      params = %{"skillKey" => ""}

      {:error, error} = SkillsInstall.handle(params, ctx)

      assert error == {:invalid_request, "skillKey is required"}
    end
  end
end
