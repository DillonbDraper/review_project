// Hologram calls this after sending a local message. Wait for its DOM update
// before moving the chat viewport; no pointer/drawing state goes to the server.
export function scrollChatToLatest() {
  requestAnimationFrame(() => {
    const messages = document.getElementById("chat-messages")
    if (messages) messages.scrollTop = messages.scrollHeight
  })
}
