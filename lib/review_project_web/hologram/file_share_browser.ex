defmodule ReviewProjectWeb.Hologram.FileShareBrowser do
  @moduledoc "Executes Elixir file-sharing effects using scoped browser handles."
  use Hologram.JS
  alias ReviewProjectWeb.Hologram.FileShareState
  js_import from: "../../../assets/js/file_share_native.mjs", as: :Native
  js_import from: "../../../assets/js/room_browser.mjs", as: :Browser

  def start(state, params) do
    scope = %{
      room_id: params.snapshot.room_id,
      epoch: params.snapshot.epoch,
      self_id: params.self_id
    }

    case JS.call(:Native, :start, [scope, state.generation]) do
      result when is_map(result) ->
        retained =
          case result["retained"] do
            nil ->
              nil

            retained ->
              %{
                handle: retained["handle"],
                source_id: retained["source_id"],
                source_generation: retained["source_generation"]
              }
          end

        %{generation: result["generation"], retained: retained}

      _ ->
        %{generation: state.generation + 1, retained: nil}
    end
  end

  def stop(state, mode) do
    operation = if mode == "recover", do: :suspend, else: :release

    case JS.call(:Native, operation, [state.generation]) do
      generation when is_integer(generation) -> generation
      _ -> state.generation + 1
    end
  end

  def retain_ice(state, params) do
    if params.status == "ok" do
      ref = JS.call(:Native, :keepIce, [state.generation, params.result.servers])

      {:ice_ready,
       %{request: params.request, ref: ref, refresh_after: params.result.refresh_after}}
    else
      {:ice_failed, %{request: params.request}}
    end
  end

  def perform(state, effect) do
    if JS.call(:Native, :current, [state.generation]) == true,
      do: execute(state, effect),
      else: []
  end

  defp execute(state, {:configure_source, source, mode}) do
    JS.call(:Native, :configureSource, [state.generation, source, mode])
    []
  end

  defp execute(state, {:choose_file, request}) do
    JS.call(:Native, :choose, [state.generation, request])
    []
  end

  defp execute(state, {:inspect_file, request, handle}) do
    JS.call(:Native, :inspect, [state.generation, request, handle])
    []
  end

  defp execute(_state, {:release_file, handle}) do
    JS.call(:Native, :releaseFile, [handle])
    []
  end

  defp execute(state, {:adopt_file, handle, source}) do
    JS.call(:Native, :adoptFile, [state.generation, handle, source])
    []
  end

  defp execute(_state, {:check_decode, request, codec}) do
    supported = JS.call(:Native, :canDecode, [codec]) == true
    [{:decoded, %{request: request, supported: supported}}]
  end

  defp execute(state, {:offer, selection}) do
    payload =
      Map.merge(selection.guards, %{
        metadata: selection.metadata,
        page_id: JS.call(:Native, :pageId, [])
      })

    push(state, "file_offer", payload, %{kind: "offered", request: selection.request})
    []
  end

  defp execute(state, {:restore, id}) do
    payload =
      Map.merge(FileShareState.file_guards(state), %{
        available: true,
        page_id: JS.call(:Native, :pageId, [])
      })

    push(state, "file_available", payload, %{kind: "restored", source_id: id})
    []
  end

  defp execute(state, {:fetch_ice, request}) do
    push(state, "file_ice", FileShareState.file_guards(state), %{kind: "ice", request: request})
    []
  end

  defp execute(_state, {:release_ice, ref}) do
    if ref, do: JS.call(:Native, :releaseIce, [ref])
    []
  end

  defp execute(_state, {:close_peer, group}) do
    JS.call(:Native, :closePeer, [group])
    []
  end

  defp execute(state, {:bind_channel, id, handle}) do
    JS.call(:Native, :bindChannel, [state.generation, state.peers[id].group, handle])
    []
  end

  defp execute(state, {:peer_operation, id, token, operation, args}) do
    peer = state.peers[id]
    args = if operation in [:create, :configure], do: %{ice_ref: state.ice_ref}, else: args

    JS.call(:Native, :run, [
      state.generation,
      peer.group,
      Atom.to_string(operation),
      args,
      %{peer: id, token: token}
    ])

    []
  end

  defp execute(state, {:signal, id, data}) do
    peer = state.peers[id]
    payload = Map.put(FileShareState.envelope(state, peer), :data, data)
    push(state, "file_signal", payload, %{kind: "signaled", peer: id, group: peer.group})
    []
  end

  defp execute(state, {:reset_peer, id}) do
    peer = state.peers[id]

    push(state, "file_reset", FileShareState.envelope(state, peer), %{
      kind: "reset_result",
      peer: id,
      group: peer.group
    })

    []
  end

  defp execute(state, {:later, group, key, delay, metadata}) do
    JS.call(:Native, :later, [state.generation, group, key, delay, metadata])
    []
  end

  defp execute(_state, {:cancel_timer, group, key}) do
    JS.call(:Native, :cancelTimer, [group, key])
    []
  end

  defp execute(_state, {:player_ready, id}), do: [{:player_ready, %{source_id: id}}]

  defp push(state, event, payload, metadata),
    do:
      JS.call(:Browser, :push, [
        event,
        payload,
        "video-panel",
        "share_channel_result",
        Map.put(metadata, :generation, state.generation)
      ])
end
