// Prototype only: inference from supported API telemetry, never iframe internals.
// Focus is evidence, not proof of a gesture. Ambiguous transitions stay local.
export class NativeIntent {
  constructor() { this.reset(); }
  reset() { this.previous = null; this.pending = null; this.suppressedUntil = 0; }
  commanded(now) {
    this.pending = null;
    this.previous = null;
    this.suppressedUntil = now + 1200;
  }
  observe(sample) {
    const prior = this.previous;
    this.previous = sample;
    if (!sample.controller || !sample.focused || sample.hidden || !sample.ready || sample.blocked ||
        sample.now < this.suppressedUntil || (prior && sample.now - prior.now > 500)) {
      this.pending = null;
      return null;
    }
    if (sample.state === 3) {
      // YouTube can report a seek as PAUSED -> BUFFERING -> PLAYING. Keep an
      // already observed position jump; the intermediate pause is not intent.
      if (this.pending?.kind === "seek" && sample.now - this.pending.since <= 5000) {
        this.pending = {...this.pending, buffering: true};
        return null;
      }
      if (prior && [1, 2, 5].includes(prior.state)) {
        const expected = prior.position + (prior.state === 1 ? (sample.now - prior.now) / 1000 : 0);
        const jumped = Math.abs(sample.position - expected) > 0.4;
        if (jumped || ([2, 5].includes(prior.state) && sample.desiredPlaying === false)) {
          this.pending = {since: sample.now, state: sample.desiredPlaying ? 1 : jumped ? 2 : 1,
            kind: jumped ? "seek" : "transport", buffering: true};
        } else this.pending = null;
      } else if (!this.pending?.buffering || sample.now - this.pending.since > 5000) this.pending = null;
      return null;
    }
    if (this.pending?.buffering && [1, 2, 5].includes(sample.state) &&
        (this.pending.kind === "seek" || this.pending.state === sample.state)) {
      this.pending = {...this.pending, since: sample.now, state: sample.state, buffering: false};
      return null;
    }
    if (!prior || ![1, 2, 5].includes(prior.state) || ![1, 2, 5].includes(sample.state)) {
      this.pending = null;
      return null;
    }
    const projected = prior.position + (prior.state === 1 ? (sample.now - prior.now) / 1000 : 0);
    const jumped = Math.abs(sample.position - projected) > 0.4;
    const changed = sample.state !== prior.state && [1, 2].includes(sample.state);
    if (jumped || changed) {
      this.pending = {since: sample.now, state: sample.state, kind: jumped ? "seek" : "transport"};
      return null;
    }
    if (!this.pending) return null;
    if (this.pending.state !== sample.state) { this.pending = null; return null; }
    if (sample.now - this.pending.since < 200) return null;
    this.pending = null;
    return {position: sample.position, playing: sample.state === 1};
  }
}
