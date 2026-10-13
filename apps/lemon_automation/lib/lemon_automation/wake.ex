defmodule LemonAutomation.Wake do
  @moduledoc """
  Wake functionality to trigger immediate cron job execution.

  Wake allows triggering any cron job to run immediately, bypassing
  the normal schedule. This is useful for:

  - Testing job configurations
  - Manual intervention during incidents
  - On-demand automation triggers
  - Integration with external systems

  ## Usage

      # Trigger a job by ID
      {:ok, run} = Wake.trigger("cron_abc123")

      # Trigger with custom context
      {:ok, run} = Wake.trigger("cron_abc123", context: %{reason: "manual test"})

      # Trigger multiple jobs
      results = Wake.trigger_many(["cron_abc", "cron_xyz"])

  ## Events

  Wake operations emit `:cron_run_started` events with `triggered_by: :wake`
  to distinguish them from scheduled runs.
  """

  alias LemonAutomation.{CronManager, CronRun, CronStore}

  @doc """
  Trigger a cron job to run immediately.

  Returns `{:ok, run}` with the created CronRun, or an error tuple.

  ## Options

  - `:context` - Additional context map to include in run metadata
  - `:skip_if_running` - Don't trigger if job already has an active run (default: false)
  """
  @spec trigger(binary(), keyword()) :: {:ok, CronRun.t()} | {:error, term()}
  def trigger(job_id, opts \\ []) do
    CronManager.wake(job_id, opts)
  end

  @doc """
  Trigger multiple cron jobs to run immediately.

  Returns a map of job_id => result for each job.
  """
  @spec trigger_many([binary()], keyword()) :: %{
          binary() => {:ok, CronRun.t()} | {:error, term()}
        }
  def trigger_many(job_ids, opts \\ []) when is_list(job_ids) do
    job_ids
    |> Enum.map(fn job_id -> {job_id, trigger(job_id, opts)} end)
    |> Map.new()
  end

  @doc """
  Trigger all enabled jobs matching a pattern in their name.

  ## Examples

      # Trigger all heartbeat jobs
      Wake.trigger_matching("heartbeat")

      # Trigger all daily report jobs
      Wake.trigger_matching("daily")
  """
  @spec trigger_matching(binary(), keyword()) :: %{
          binary() => {:ok, CronRun.t()} | {:error, term()}
        }
  def trigger_matching(pattern, opts \\ []) when is_binary(pattern) do
    pattern_downcase = String.downcase(pattern)

    CronStore.list_enabled_jobs()
    |> Enum.filter(fn job ->
      String.contains?(String.downcase(job.name), pattern_downcase)
    end)
    |> Enum.map(& &1.id)
    |> trigger_many(opts)
  end

  @doc """
  Trigger all enabled jobs for a specific agent.
  """
  @spec trigger_for_agent(binary(), keyword()) :: %{
          binary() => {:ok, CronRun.t()} | {:error, term()}
        }
  def trigger_for_agent(agent_id, opts \\ []) when is_binary(agent_id) do
    CronStore.list_enabled_jobs()
    |> Enum.filter(fn job -> job.agent_id == agent_id end)
    |> Enum.map(& &1.id)
    |> trigger_many(opts)
  end
end
