defmodule ReviewProjectWeb.YouTubeSyncSocket do
  @moduledoc "Development/test-only transport for the synchronization experiment."
  use Phoenix.Socket

  channel "youtube_sync:*", ReviewProjectWeb.YouTubeSyncChannel

  @impl true
  def connect(_params, socket, _connect_info) do
    if Application.get_env(:review_project, :youtube_sync_spike, false),
      do: {:ok, assign(socket, :rooms, ReviewProject.SyncSpikes.Rooms)},
      else: :error
  end

  @impl true
  def id(_socket), do: nil
end
