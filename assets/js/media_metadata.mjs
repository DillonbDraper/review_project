// Project only bounded primitive metadata. Codec/container acceptance is Elixir policy.
export function inspectionTracks(result) {
  const tracks = result?.media?.track;
  if (!Array.isArray(tracks) || tracks.length > 16) throw Error('inspection_limit');
  const string = value => typeof value === 'string' ? value.slice(0, 256) : null;
  const number = value => value != null && Number.isFinite(Number(value)) ? Number(value) : null;
  return tracks.map(track => ({
    type: string(track['@type']), format: string(track.Format), profile: string(track.Format_Profile),
    features: string(track.Format_AdditionalFeatures), codec_id: string(track.CodecID),
    bit_depth: number(track.BitDepth), chroma: string(track.ChromaSubsampling),
    duration: number(track.Duration), width: number(track.Width), height: number(track.Height),
  }));
}
