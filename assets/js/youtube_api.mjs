// Official YouTube API loader shared by the production adapter and research facades.
let apiPromise;
const API_URL = "https://www.youtube.com/iframe_api";
export function playerError(code) {
  return (
    {
      2: "YouTube rejected the video ID or player parameters.",
      5: "This browser could not play the video. Try another video or reload.",
      100: "This video is unavailable, private, or has been removed.",
      101: "The video owner does not allow embedded playback. Choose another video.",
      150: "The video owner does not allow embedded playback. Choose another video.",
      153: "YouTube could not identify this application. Check its origin and referrer configuration.",
    }[code] ||
    `YouTube reported player error ${code}. Choose another video or retry.`
  );
}

export function loadAPI() {
  if (globalThis.YT?.Player) return Promise.resolve(globalThis.YT);
  if (apiPromise) return apiPromise;
  apiPromise = new Promise((resolve, reject) => {
    const script = document.createElement("script");
    const previous = globalThis.onYouTubeIframeAPIReady;
    const cleanup = () => {
      clearTimeout(timer);
      script.onerror = null;
      if (globalThis.onYouTubeIframeAPIReady === callback)
        globalThis.onYouTubeIframeAPIReady = previous;
    };
    const fail = () => {
      cleanup();
      script.remove();
      reject(
        new Error(
          "YouTube's player could not load. Check your connection or content blocker, then create the player again.",
        ),
      );
    };
    const callback = () => {
      cleanup();
      if (globalThis.YT?.Player) resolve(globalThis.YT);
      else
        reject(
          new Error(
            "YouTube's player API did not initialize. Try creating the player again.",
          ),
        );
      if (typeof previous === "function") previous();
    };
    const timer = setTimeout(fail, 20_000);
    globalThis.onYouTubeIframeAPIReady = callback;
    script.src = API_URL;
    script.async = true;
    script.onerror = fail;
    document.head.append(script);
  }).catch((error) => {
    apiPromise = undefined;
    throw error;
  });
  return apiPromise;
}
