defmodule ReviewProject.Rooms.Validation do
  @moduledoc false
  import Ecto.Changeset

  def display_name(changeset, field \\ :display_name) do
    changeset
    |> update_change(field, &trim/1)
    |> validate_required([field])
    |> validate_length(field, max: 60, count: :codepoints)
    |> validate_format(field, ~r/\A[^\x00-\x1F\x7F]+\z/u,
      message: "must not contain control characters"
    )
  end

  def trim(value) when is_binary(value), do: String.trim(value)
  def trim(value), do: value
end
