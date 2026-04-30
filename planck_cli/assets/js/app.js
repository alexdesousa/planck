import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const Hooks = {}

// Submit on Enter, newline on Shift+Enter.
// Auto-grow is handled by field-sizing: content (Chrome/Safari).
// Firefox falls back to a fixed-height input until browser support lands.
Hooks.PromptInput = {
  mounted() {
    this.el.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault()
        this.el.closest("form").requestSubmit()
      }
    })
  }
}

// Keep chat scrolled to bottom on new messages
Hooks.ScrollBottom = {
  updated() { this.el.scrollTop = this.el.scrollHeight }
}

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

// Progress bar on navigations
topbar.config({barColors: {0: "#5F4FE6"}, shadowColor: "rgba(0,0,0,.3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// Dark mode: sync data-theme attribute with system preference
const applyTheme = () => {
  const dark = window.matchMedia("(prefers-color-scheme: dark)").matches
  document.documentElement.setAttribute("data-theme", dark ? "dark" : "light")
}
applyTheme()
window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", applyTheme)

liveSocket.connect()
window.liveSocket = liveSocket
