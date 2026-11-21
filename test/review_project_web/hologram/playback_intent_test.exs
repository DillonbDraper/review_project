defmodule ReviewProjectWeb.Hologram.PlaybackIntentTest do
  use ExUnit.Case, async: true
  alias ReviewProjectWeb.Hologram.PlaybackIntent, as: Intent

  defp sample(at, state, position, playing \\ true),
    do: %{
      now: at,
      state: state,
      position: position,
      desired_playing: playing,
      controller: true,
      focused: true,
      hidden: false,
      ready: true,
      blocked: false
    }

  test "only expected command responses are ignored and settlement releases the next native action immediately" do
    initial = sample(1000, 2, 10, false)
    intent = Intent.commanded(Intent.new(), initial, %{position: nil, playing: true})
    {intent, nil} = Intent.observe(intent, sample(1100, 3, 10))
    assert intent.expected != nil
    {intent, nil} = Intent.observe(intent, sample(1200, 1, 10))
    assert intent.expected == nil
    {intent, nil} = Intent.observe(intent, sample(1250, 2, 10.05))
    {_, command} = Intent.observe(intent, sample(1450, 2, 10.05))
    refute command.playing
  end

  test "a divergent native seek is observed while an SDK seek remains unacknowledged" do
    intent = Intent.commanded(Intent.new(), sample(1000, 1, 10), %{position: 40, playing: nil})
    {intent, nil} = Intent.observe(intent, sample(1100, 1, 10.1))
    {intent, nil} = Intent.observe(intent, sample(1200, 1, 80))
    assert intent.expected == nil
    {_, command} = Intent.observe(intent, sample(1400, 1, 80.2))
    assert command == %{playing: true, position: 80.2}
  end

  test "long buffering retains seek position intent and original transport mode" do
    for playing <- [true, false] do
      {intent, nil} =
        Intent.observe(Intent.new(), sample(1000, if(playing, do: 1, else: 2), 10, playing))

      {intent, nil} = Intent.observe(intent, sample(1100, 2, 40, playing))

      intent =
        Enum.reduce(1200..7200//100, intent, fn at, intent ->
          {intent, nil} = Intent.observe(intent, sample(at, 3, 40, playing))
          assert intent.pending.kind == :seek
          intent
        end)

      {intent, nil} = Intent.observe(intent, sample(7300, 2, 40, playing))
      {_, command} = Intent.observe(intent, sample(7500, 2, 40, playing))
      assert command == %{playing: playing, position: 40}
    end
  end

  test "an unacknowledged SDK operation expires and does not permanently block playback" do
    intent = Intent.commanded(Intent.new(), sample(1000, 2, 10), %{position: nil, playing: true})
    {intent, nil} = Intent.observe(intent, sample(6100, 2, 10))
    assert intent.expected == nil
    {intent, nil} = Intent.observe(intent, sample(6200, 1, 10))
    {_, command} = Intent.observe(intent, sample(6400, 1, 10.2))
    assert command.playing
  end

  test "followers can acknowledge app commands but cannot infer shared native actions" do
    intent = Intent.commanded(Intent.new(), sample(1000, 2, 10), %{position: 40, playing: nil})
    {intent, nil} = Intent.observe(intent, %{sample(1100, 2, 40) | controller: false})
    assert intent.expected == nil
    {intent, nil} = Intent.observe(intent, %{sample(1200, 1, 80) | controller: false})
    {_, nil} = Intent.observe(intent, %{sample(1400, 1, 80.2) | controller: false})
  end
end
