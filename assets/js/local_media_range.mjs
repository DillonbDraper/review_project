// Inclusive byte ranges. Invalid or multiple ranges receive 416.
export function rangeResponse(range, size) {
  if (!Number.isSafeInteger(size) || size < 1) throw Error('Invalid file size');
  if (range == null) return {status: 200, start: 0, end: size - 1, length: size};
  const match = /^bytes=(\d*)-(\d*)$/.exec(range);
  if (!match || (!match[1] && !match[2])) return {status: 416, length: 0};
  let start, end;
  if (!match[1]) {
    const suffix = Number(match[2]);
    if (!Number.isSafeInteger(suffix) || suffix < 1) return {status: 416, length: 0};
    start = Math.max(0, size - suffix); end = size - 1;
  } else {
    start = Number(match[1]); end = match[2] ? Number(match[2]) : size - 1;
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start >= size || end < start) return {status: 416, length: 0};
    end = Math.min(size - 1, end);
  }
  return {status: 206, start, end, length: end - start + 1};
}
