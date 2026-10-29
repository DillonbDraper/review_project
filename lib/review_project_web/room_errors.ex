defmodule ReviewProjectWeb.RoomErrors do
  @moduledoc false

  def payload(%Ecto.Changeset{} = changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
        Enum.reduce(opts, message, fn {key, value}, text ->
          String.replace(text, "%{#{key}}", to_string(value))
        end)
      end)

    %{reason: "validation", errors: errors}
  end

  def payload(reason) when is_atom(reason), do: %{reason: Atom.to_string(reason)}
  def payload(_reason), do: %{reason: "unavailable"}
end
