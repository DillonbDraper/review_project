defmodule ReviewProjectWeb.Hologram.RoomPage do
  @moduledoc "Public invitation entry; the room transport authorizes admission."
  use Hologram.Page

  alias ReviewProjectWeb.Hologram.{UserAuth, WatchPage, WorkspaceLayout}

  route "/rooms/:room_id"
  param :room_id, :string
  layout WorkspaceLayout

  middleware UserAuth, :mount_current_scope

  @impl Page
  def init(params, component, _server), do: put_state(component, room_id: params.room_id)

  @impl Page
  def template, do: WatchPage.template()
end
