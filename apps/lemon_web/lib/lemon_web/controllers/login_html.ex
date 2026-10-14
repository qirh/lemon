defmodule LemonWeb.LoginHTML do
  @moduledoc false

  use LemonWeb, :html

  embed_templates("login_html/*")

  def error_message(:invalid_token), do: "That token was not accepted. Check it and try again."

  def error_message({:throttled, seconds}),
    do: "Too many attempts. Try again in #{seconds} second#{if seconds == 1, do: "", else: "s"}."

  def error_message(_), do: nil
end
