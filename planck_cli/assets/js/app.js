import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"
import hljs from "highlight.js"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const Hooks = {}

// Submit on Enter, newline on Shift+Enter.
// ↑/↓ on empty first line navigates message history.
// Auto-grow is handled by field-sizing: content (Chrome/Safari).
Hooks.PromptInput = {
  mounted() {
    this.el.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault()
        this.el.closest("form").requestSubmit()
      } else if (e.key === "ArrowUp" && this.isOnFirstLine()) {
        e.preventDefault()
        this.pushEvent("history_prev", {})
      } else if (e.key === "ArrowDown" && this.isOnLastLine()) {
        e.preventDefault()
        this.pushEvent("history_next", {})
      }
    })
  },
  isOnFirstLine() {
    return this.el.selectionStart === 0 ||
      !this.el.value.slice(0, this.el.selectionStart).includes("\n")
  },
  isOnLastLine() {
    return this.el.selectionEnd === this.el.value.length ||
      !this.el.value.slice(this.el.selectionEnd).includes("\n")
  }
}

// Scroll chat to bottom, highlight code, and format timestamps in local time
Hooks.Chat = {
  mounted()  { this.scrollBottom(); this.highlight(); this.formatTimes() },
  updated()  { this.scrollBottom(); this.highlight(); this.formatTimes() },
  scrollBottom() {
    this.el.scrollTop = this.el.scrollHeight
  },
  highlight() {
    this.el.querySelectorAll('pre code:not([data-highlighted])').forEach(el => {
      hljs.highlightElement(el)
    })
  },
  formatTimes() {
    const now = new Date()
    this.el.querySelectorAll('time[data-local-time]').forEach(el => {
      const dt = new Date(el.dataset.localTime)
      const isToday = dt.toDateString() === now.toDateString()
      el.textContent = isToday
        ? dt.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
        : dt.toLocaleDateString([], { month: 'short', day: 'numeric' }) + ' ' +
          dt.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
    })
  }
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
