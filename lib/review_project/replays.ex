defmodule ReviewProject.Replays do
  @moduledoc "Short-lived, connection-bound replay HTTP grants."

  def grant(room, epoch, seat, generation) do
    Phoenix.Token.sign(
      ReviewProjectWeb.Endpoint,
      "replay-http-v1",
      {room, epoch, seat, generation}
    )
  end

  def verify(token, room, epoch, seat, generation) do
    case Phoenix.Token.verify(ReviewProjectWeb.Endpoint, "replay-http-v1", token, max_age: 300) do
      {:ok, {^room, ^epoch, ^seat, ^generation}} -> :ok
      _ -> {:error, :not_joined}
    end
  end
end
