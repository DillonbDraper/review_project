// Use Phoenix's signed cookie session, rather than a separate Hologram identity.
export function bootstrapAccess(signal) {
  const request = async () => {
    const response = await fetch("/dev/spikes/room-access/session", {
      signal, credentials: "same-origin", cache: "no-store",
    });
    if (!response.ok) throw new Error("Could not check your sign-in. Refresh this page to try again.");
    return response.json();
  };
  // Serialize first-cookie creation across tabs of a fresh guest browser.
  return navigator.locks ? navigator.locks.request("room-access-session", {signal}, request) : request();
}

// Called on mount and by Hologram's window-focus binding. The framework owns
// the listener lifecycle as it reconciles pages and restores history snapshots.
let authRequest;
export function watchAccessAuth() {
  authRequest?.abort();
  const controller = new AbortController();
  authRequest = controller;
  const original = new URL(performance.getEntriesByType("navigation")[0]?.name || location.href);
  const mode = original.searchParams.get("ice");
  const returnTo = location.pathname + (mode ? "?" + new URLSearchParams({ice: mode}) : "");
  const loginURL = "/dev/spikes/room-access/sign-in?" + new URLSearchParams({return_to: returnTo});
  const emit = (signedIn, status) => {
    if (!controller.signal.aborted && document.getElementById("access-auth-status")) {
      globalThis.Hologram?.dispatchAction("access_auth", "page", {
        signed_in: signedIn, status, login_url: loginURL,
      });
    }
  };
  queueMicrotask(async () => {
    try {
      const auth = await bootstrapAccess(controller.signal);
      emit(auth.signed_in, auth.signed_in ?
        "Signed in as " + auth.email + ". You can create a room or rejoin one you own." :
        "Not signed in. Sign in to create a room; guests can join an invitation without an account.");
    } catch (error) {
      if (error.name !== "AbortError") emit(false, error.message);
    }
  });
}
