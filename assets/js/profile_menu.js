// Phoenix headers only. The Hologram AccountMenu owns its own interactions and
// deliberately does not render data-profile-menu.
const menus = () => document.querySelectorAll("details[data-profile-menu][open]")

document.addEventListener("click", event => {
  for (const menu of menus()) {
    if (!menu.contains(event.target) || event.target.closest("a, button[type=submit]")) {
      menu.open = false
    }
  }
})

document.addEventListener("keydown", event => {
  if (event.key !== "Escape") return
  for (const menu of menus()) {
    menu.open = false
    menu.querySelector("summary").focus()
    event.preventDefault()
  }
})

document.addEventListener("focusout", () => {
  requestAnimationFrame(() => {
    for (const menu of menus()) {
      if (!menu.contains(document.activeElement)) menu.open = false
    }
  })
})

window.addEventListener("pagehide", () => {
  for (const menu of menus()) menu.open = false
})
window.addEventListener("phx:page-loading-start", () => {
  for (const menu of menus()) menu.open = false
})
