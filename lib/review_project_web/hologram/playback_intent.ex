defmodule ReviewProjectWeb.Hologram.PlaybackIntent do
  @moduledoc "Conservative native-input inference from normalized player observations."

  def new, do: %{previous: nil, pending: nil, suppressed_until: 0}

  def commanded(intent, now),
    do: %{intent | previous: nil, pending: nil, suppressed_until: now + 1200}

  def observe(intent, sample) do
    previous = intent.previous
    intent = %{intent | previous: sample}

    cond do
      not sample.controller or not sample.focused or sample.hidden or not sample.ready or
        sample.blocked or sample.now < intent.suppressed_until or
          (previous != nil and sample.now - previous.now > 500) ->
        {%{intent | pending: nil}, nil}

      sample.state == 3 ->
        {buffering(intent, previous, sample), nil}

      intent.pending != nil and intent.pending.buffering and sample.state in [1, 2, 5] and
          (intent.pending.kind == :seek or intent.pending.state == sample.state) ->
        pending = %{intent.pending | since: sample.now, state: sample.state, buffering: false}
        {%{intent | pending: pending}, nil}

      previous != nil and previous.state == 0 and sample.state == 1 and sample.position < 1 ->
        {%{intent | pending: candidate(sample, :seek)}, nil}

      previous == nil or previous.state not in [1, 2, 5] or sample.state not in [1, 2, 5] ->
        {%{intent | pending: nil}, nil}

      true ->
        settle(intent, previous, sample)
    end
  end

  defp buffering(intent, previous, sample) do
    cond do
      intent.pending != nil and intent.pending.kind == :seek and
          sample.now - intent.pending.since <= 5000 ->
        %{intent | pending: %{intent.pending | buffering: true}}

      previous != nil and previous.state in [1, 2, 5] ->
        jumped = abs(sample.position - project(previous, sample.now)) > 0.4

        if jumped or (previous.state in [2, 5] and not sample.desired_playing) do
          state = if sample.desired_playing or not jumped, do: 1, else: 2

          pending = %{
            candidate(sample, if(jumped, do: :seek, else: :transport))
            | state: state,
              buffering: true
          }

          %{intent | pending: pending}
        else
          %{intent | pending: nil}
        end

      intent.pending == nil or not intent.pending.buffering or
          sample.now - intent.pending.since > 5000 ->
        %{intent | pending: nil}

      true ->
        intent
    end
  end

  defp settle(intent, previous, sample) do
    jumped = abs(sample.position - project(previous, sample.now)) > 0.4
    changed = sample.state != previous.state and sample.state in [1, 2]

    cond do
      jumped or changed ->
        {%{intent | pending: candidate(sample, if(jumped, do: :seek, else: :transport))}, nil}

      intent.pending == nil ->
        {intent, nil}

      intent.pending.state != sample.state ->
        {%{intent | pending: nil}, nil}

      sample.now - intent.pending.since < 200 ->
        {intent, nil}

      true ->
        {%{intent | pending: nil}, %{position: sample.position, playing: sample.state == 1}}
    end
  end

  defp candidate(sample, kind),
    do: %{since: sample.now, state: sample.state, kind: kind, buffering: false}

  defp project(sample, now),
    do: sample.position + if(sample.state == 1, do: (now - sample.now) / 1000, else: 0)
end
