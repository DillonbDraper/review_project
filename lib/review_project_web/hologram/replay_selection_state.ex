defmodule ReviewProjectWeb.Hologram.ReplaySelectionState do
  @moduledoc "Replay selection policy. Effects carry metadata; browser resources stay native."
  alias ReviewProjectWeb.Hologram.PlaybackState

  def new, do: %{open: false, busy: false, request: 0, generation: 0, base: nil, message: ""}

  def view(state),
    do: %{replay_open: state.open, replay_busy: state.busy, replay_message: state.message}

  def event(state, :open, %{playback: playback}) do
    if PlaybackState.controller?(playback),
      do: {%{state | open: true, message: ""}, []},
      else: {state, []}
  end

  def event(state, :choose, %{playback: playback}) do
    if state.open and not state.busy and PlaybackState.controller?(playback) do
      request = state.request + 1
      solo = PlaybackState.solo?(playback)
      seat = if not solo, do: Enum.find(playback.desired.seats, &(&1.id == playback.self_id))

      params =
        Map.merge(Map.take(playback.desired || %{}, [:epoch, :revision, :authority_revision]), %{
          room_id: playback.room_id,
          solo: solo,
          request: request,
          generation: playback.generation,
          connection_generation: if(seat, do: seat.connection_generation, else: 0)
        })

      {%{
         state
         | busy: true,
           request: request,
           generation: playback.generation,
           base: base(playback),
           message: "Choose a .slp file…"
       }, [{:choose, params}]}
    else
      {state, []}
    end
  end

  def event(state, :result, %{playback: playback, result: params}) do
    if state.open and state.request == params.request and state.generation == params.generation and
         playback.generation == params.generation do
      state = %{
        state
        | busy: params.status in ["preparing", "uploading"],
          message: params.message
      }

      cond do
        params.status == "accepted" and PlaybackState.solo?(playback) and
            state.base != base(playback) ->
          {%{
             state
             | busy: false,
               message: "The source changed during preparation. Choose the replay again."
           }, [:cancel]}

        params.status == "accepted" ->
          effect =
            if PlaybackState.solo?(playback),
              do: {:local, params.result},
              else: {:snapshot, params.result}

          {%{state | open: false, busy: false, request: state.request + 1}, [effect, :cancel]}

        true ->
          {state, []}
      end
    else
      {state, []}
    end
  end

  def event(state, :close, %{playback: playback}) do
    effects =
      if state.busy and not PlaybackState.solo?(playback),
        do: [:cancel, :reconcile],
        else: [:cancel]

    {%{state | open: false, busy: false, request: state.request + 1}, effects}
  end

  def event(state, _, _), do: {state, []}

  defp base(playback), do: Map.take(playback.desired || %{}, [:video_id, :revision])
end
