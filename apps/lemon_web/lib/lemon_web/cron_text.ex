defmodule LemonWeb.CronText do
  @moduledoc """
  Human-readable descriptions of normalized 5-field cron expressions.

  Covers the shapes Lemon's scheduler shorthands produce (intervals, hourly,
  daily, weekdays, weekly, monthly) plus common hand-written variants. Anything
  else falls back to "Custom schedule" so the raw expression stays the source
  of truth next to it.
  """

  @days ~w(Sunday Monday Tuesday Wednesday Thursday Friday Saturday)
  @months ~w(January February March April May June July August September October November December)

  @doc "Describes `expression` (e.g. `\"0 9 * * 1-5\"` → `\"Weekdays at 09:00\"`)."
  @spec describe(String.t() | nil) :: String.t()
  def describe(expression) when is_binary(expression) do
    case String.split(expression, ~r/\s+/, trim: true) do
      [minute, hour, day, month, weekday] -> describe(minute, hour, day, month, weekday)
      _ -> "Custom schedule"
    end
  end

  def describe(_), do: "Custom schedule"

  @doc "Timezone label shown next to a schedule."
  @spec zone(String.t() | nil) :: String.t()
  def zone("local"), do: "server local time"
  def zone(_), do: "UTC"

  defp describe("*", "*", "*", "*", "*"), do: "Every minute"

  defp describe("*/" <> step, "*", "*", "*", "*") do
    case int(step) do
      1 -> "Every minute"
      n when is_integer(n) -> "Every #{n} minutes"
      _ -> "Custom schedule"
    end
  end

  defp describe(minute, hour, day, month, weekday) do
    with m when is_integer(m) <- int(minute),
         {kind, _} = when_text when kind in [:ok, :hourly] <- hours(hour, m) do
      describe_days(when_text, day, month, weekday)
    else
      _ -> list_of_minutes(minute, hour, day, month, weekday)
    end
  end

  defp list_of_minutes(minute, "*", "*", "*", "*") do
    case ints(minute) do
      [_ | _] = values when length(values) <= 6 ->
        "Every hour at " <> Enum.map_join(values, ", ", &":#{pad(&1)}")

      _ ->
        "Custom schedule"
    end
  end

  defp list_of_minutes(_, _, _, _, _), do: "Custom schedule"

  defp hours("*", 0), do: {:hourly, "Every hour"}
  defp hours("*", m), do: {:hourly, "Every hour at :#{pad(m)}"}

  defp hours("*/" <> step, m) do
    case int(step) do
      1 ->
        hours("*", m)

      n when is_integer(n) ->
        {:hourly, "Every #{n} hours" <> if(m == 0, do: "", else: " at :#{pad(m)}")}

      _ ->
        :error
    end
  end

  defp hours(hour, m) do
    case ints(hour) do
      [_ | _] = values when length(values) <= 4 ->
        {:ok, "at " <> Enum.map_join(values, ", ", &"#{pad(&1)}:#{pad(m)}")}

      _ ->
        :error
    end
  end

  defp describe_days({:hourly, text}, "*", "*", "*"), do: text

  defp describe_days({:hourly, text}, "*", "*", weekday) do
    case weekdays(weekday) do
      nil -> "Custom schedule"
      days -> "#{text}, #{days}"
    end
  end

  defp describe_days({:hourly, _}, _, _, _), do: "Custom schedule"
  defp describe_days({:ok, at}, "*", "*", "*"), do: "Daily #{at}"

  defp describe_days({:ok, at}, "*", "*", weekday) do
    case weekdays(weekday) do
      nil -> "Custom schedule"
      "weekdays" -> "Weekdays #{at}"
      "weekends" -> "Weekends #{at}"
      days -> "Every #{days} #{at}"
    end
  end

  defp describe_days({:ok, at}, day, "*", "*") do
    case int(day) do
      d when is_integer(d) -> "Monthly on the #{ordinal(d)} #{at}"
      _ -> "Custom schedule"
    end
  end

  defp describe_days({:ok, at}, day, month, "*") do
    with d when is_integer(d) <- int(day),
         mo when is_integer(mo) and mo in 1..12 <- int(month) do
      "Yearly on #{Enum.at(@months, mo - 1)} #{d} #{at}"
    else
      _ -> "Custom schedule"
    end
  end

  defp describe_days(_, _, _, _), do: "Custom schedule"

  defp weekdays("1-5"), do: "weekdays"
  defp weekdays("0,6"), do: "weekends"
  defp weekdays("6,0"), do: "weekends"
  defp weekdays("6,7"), do: "weekends"

  defp weekdays(value) do
    case ints(value) do
      [_ | _] = values ->
        if Enum.all?(values, &(&1 in 0..7)),
          do: Enum.map_join(values, ", ", &Enum.at(@days, rem(&1, 7))),
          else: nil

      _ ->
        nil
    end
  end

  defp ints(value) do
    parts = String.split(value, ",")
    values = Enum.map(parts, &int/1)
    if Enum.all?(values, &is_integer/1), do: values, else: []
  end

  defp int(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp ordinal(n) when rem(n, 100) in 11..13, do: "#{n}th"
  defp ordinal(n) when rem(n, 10) == 1, do: "#{n}st"
  defp ordinal(n) when rem(n, 10) == 2, do: "#{n}nd"
  defp ordinal(n) when rem(n, 10) == 3, do: "#{n}rd"
  defp ordinal(n), do: "#{n}th"
end
