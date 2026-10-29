defmodule ReviewProjectWeb.Hologram.RoomUI do
  @moduledoc "Shared presentation and client validation for the Hologram room workspace."

  def display_name(raw) when is_binary(raw) do
    name = String.trim(raw)
    chars = String.to_charlist(name)

    if name == "" or length(chars) > 60 or Enum.any?(chars, &(&1 < 32 or &1 == 127)) do
      {:error, "Choose a display name of 1–60 characters without control characters."}
    else
      {:ok, name}
    end
  end

  def display_name(_),
    do: {:error, "Choose a display name of 1–60 characters without control characters."}

  def invitation_url(_origin, _id, ""), do: ""

  def invitation_url(origin, id, token),
    do: origin <> "/rooms/" <> id <> "#invitation=" <> URI.encode_www_form(token)

  def error(%{reason: "validation", errors: errors}) do
    Enum.map_join(errors, " ", fn {field, messages} ->
      label = if to_string(field) == "display_name", do: "Display name", else: "Room name"
      label <> " " <> Enum.join(messages, ", ") <> "."
    end)
  end

  def error(%{reason: reason}) do
    case reason do
      "invalid_invitation" ->
        "This invitation is invalid or has been replaced. Ask the host for a new link."

      "invalid_display_name" ->
        "Choose a display name of 1–60 characters without control characters."

      "room_full" ->
        "This room is full. There’s space for the host and four guests. Try again when a seat opens."

      "room_closed" ->
        "The host has closed this room."

      "closed" ->
        "The host has closed this room."

      "not_found" ->
        "We couldn’t find this room. Check the invitation link."

      "not_joined" ->
        "The room restarted. Please join again."

      "authentication_required" ->
        "Sign in as the host, or use a full invitation link to join as a guest."

      "forbidden" ->
        "Only the room’s host can do that."

      "session_expired" ->
        "Your sign-in expired. Sign in again to rejoin."

      "joined_another_tab" ->
        "Your seat moved to another tab. Join here to move it back."

      "left" ->
        "You left the room."

      _ ->
        "Couldn’t connect to the room. Please try again."
    end
  end

  def error(_), do: "Couldn’t connect to the room. Please try again."

  def chat_error(%{reason: "validation", errors: %{body: messages}}),
    do: Enum.map_join(messages, " ", &("Message " <> &1 <> "."))

  def chat_error(%{reason: reason})
      when reason in ["not_joined", "authentication_required", "session_expired"],
      do: "Rejoin the room before sending messages."

  def chat_error(%{reason: "room_closed"}), do: "This room is closed."
  def chat_error(_), do: "Couldn’t complete the chat request. Please try again."
end
