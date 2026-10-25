// Experimental tolerances, not a release SLA. All time math uses monotonic clocks.
export const SEEK_COOLDOWN_MS = 3000;
export const PLAYING_TOLERANCE = 1.0;
export const PAUSED_TOLERANCE = 0.35;

export function playbackStatus({connected, ready, error, enabled, blocked, pending_video, playing, role, state}) {
  if (!connected) return "Disconnected. Join a room or reconnect to get its playback state.";
  if (error) return "YouTube playback failed. See the player error below; check the selected video and browser content blocking.";
  if (!ready) return "Loading the YouTube player…";
  if (pending_video) return "Preparing the selected video…";
  if (blocked) return "Your browser blocked YouTube playback. Click Enable playback on this device again, or press Play inside the embedded player.";
  if (!enabled) return "Step 1: click Enable playback on this device. The host must also press Play for everyone to start the room.";
  if (!playing) return role === "host" ?
    "Playback is enabled on this device. The room is paused: click Play for everyone to start YouTube." :
    "Playback is enabled on this device. The room is paused; waiting for the host to press Play for everyone.";
  if (state === "buffering") return "Buffering locally. The room continues; this device will catch up.";
  return state === "playing" ? "Following the room timeline." :
    "Starting YouTube playback… If it stays blank, click Enable playback again or use Play inside the embedded player.";
}

export function targetPosition(snapshot, now, offset) {
  return Math.max(0, snapshot.position + (snapshot.playing ? Math.max(0, now + offset - snapshot.server_time_ms) / 1000 : 0));
}

export function newerSnapshot(current, incoming) {
  return !current || incoming.revision > current.revision ||
    (incoming.revision === current.revision && incoming.server_time_ms >= current.server_time_ms);
}

export function correction({target, position, playing, state, now, lastSeek, force = false}) {
  // Seeking repeatedly into a buffering player prevents it from ever recovering.
  if (playing && state === 3 && !force) return {seek: null, transport: null};
  const tolerance = playing ? PLAYING_TOLERANCE : PAUSED_TOLERANCE;
  return {
    seek: Math.abs(target - position) > tolerance && (force || now - lastSeek >= SEEK_COOLDOWN_MS) ? target : null,
    transport: playing ? (state === 1 ? null : "play") : ([-1, 2, 5].includes(state) ? null : "pause"),
  };
}
