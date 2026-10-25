defmodule ReviewProject.MediaSpikes.EchoSessions do
  @moduledoc """
  Phase 0 spike session manager for the Hologram <-> Membrane WebRTC integration.

  Hologram server commands run in a transient HTTP request process, so a pipeline
  started with `start_link` there would be torn down the moment the command
  responds. This tiny manager owns the pipeline lifecycle out of band: it starts
  each echo pipeline **unlinked** (`Membrane.Pipeline.start/2`) and tracks it by a
  per-page `base_id` so a later "stop" command (or a fresh "start" for the same
  id) can terminate it.

  Throwaway spike infrastructure — a real implementation would tie sessions to
  room/presence lifecycle and supervise them properly.
  """

  use GenServer

  alias ReviewProject.MediaSpikes.WebRTCEchoPipeline

  require Logger

  @table __MODULE__

  # --- Public API ---

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Starts (or restarts) an echo pipeline for `base_id`, wiring a capture signaling
  (`"<base_id>_capture"`) into `Membrane.WebRTC.Source` and a player signaling
  (`"<base_id>_player"`) into `Membrane.WebRTC.Sink`, both over `PhoenixSignaling`.
  """
  @spec start_session(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_session(base_id, opts \\ []) when is_binary(base_id) do
    GenServer.call(__MODULE__, {:start_session, base_id, opts})
  end

  @spec stop_session(String.t()) :: :ok
  def stop_session(base_id) when is_binary(base_id) do
    GenServer.call(__MODULE__, {:stop_session, base_id})
  end

  # --- GenServer ---

  @impl true
  def init(:ok) do
    table = :ets.new(@table, [:named_table, :set, :protected])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:start_session, base_id, opts}, _from, state) do
    terminate_existing(base_id)

    capture_signaling = Membrane.WebRTC.PhoenixSignaling.new("#{base_id}_capture")
    player_signaling = Membrane.WebRTC.PhoenixSignaling.new("#{base_id}_player")

    pipeline_opts =
      Keyword.merge(
        [
          capture_signaling: capture_signaling,
          player_signaling: player_signaling,
          echo_audio?: true
        ],
        opts
      )

    case Membrane.Pipeline.start(WebRTCEchoPipeline, pipeline_opts) do
      {:ok, _supervisor_pid, pipeline_pid} ->
        :ets.insert(@table, {base_id, pipeline_pid})

        Logger.info(
          "[EchoSessions] started echo pipeline for #{base_id}: #{inspect(pipeline_pid)}"
        )

        {:reply, {:ok, pipeline_pid}, state}

      {:error, reason} = error ->
        Logger.error("[EchoSessions] failed to start pipeline for #{base_id}: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:stop_session, base_id}, _from, state) do
    terminate_existing(base_id)
    {:reply, :ok, state}
  end

  defp terminate_existing(base_id) do
    case :ets.lookup(@table, base_id) do
      [{^base_id, pipeline_pid}] ->
        if Process.alive?(pipeline_pid) do
          Membrane.Pipeline.terminate(pipeline_pid, timeout: 1_000, force?: true)
        end

        :ets.delete(@table, base_id)

      [] ->
        :ok
    end
  end
end
