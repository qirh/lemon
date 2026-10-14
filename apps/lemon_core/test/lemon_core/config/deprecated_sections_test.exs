defmodule LemonCore.Config.DeprecatedSectionsTest do
  @moduledoc """
  Tests for deprecated section detection in configuration.
  """
  use ExUnit.Case, async: true

  alias LemonCore.Config.Modular
  alias LemonCore.Config.Validator
  alias LemonCore.Config.ValidationError

  describe "Modular.check_deprecated_sections!/1" do
    test "returns :ok for valid settings with no deprecated sections" do
      settings = %{
        "defaults" => %{"provider" => "anthropic", "model" => "claude-sonnet-4"},
        "runtime" => %{"theme" => "lemon"},
        "providers" => %{}
      }

      assert :ok = Modular.check_deprecated_sections!(settings)
    end

    test "returns :ok for empty settings" do
      assert :ok = Modular.check_deprecated_sections!(%{})
    end

    test "does not reject the legacy [agent] alias" do
      assert :ok =
               Modular.check_deprecated_sections!(%{
                 "agent" => %{"default_model" => "claude-sonnet-4", "tools" => %{"web" => %{}}}
               })
    end

    test "raises when [agents] section is present" do
      settings = %{
        "agents" => %{"default" => %{"name" => "My Agent"}}
      }

      assert_raise ValidationError, ~r/\[agents\.<id>\] is deprecated/, fn ->
        Modular.check_deprecated_sections!(settings)
      end
    end

    test "collects multiple deprecation errors" do
      settings = %{
        "agents" => %{"default" => %{}},
        "tools" => %{"web" => %{}}
      }

      error =
        assert_raise ValidationError, fn ->
          Modular.check_deprecated_sections!(settings)
        end

      assert length(error.errors) == 2
    end

    test "raises when top-level [tools] section is present" do
      settings = %{
        "tools" => %{"web" => %{"search" => %{"provider" => "brave"}}}
      }

      assert_raise ValidationError, ~r/\[tools\.\*\] is deprecated/, fn ->
        Modular.check_deprecated_sections!(settings)
      end
    end
  end

  describe "Validator.validate_deprecated_sections/1" do
    test "returns :ok for valid settings" do
      assert :ok =
               Validator.validate_deprecated_sections(%{
                 "defaults" => %{"model" => "test"},
                 "runtime" => %{}
               })
    end

    test "returns error tuple for [agents] section" do
      assert {:error, errors} =
               Validator.validate_deprecated_sections(%{
                 "agents" => %{"default" => %{}}
               })

      assert Enum.any?(errors, &String.contains?(&1, "[agents.<id>] is deprecated"))
    end

    test "returns error tuple for top-level [tools] section" do
      assert {:error, errors} =
               Validator.validate_deprecated_sections(%{
                 "tools" => %{"web" => %{"search" => %{}}}
               })

      assert Enum.any?(errors, &String.contains?(&1, "[tools.*] is deprecated"))
    end
  end

  describe "Validator.deprecation_warnings/1" do
    test "warns about a legacy [agent] table and names the migration command" do
      assert [warning] = Validator.deprecation_warnings(%{"agent" => %{"theme" => "dark"}})
      assert warning =~ "[agent] is deprecated"
      assert warning =~ "lemon config migrate"
    end

    test "is empty for canonical settings or a non-table agent key" do
      assert [] = Validator.deprecation_warnings(%{"defaults" => %{"model" => "x"}})
      assert [] = Validator.deprecation_warnings(%{"agent" => "not-a-map"})
    end
  end

  describe "Modular.validate_settings/1" do
    test "accepts a legacy [agent] table as its canonical sections" do
      assert {:ok, config} =
               Modular.validate_settings(%{
                 "agent" => %{"default_provider" => "openai", "default_model" => "openai:gpt-5"}
               })

      assert config.agent.default_provider == "openai"
      assert config.agent.default_model == "openai:gpt-5"
    end

    test "rejects [runtime.cli] reached through a legacy [agent.cli] table" do
      assert {:error, errors} =
               Modular.validate_settings(%{"agent" => %{"cli" => %{"codex" => %{}}}})

      assert Enum.any?(errors, &String.contains?(&1, "[runtime.cli]"))
    end
  end
end
