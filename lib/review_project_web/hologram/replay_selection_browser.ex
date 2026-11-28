defmodule ReviewProjectWeb.Hologram.ReplaySelectionBrowser do
  @moduledoc "Native effects for replay selection. Grants never enter component state."
  use Hologram.JS
  js_import from: "../../../assets/js/replay_native.mjs", as: :ReplayUpload

  def perform({:choose, params}) do
    JS.call(:ReplayUpload, :choose, [params])
    []
  end

  def perform(:cancel) do
    JS.call(:ReplayUpload, :cancel, [])
    []
  end

  def perform({:local, source}) do
    JS.call(:ReplayUpload, :commitLocal, [source.handle])
    [{:local_replay, %{source: source}}]
  end

  def perform({:snapshot, snapshot}), do: [{:room_snapshot, %{snapshot: snapshot}}]
  def perform(:reconcile), do: [{:visible, %{visible: true}}]
end
