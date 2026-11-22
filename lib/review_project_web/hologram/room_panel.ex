defmodule ReviewProjectWeb.Hologram.RoomPanel do
  @moduledoc "Room creation, shareable invitations and named guest admission."
  use Hologram.Component
  use Hologram.JS

  alias ReviewProject.Rooms
  alias ReviewProjectWeb.RoomErrors
  alias ReviewProjectWeb.Hologram.{ConferenceBrowser, RoomUI, UserAuth}

  middleware UserAuth, :mount_current_scope

  prop :room_id, :string, default: ""

  js_import from: "../../../assets/js/room_browser.mjs", as: :Browser

  @impl Component
  def init(props, component, server) do
    scope = get_stash(server, :current_scope)

    rooms =
      case scope && Rooms.list_rooms(scope) do
        {:ok, rooms} ->
          rooms
          |> Enum.reject(& &1.closed_at)
          |> Enum.take(6)
          |> Enum.map(&%{id: &1.id, name: &1.name || "Watch room"})

        _ ->
          []
      end

    component
    |> put_state(
      room_id: props.room_id,
      signed_in: not is_nil(scope),
      recovering: false,
      rooms: rooms,
      joined: false,
      busy: false,
      owner: false,
      room_name: "Your room",
      display_name: "",
      invitation_url: "",
      participants: [],
      seat_count: 0,
      connected_count: 0,
      status: "",
      error: "",
      copy_status: "",
      generation: 0,
      conference_generation: 0,
      operation_id: 0,
      operation_pending: false,
      origin: "",
      invitation: "",
      welcome: false,
      uncertain: false,
      authenticated: false,
      self_id: nil
    )
  end

  @impl Component
  def template do
    ~HOLO"""
    <section id="room-panel" data-room-id={@room_id} class="room-panel" aria-label="Room">
      {%if @room_id == ""}
        <div class="room-start-row">
          <div><p class="eyebrow">BETTER TOGETHER</p><p class="room-start-description">Make a room. Send a link. Bring everyone in.</p></div>
          <button id="open-create-room" type="button" class="primary-button" $click="open_create">Create a room <span aria-hidden="true">↗</span></button>
        </div>
        {%if @rooms != []}
          <nav id="owned-rooms" class="owned-rooms" aria-label="Your rooms">
            <span>Your rooms</span>
            {%for room <- @rooms}
              <a href="/rooms/{room.id}">{room.name}</a>
            {/for}
          </nav>
        {/if}
      {%else}
        <div class="room-start-row">
          <div>
            <p class="eyebrow">YOUR ROOM</p>
            <h2 id="room-name" class="room-name">{@room_name}</h2>
            <p id="room-status" role="status" class="field-hint">{@status}</p>
          </div>
          <div class="room-actions">
            {%if @joined}
              <button id="open-invitation" type="button" class="primary-button" $click="open_invitation">Invite people</button>
              <button id="leave-room" type="button" class="secondary-button" $click="leave" disabled={@busy}>{%if @busy}Leaving…{%else}Leave room{/if}</button>
            {%else}
              <button id="open-join-room" type="button" class="primary-button" $click="open_join" disabled={@busy}>Join room</button>
              <a href="/" class="secondary-button">Back home</a>
            {/if}
          </div>
        </div>
        {%if @joined}
          <div id="room-participants" class="room-participants" aria-label="Participants">
            <span class="room-capacity">{@connected_count} connected · {@seat_count}/5 seats</span>
            {%for participant <- @participants}
              <span class="participant-chip" data-connected={participant.connected}>
                <span class="status-dot" aria-hidden="true"></span>{participant.display_name}
                {%if participant.role == "owner"}<span class="participant-detail">Host</span>{/if}
                {%if !participant.connected}<span class="participant-detail">Away</span>{/if}
              </span>
            {/for}
          </div>
        {/if}
      {/if}
      <p id="room-error" class="field-error" role="alert">{@error}</p>

      <dialog id="create-room-dialog" class="room-dialog" aria-labelledby="create-room-heading">
        <div class="room-dialog-heading">
          <span class="eyebrow">A LITTLE SPACE, TOGETHER</span>
          <button id="close-create-room" type="button" class="dialog-close" $click="close_create" aria-label="Close create room">Close</button>
        </div>
        <h2 id="create-room-heading">Make room for your people.</h2>
        <p class="room-dialog-description">Give your room a name. You’ll get a link to share with up to four guests.</p>
        {%if @signed_in}
          <form id="create-room-form" $submit="create">
            <label for="room-title" class="field-label">Room name</label>
            <input id="room-title" name="name" type="text" class="workspace-input" placeholder="Friday watch party" maxlength="120" required autofocus />
            <label for="host-name" class="field-label">Your display name</label>
            <input id="host-name" name="display_name" type="text" class="workspace-input" placeholder="What should we call you?" maxlength="120" required autocomplete="nickname" />
            <p class="field-hint">Guests choose their own names. No account needed for them.</p>
            <p id="create-room-error" class="field-error" role="alert">{@error}</p>
            <button id="create-room-submit" type="submit" class="primary-button room-submit" disabled={@busy}>{%if @busy}Creating…{%else}Create room & get a link{/if}</button>
          </form>
        {%else}
          <div id="create-room-sign-in" class="room-sign-in">
            <p>Sign in to host a room. Your guests can join with just the invitation link.</p>
            <a id="sign-in-to-create" href="/room-sign-in" class="primary-button">Sign in to create a room</a>
          </div>
        {/if}
      </dialog>

      <dialog id="join-room-dialog" class="room-dialog" aria-labelledby="join-room-heading">
        <div class="room-dialog-heading"><span class="eyebrow">YOU’RE INVITED</span><button id="close-join-room" type="button" class="dialog-close" $click="close_join" aria-label="Close join room">Close</button></div>
        <h2 id="join-room-heading">Come on in.</h2>
        <p class="room-dialog-description">Choose a name so everyone knows it’s you. No account needed.</p>
        <form id="join-room-form" $submit="join">
          <label for="guest-name" class="field-label">Your display name</label>
          <input id="guest-name" name="display_name" type="text" value={@display_name} class="workspace-input" placeholder="What should we call you?" maxlength="120" required autocomplete="nickname" autofocus />
          <p class="field-hint">One seat per browser. Joining in another tab moves your seat there.</p>
          <p id="join-room-error" class="field-error" role="alert">{@error}</p>
          <button id="join-room-submit" type="submit" class="primary-button room-submit" disabled={@busy}>{%if @busy}Joining…{%else}Join room{/if}</button>
        </form>
        {%if @signed_in}<p class="field-hint">Hosting this room? Your signed-in account lets you rejoin.</p>{/if}
      </dialog>

      <dialog id="invitation-dialog" class="room-dialog" aria-labelledby="invitation-heading">
        <div class="room-dialog-heading"><span class="eyebrow">THE MORE, THE MERRIER</span><button id="close-invitation" type="button" class="dialog-close" $click="close_invitation" aria-label="Close invitation">Close</button></div>
        <h2 id="invitation-heading">Send a little invitation.</h2>
        <p class="room-dialog-description">Anyone with this link can join. Share it however you like — a message, an email, your group chat.</p>
        {%if @invitation_url != ""}
          <label for="invitation-link" class="field-label">Invitation link</label>
          <input id="invitation-link" class="workspace-input invitation-link" type="text" value={@invitation_url} readonly />
          <button id="copy-invitation" type="button" class="primary-button room-submit" $click="copy">Copy invitation link</button>
          <p id="invitation-copy-status" class="field-hint" role="status">{@copy_status}</p>
        {%else}
          <p class="field-hint">The original link is no longer saved in this tab.</p>
          {%if @owner}
            <p class="field-hint">A new invitation replaces the previous link. People already connected can stay; future joins need the new link.</p>
            <button id="replace-invitation" type="button" class="primary-button room-submit" $click="replace_invitation" disabled={@busy}>Create a new invitation link</button>
          {/if}
        {/if}
        <p class="field-hint">Five people total, including the host. Guests don’t need to register.</p>
        <p id="invitation-error" class="field-error" role="alert">{@error}</p>
      </dialog>
    </section>
    """
  end

  @impl Component
  def action(:room_mounted, _params, component) do
    saved = browser_entry(component.state.room_id)
    JS.call(:Browser, :ready, [])

    component
    |> put_state(
      recovering: false,
      joined: false,
      busy: false,
      participants: [],
      owner: false,
      generation: component.state.generation + 1,
      origin: saved["origin"] || "",
      invitation: saved["invitation"] || "",
      display_name: saved["display_name"] || "",
      welcome: saved["welcome"] || false,
      uncertain: saved["uncertain_delivery"] || false,
      authenticated: false,
      operation_pending: false,
      invitation_url:
        RoomUI.invitation_url(
          saved["origin"] || "",
          component.state.room_id,
          saved["invitation"] || ""
        )
    )
    |> put_action(name: :reset, target: "chat-panel", params: %{resume: true})
    |> stop_conference()
  end

  def action(:restore, _params, component) do
    cond do
      component.state.room_id == "" ->
        component

      component.state.display_name != "" ->
        begin_join(component, component.state.display_name)

      true ->
        dialog("join-room-dialog", true)
        put_state(component, status: "Choose a name to join this room.")
    end
  end

  def action(name, _params, component)
      when name in [:open_create, :open_join, :open_invitation] do
    id =
      case name do
        :open_create -> "create-room-dialog"
        :open_join -> "join-room-dialog"
        :open_invitation -> "invitation-dialog"
      end

    dialog(id, true)
    put_state(component, error: "", copy_status: "")
  end

  def action(name, _params, component)
      when name in [:close_create, :close_join, :close_invitation] do
    id =
      case name do
        :close_create -> "create-room-dialog"
        :close_join -> "join-room-dialog"
        :close_invitation -> "invitation-dialog"
      end

    dialog(id, false)
    component
  end

  def action(:create, %{event: %{"name" => raw, "display_name" => raw_name}}, component) do
    name = String.trim(raw)

    cond do
      component.state.busy ->
        component

      name == "" or length(String.to_charlist(name)) > 120 ->
        put_state(component, error: "Choose a room name of 1–120 characters.")

      true ->
        case RoomUI.display_name(raw_name) do
          {:ok, display_name} ->
            generation = component.state.generation + 1
            operation_id = component.state.operation_id + 1

            component
            |> put_state(
              busy: true,
              error: "",
              generation: generation,
              operation_id: operation_id,
              operation_pending: true
            )
            |> put_command(:create, %{
              name: name,
              display_name: display_name,
              generation: generation,
              operation_id: operation_id
            })
            |> put_action(
              name: :operation_timeout,
              params: %{generation: generation, operation_id: operation_id},
              delay: 15_000
            )

          {:error, error} ->
            put_state(component, error: error)
        end
    end
  end

  def action(:created, params, component) do
    if current_operation?(component, params) do
      JS.call(:Browser, :save, [
        params.room_id,
        %{display_name: params.display_name, invitation: params.invitation, welcome: true}
      ])

      JS.call(:Browser, :navigate, ["/rooms/" <> params.room_id])
      put_state(component, busy: false, operation_pending: false)
    else
      component
    end
  end

  def action(:operation_timeout, params, component) do
    if current_operation?(component, params) and component.state.operation_pending do
      put_state(component,
        busy: false,
        operation_pending: false,
        error: "Couldn’t confirm the request. Refresh before trying again."
      )
    else
      component
    end
  end

  def action(:operation_error, %{error: error} = params, component) do
    if current_operation?(component, params),
      do: put_state(component, busy: false, operation_pending: false, error: RoomUI.error(error)),
      else: component
  end

  def action(:join, %{event: %{"display_name" => name}}, component) do
    if component.state.busy, do: component, else: begin_join(component, name)
  end

  def action(:session_result, %{generation: generation} = params, component) do
    if generation != component.state.generation do
      component
    else
      case params do
        %{status: "ok", result: auth} ->
          cond do
            component.state.authenticated and not auth.signed_in ->
              ended(component, %{reason: "session_expired"})

            component.state.invitation == "" and not auth.signed_in ->
              refused(component, %{reason: "invalid_invitation"})

            true ->
              JS.call(:Browser, :connect, [
                %{
                  generation: generation,
                  path: "/room-socket",
                  topic: "room:" <> component.state.room_id,
                  csrf: auth.csrf_token,
                  params: %{
                    display_name: component.state.display_name,
                    invitation: component.state.invitation
                  },
                  events: [
                    "room_state",
                    "room_ended",
                    "room_restart",
                    "chat_message",
                    "conference_signal",
                    "conference_peer"
                  ]
                }
              ])

              put_state(component, authenticated: auth.signed_in)
          end

        %{status: "insecure"} ->
          put_state(component,
            busy: false,
            status: "Not connected",
            error: "Open the app over HTTPS or localhost to join a room."
          )

        _ ->
          component
          |> put_state(status: "Connection unavailable. Reconnecting…", busy: true)
          |> put_action(name: :retry, params: %{generation: generation}, delay: 1500)
      end
    end
  end

  def action(:retry, %{generation: generation}, component) do
    if generation == component.state.generation and component.state.busy do
      JS.call(:Browser, :session, [generation])
    end

    component
  end

  def action(:transport, %{generation: generation} = params, component) do
    if generation != component.state.generation do
      component
    else
      transport(params.type, params.result, component)
    end
  end

  def action(:poll, %{generation: generation}, component) do
    if generation == component.state.generation and component.state.joined do
      JS.call(:Browser, :push, [
        "snapshot",
        %{},
        "room-controls",
        "snapshot",
        %{generation: generation}
      ])
    end

    component
  end

  def action(:snapshot, %{generation: generation} = params, component) do
    cond do
      generation != component.state.generation ->
        component

      params.status == "ok" ->
        component
        |> accept(params.result)
        |> schedule_poll()
        |> conference(:roster, %{snapshot: params.result})

      params.status == "timeout" ->
        reconnect(component)

      true ->
        ended(component, params.result)
    end
  end

  def action(:leave, _params, component) do
    component = stop_conference(component)

    JS.call(:Browser, :push, [
      "leave",
      %{},
      "room-controls",
      "left",
      %{generation: component.state.generation}
    ])

    put_state(component, busy: true)
  end

  def action(:left, %{generation: generation} = params, component) do
    cond do
      generation != component.state.generation ->
        component

      params.status == "ok" ->
        leave_completed(component)

      true ->
        put_state(component, busy: false, error: "Couldn’t confirm leaving. Please try again.")
    end
  end

  def action(:copy, _params, component) do
    JS.call(:Browser, :copy, ["invitation-link", "room-controls", "copied"])
    component
  end

  def action(:copied, %{copied: copied}, component) do
    put_state(component,
      copy_status:
        if(copied,
          do: "Link copied. Share it wherever you like.",
          else: "Select and copy the link above to share it."
        )
    )
  end

  def action(:replace_invitation, _params, component) do
    if component.state.busy do
      component
    else
      operation_id = component.state.operation_id + 1

      component
      |> put_state(busy: true, error: "", operation_id: operation_id, operation_pending: true)
      |> put_command(:replace_invitation, %{
        room_id: component.state.room_id,
        generation: component.state.generation,
        operation_id: operation_id
      })
      |> put_action(
        name: :operation_timeout,
        params: %{generation: component.state.generation, operation_id: operation_id},
        delay: 15_000
      )
    end
  end

  def action(:invitation_replaced, %{invitation: token} = params, component) do
    if current_operation?(component, params) do
      JS.call(:Browser, :save, [component.state.room_id, %{invitation: token}])

      put_state(component,
        busy: false,
        invitation: token,
        operation_pending: false,
        invitation_url:
          RoomUI.invitation_url(component.state.origin, component.state.room_id, token),
        copy_status: "New invitation ready."
      )
    else
      component
    end
  end

  @impl Component
  def command(:create, params, server) do
    scope = get_stash(server, :current_scope)

    with true <- not is_nil(scope),
         {:ok, display_name} <- RoomUI.display_name(params.display_name),
         {:ok, %{room: room, invitation_token: token}} <-
           Rooms.create_room(scope, %{name: params.name}) do
      put_action(server, :created, %{
        room_id: room.id,
        invitation: token,
        display_name: display_name,
        generation: params.generation,
        operation_id: params.operation_id
      })
    else
      false ->
        command_error(server, params, :session_expired)

      {:error, reason} when is_binary(reason) ->
        command_error(server, params, :invalid_display_name)

      {:error, reason} ->
        command_error(server, params, reason)
    end
  end

  def command(:replace_invitation, params, server) do
    case Rooms.rotate_invitation(get_stash(server, :current_scope), params.room_id) do
      {:ok, token} ->
        put_action(server, :invitation_replaced, %{
          invitation: token,
          generation: params.generation,
          operation_id: params.operation_id
        })

      {:error, reason} ->
        command_error(server, params, reason)
    end
  end

  defp command_error(server, params, reason),
    do:
      put_action(server, :operation_error, %{
        generation: params.generation,
        operation_id: params.operation_id,
        error: RoomErrors.payload(reason)
      })

  defp current_operation?(component, params),
    do:
      params.generation == component.state.generation and
        params.operation_id == component.state.operation_id

  defp begin_join(component, raw) do
    case RoomUI.display_name(raw) do
      {:ok, name} ->
        generation = component.state.generation + 1
        JS.call(:Browser, :save, [component.state.room_id, %{display_name: name}])
        JS.call(:Browser, :session, [generation])

        put_state(component,
          display_name: name,
          busy: true,
          error: "",
          generation: generation,
          status: "Joining room…"
        )

      {:error, error} ->
        put_state(component, busy: false, error: error)
    end
  end

  defp transport("joined", reply, component) do
    dialog("join-room-dialog", false)
    resume = component.state.recovering

    if component.state.welcome do
      JS.call(:Browser, :save, [component.state.room_id, %{welcome: false}])
      dialog("invitation-dialog", true)
    end

    component
    |> put_state(
      self_id: reply.self_id,
      joined: true,
      recovering: false,
      welcome: false,
      uncertain: false
    )
    |> accept(reply.snapshot)
    |> put_action(
      name: :activate,
      target: "chat-panel",
      params: %{
        messages: reply.messages,
        self_id: reply.self_id,
        room_id: component.state.room_id,
        uncertain: component.state.uncertain,
        room_generation: component.state.generation
      }
    )
    |> start_conference(reply, resume)
  end

  defp transport("room_state", snapshot, component) do
    if component.state.joined,
      do: component |> accept(snapshot) |> conference(:roster, %{snapshot: snapshot}),
      else: component
  end

  defp transport("chat_message", message, component) do
    if component.state.joined,
      do:
        put_action(component, name: :received, target: "chat-panel", params: %{message: message}),
      else: component
  end

  defp transport("conference_signal", signal, component) do
    if component.state.joined,
      do: conference(component, :signal, %{signal: signal}),
      else: component
  end

  defp transport("conference_peer", peer, component) do
    if component.state.joined,
      do: conference(component, :peer_reset, %{peer: peer}),
      else: component
  end

  defp transport("room_ended", %{reason: "left"}, component), do: leave_completed(component)
  defp transport("room_ended", error, component), do: ended(component, error)
  defp transport("refused", error, component), do: refused(component, error)

  defp transport(type, _result, component) when type in ["lost", "room_restart"],
    do: reconnect(component)

  defp accept(component, snapshot) do
    own = Enum.find(snapshot.seats, &(&1.id == component.state.self_id))

    put_state(component,
      joined: true,
      busy: false,
      error: "",
      owner: own != nil and own.role == "owner",
      room_name: snapshot.room_name || "Watch room",
      participants: snapshot.seats,
      connected_count: snapshot.connected_count,
      seat_count: snapshot.seat_count,
      status: "You’re connected. Invite someone to join you."
    )
  end

  defp reconnect(component) do
    JS.call(:Browser, :disconnect, [])
    generation = component.state.generation + 1

    component
    |> put_state(
      recovering: true,
      joined: false,
      busy: true,
      generation: generation,
      status: "Connection lost. Reconnecting…"
    )
    |> put_action(
      name: :disconnected,
      target: "chat-panel",
      params: %{retry: true, generation: generation, status: "Reconnecting to room chat…"}
    )
    |> stop_conference("recover")
  end

  defp leave_completed(component) do
    component = ended(component, %{reason: "left"})
    JS.call(:Browser, :navigate, ["/"])
    component
  end

  defp ended(component, error) do
    JS.call(:Browser, :disconnect, [])
    dialog("invitation-dialog", false)
    dialog("join-room-dialog", false)

    component
    |> put_state(
      recovering: false,
      joined: false,
      busy: false,
      participants: [],
      generation: component.state.generation + 1,
      status: RoomUI.error(error),
      error: ""
    )
    |> put_action(name: :reset, target: "chat-panel", params: %{status: RoomUI.error(error)})
    |> stop_conference()
  end

  defp start_conference(component, reply, resume) do
    generation = ConferenceBrowser.invalidate(component.state.conference_generation)

    component
    |> put_state(:conference_generation, generation)
    |> conference(:joined, %{
      self_id: reply.self_id,
      connection_generation: reply.connection_generation,
      snapshot: reply.snapshot,
      supported: ConferenceBrowser.supported?(),
      resume: resume
    })
  end

  defp stop_conference(component, mode \\ "stop") do
    generation = ConferenceBrowser.invalidate(component.state.conference_generation)

    component
    |> put_state(:conference_generation, generation)
    |> conference(:stopped, %{mode: mode})
  end

  # A component has one next action. Preserve chat/poll continuations while the
  # conference applies the same room event and binds its rendered media nodes.
  defp conference(component, event, params) do
    next_action =
      case component.next_action do
        %{target: nil} = action -> %{action | target: "room-controls"}
        action -> action
      end

    continuation =
      if event in [:joined, :roster, :stopped] do
        playback_params =
          params
          |> Map.take([:snapshot, :self_id, :mode])
          |> Map.merge(%{
            kind: event,
            room_generation: component.state.generation,
            next_action: next_action
          })

        put_action(component,
          name: :room_event,
          target: "video-panel",
          params: playback_params
        ).next_action
      else
        next_action
      end

    params =
      Map.merge(params, %{
        generation: component.state.conference_generation,
        next_action: continuation
      })

    put_action(component, name: event, target: "conference-panel", params: params)
  end

  defp refused(component, error) do
    component = component |> ended(error) |> put_state(error: RoomUI.error(error))
    dialog("join-room-dialog", true)
    component
  end

  defp schedule_poll(component),
    do:
      put_action(component,
        name: :poll,
        params: %{generation: component.state.generation},
        delay: 15_000
      )

  defp browser_entry(id) do
    case JS.call(:Browser, :entry, [id]) do
      saved when is_map(saved) -> saved
      _ -> %{}
    end
  end

  defp dialog(id, open), do: JS.call(:Browser, :dialog, [id, open])
end
