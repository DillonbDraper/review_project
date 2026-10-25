defmodule ReviewProject.MediaSpikes.WebRTCEchoPipeline do
  @moduledoc """
  Throwaway Phase 0 RTC-layer spike pipeline.

  It receives a browser camera/microphone through `Membrane.WebRTC.Source` and
  immediately forwards it to `Membrane.WebRTC.Sink`, which loops it back to a
  browser player. The point is to validate the raw `membrane_webrtc_plugin`
  deployment path with fixed ICE UDP port ranges, not to model the final
  watch-party SFU topology.

  ## Audio

  Video echoes with a direct `Source -> Sink` video link. Audio needs one extra
  element: the Source emits depayloaded Opus as
  `%Membrane.RemoteStream{content_format: Membrane.Opus}`, which the Sink's input
  pad does not accept directly — it wants raw `Membrane.Opus`.
  `Membrane.Opus.Parser` bridges the two (it accepts `RemoteStream{Opus}` and
  outputs `Opus`). Audio echo is enabled by default and can be turned off with
  `echo_audio?: false` (e.g. for the minimal video-only proof).
  """

  use Membrane.Pipeline

  @default_ice_servers [%{urls: "stun:stun.l.google.com:19302"}]
  @default_source_ice_port_range 50_000..50_020
  @default_sink_ice_port_range 50_021..50_040

  @type options :: [
          capture_signaling: Membrane.WebRTC.Signaling.t(),
          player_signaling: Membrane.WebRTC.Signaling.t(),
          notify: pid() | nil,
          echo_audio?: boolean(),
          ice_servers: [ExWebRTC.PeerConnection.Configuration.ice_server()],
          ice_port_range: Enumerable.t(non_neg_integer()),
          source_ice_port_range: Enumerable.t(non_neg_integer()),
          sink_ice_port_range: Enumerable.t(non_neg_integer())
        ]

  @impl true
  def handle_init(_ctx, opts) do
    capture_signaling = Keyword.fetch!(opts, :capture_signaling)
    player_signaling = Keyword.fetch!(opts, :player_signaling)
    notify = Keyword.get(opts, :notify)
    echo_audio? = Keyword.get(opts, :echo_audio?, true)
    ice_servers = Keyword.get(opts, :ice_servers, @default_ice_servers)

    source_ice_port_range =
      Keyword.get(
        opts,
        :source_ice_port_range,
        Keyword.get(opts, :ice_port_range, @default_source_ice_port_range)
      )

    sink_ice_port_range =
      Keyword.get(
        opts,
        :sink_ice_port_range,
        Keyword.get(opts, :ice_port_range, @default_sink_ice_port_range)
      )

    source = %Membrane.WebRTC.Source{
      signaling: capture_signaling,
      allowed_video_codecs: :vp8,
      preferred_video_codec: :vp8,
      keyframe_interval: Membrane.Time.seconds(2),
      ice_servers: ice_servers,
      ice_port_range: source_ice_port_range,
      ice_ip_filter: &__MODULE__.ipv4_candidate?/1
    }

    sink = %Membrane.WebRTC.Sink{
      signaling: player_signaling,
      tracks: sink_tracks(echo_audio?),
      video_codec: :vp8,
      ice_servers: ice_servers,
      ice_port_range: sink_ice_port_range,
      ice_ip_filter: &__MODULE__.ipv4_candidate?/1
    }

    video_branch =
      child(:source, source)
      |> via_out(Pad.ref(:output, :video), options: [kind: :video])
      |> via_in(Pad.ref(:input, :video), options: [kind: :video])
      |> child(:sink, sink)

    spec = [video_branch | audio_branch(echo_audio?)]

    state = %{
      notify: notify,
      echo_audio?: echo_audio?,
      ice_servers: ice_servers,
      source_ice_port_range: source_ice_port_range,
      sink_ice_port_range: sink_ice_port_range
    }

    {[spec: spec], state}
  end

  defp sink_tracks(true), do: [:audio, :video]
  defp sink_tracks(false), do: [:video]

  # Source emits %RemoteStream{content_format: Opus}; Opus.Parser converts it to
  # raw Membrane.Opus, which is what the Sink's audio input pad accepts.
  defp audio_branch(false), do: []

  defp audio_branch(true) do
    [
      get_child(:source)
      |> via_out(Pad.ref(:output, :audio), options: [kind: :audio])
      |> child(:opus_parser, Membrane.Opus.Parser)
      |> via_in(Pad.ref(:input, :audio), options: [kind: :audio])
      |> get_child(:sink)
    ]
  end

  @impl true
  def handle_child_notification(notification, child, _ctx, state) do
    notify(state, {:webrtc_echo_pipeline, child, notification})
    {[], state}
  end

  @impl true
  def handle_child_playing(child, _ctx, state) do
    notify(state, {:webrtc_echo_pipeline_child_playing, child})
    {[], state}
  end

  @impl true
  def handle_child_terminated(child, _ctx, state) do
    notify(state, {:webrtc_echo_pipeline_child_terminated, child})
    {[], state}
  end

  # Keep the local spike on ordinary IPv4 interfaces. In this dev environment
  # WebRTC sometimes selects IPv6 ULA or 100.64.0.0/10 VPN/CGNAT candidates,
  # which can connect on one peer while failing on the other. Production should
  # make this configurable per deployment host/network.
  def ipv4_candidate?({100, second_octet, _, _}) when second_octet in 64..127, do: false
  def ipv4_candidate?({_, _, _, _}), do: true
  def ipv4_candidate?(_ip), do: false

  defp notify(%{notify: nil}, _message), do: :ok
  defp notify(%{notify: pid}, message) when is_pid(pid), do: send(pid, message)
end
