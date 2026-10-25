// Request devices independently: an unavailable camera must not discard a good microphone.
const constraints = {
  audio: {echoCancellation: true},
  video: {width: {ideal: 320}, height: {ideal: 180}, frameRate: {ideal: 15, max: 15}},
};

export function captureError(kind, error) {
  const device = kind === "audio" ? "Microphone" : "Camera";
  const name = error.name || "Error";
  const reasons = {
    NotFoundError: `no usable ${device.toLowerCase()} was found`,
    DevicesNotFoundError: `no usable ${device.toLowerCase()} was found`,
    NotAllowedError: "access was denied; check this site's and your system's device permissions",
    SecurityError: "access was blocked; check trusted HTTPS and device permissions",
    NotReadableError: "the device could not be opened; it may be busy or unavailable",
    AbortError: "the device could not be started; retry after checking it",
    OverconstrainedError: "the device could not meet the requested capture settings",
  };
  return `${device}: ${reasons[name] || error.message || name} (${name}).`;
}

export async function captureDevices(mode, request, cancelled = () => false) {
  const tracks = [], warnings = [];
  const stop = () => tracks.forEach(track => track.stop());
  try {
    for (const kind of mode === "microphone" ? ["audio"] : ["audio", "video"]) {
      if (cancelled()) { stop(); return null; }
      try {
        const stream = await request({audio: kind === "audio" ? constraints.audio : false,
          video: kind === "video" ? constraints.video : false});
        tracks.push(...stream.getTracks());
      } catch (error) { warnings.push(captureError(kind, error)); }
      if (cancelled()) { stop(); return null; }
    }
    if (!tracks.length) throw new Error(warnings.join(" "));
    return {tracks, warnings};
  } catch (error) { stop(); throw error; }
}
