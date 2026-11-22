// Called by Hologram after the native toggle, and on viewport changes. Native
// popovers handle toggling, Escape and outside clicks; no global listeners here.
function position() {
  const popover = document.querySelector("#video-enable-explanation:popover-open")
  const trigger = document.getElementById("video-enable-info")
  if (!popover || !trigger) return

  const anchor = trigger.getBoundingClientRect()
  const {width, height} = popover.getBoundingClientRect()
  const margin = 16
  const above = anchor.top - height - 8
  const top = above >= margin ? above : anchor.bottom + 8
  popover.style.left = `${Math.max(margin, Math.min(anchor.right - width, innerWidth - width - margin))}px`
  popover.style.top = `${Math.max(margin, Math.min(top, innerHeight - height - margin))}px`
}

export default {position}
