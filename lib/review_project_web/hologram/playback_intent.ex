defmodule ReviewProjectWeb.Hologram.PlaybackIntent do
  @moduledoc "Native-input inference and acknowledgement of specific player commands."

  def new, do: %{previous: nil, pending: nil, expected: nil}

  def reset, do: new()

  # Only actual SDK calls create expectations. Accepting native input does not.
  def commanded(intent, sample, expected) do
    %{
      intent
      | previous: sample,
        pending: nil,
        expected: Map.merge(expected, %{origin: sample, issued_at: sample.now})
    }
  end

  def observe(intent, sample) do
    {intent, echo?} = acknowledge(intent, sample)
    previous = intent.previous
    intent = %{intent | previous: sample}

    cond do
      echo? ->
        {intent, nil}

      not sample.controller or not sample.focused or sample.hidden or not sample.ready or
        sample.blocked or (previous != nil and sample.now - previous.now > 500) ->
        {%{intent | pending: nil}, nil}

      sample.state == 3 ->
        {buffering(intent, previous, sample), nil}

      intent.pending != nil and intent.pending.buffering and sample.state in [1, 2, 5] and
          (intent.pending.kind == :seek or intent.pending.state == sample.state) ->
        pending = %{intent.pending | since: sample.now, state: sample.state, buffering: false}
        {%{intent | pending: pending}, nil}

      previous != nil and previous.state == 0 and sample.state == 1 and sample.position < 1 ->
        {%{intent | pending: candidate(sample, :seek, true)}, nil}

      previous == nil or previous.state not in [1, 2, 5] or sample.state not in [1, 2, 5] ->
        {%{intent | pending: nil}, nil}

      true ->
        settle(intent, previous, sample)
    end
  end

  defp acknowledge(%{expected: nil} = intent, _sample), do: {intent, false}

  defp acknowledge(intent, sample) do
    expected = intent.expected
    elapsed = max(0, sample.now - expected.issued_at) / 1000

    at_origin =
      near?(sample.position, expected.origin.position, elapsed, expected.origin.state == 1)

    at_target =
      expected.position != nil and
        near?(sample.position, expected.position, elapsed, expected.playing != false)

    cond do
      sample.now - expected.issued_at > 5000 ->
        {%{intent | expected: nil, pending: nil, previous: sample}, true}

      not at_origin and not at_target ->
        # A different position is new input, even before the SDK acknowledges us.
        {%{intent | expected: nil}, false}

      (expected.position == nil or at_target) and sample.state in [0, 1, 2, 5] and
          (expected.playing == nil or expected.playing == (sample.state == 1)) ->
        {%{intent | expected: nil, pending: nil}, true}

      true ->
        {intent, true}
    end
  end

  defp near?(position, anchor, elapsed, playing),
    do:
      position >= anchor - 0.75 and position <= anchor + if(playing, do: elapsed, else: 0) + 0.75

  defp buffering(intent, previous, sample) do
    jumped = previous != nil and abs(sample.position - project(previous, sample.now)) > 0.4

    cond do
      intent.pending != nil and intent.pending.kind == :seek ->
        pending = %{intent.pending | buffering: true}
        pending = if jumped, do: %{pending | since: sample.now}, else: pending
        %{intent | pending: pending}

      jumped ->
        %{
          intent
          | pending: %{candidate(sample, :seek, seek_playing(intent, sample)) | buffering: true}
        }

      previous != nil and previous.state in [2, 5] and not sample.desired_playing ->
        %{intent | pending: %{candidate(sample, :transport, true) | state: 1, buffering: true}}

      intent.pending != nil and intent.pending.kind == :transport and intent.pending.playing ->
        %{intent | pending: %{intent.pending | buffering: true}}

      true ->
        %{intent | pending: nil}
    end
  end

  defp settle(intent, previous, sample) do
    jumped = abs(sample.position - project(previous, sample.now)) > 0.4
    changed = sample.state != previous.state and sample.state in [1, 2]

    cond do
      jumped ->
        {%{intent | pending: candidate(sample, :seek, seek_playing(intent, sample))}, nil}

      changed and intent.pending != nil and intent.pending.kind == :seek ->
        # A seek's temporary pause/resume is not a separate transport decision.
        {%{intent | pending: %{intent.pending | state: sample.state, since: sample.now}}, nil}

      changed ->
        {%{intent | pending: candidate(sample, :transport, sample.state == 1)}, nil}

      intent.pending == nil ->
        {intent, nil}

      intent.pending.state != sample.state ->
        {%{intent | pending: nil}, nil}

      sample.now - intent.pending.since < 200 ->
        {intent, nil}

      true ->
        {%{intent | pending: nil}, %{position: sample.position, playing: intent.pending.playing}}
    end
  end

  defp seek_playing(intent, sample),
    do: if(intent.pending, do: intent.pending.playing, else: sample.desired_playing)

  defp candidate(sample, kind, playing),
    do: %{since: sample.now, state: sample.state, kind: kind, playing: playing, buffering: false}

  defp project(sample, now),
    do: sample.position + if(sample.state == 1, do: (now - sample.now) / 1000, else: 0)
end
