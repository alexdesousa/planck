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
      }
    })
  }
}

// Scroll chat to bottom, highlight code, and format timestamps in local time.
// Auto-scroll only fires if the user is already near the bottom — preserving
// scroll position when the user expands a tool call or scrolls up to read.
Hooks.Chat = {
  mounted()  { this.initialLoad = true; this.scrollBottom(true); this.highlight(); this.formatTimes() },
  updated()  { this.scrollBottom(this.initialLoad); this.initialLoad = false; this.highlight(); this.formatTimes() },
  scrollBottom(force) {
    const el = this.el
    const nearBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 80
    if (force || nearBottom) el.scrollTop = el.scrollHeight
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
  params: {_csrf_token: csrfToken, locale: document.documentElement.lang || navigator.language || "en"},
  hooks: Hooks
})

// Progress bar on navigations
topbar.config({barColors: {0: "#5F4FE6"}, shadowColor: "rgba(0,0,0,.3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// Dark mode: localStorage override, falling back to system preference
const applyTheme = () => {
  const stored = localStorage.getItem("theme")
  const dark = stored ? stored === "dark" : window.matchMedia("(prefers-color-scheme: dark)").matches
  document.documentElement.setAttribute("data-theme", dark ? "dark" : "light")
}
applyTheme()
window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
  if (!localStorage.getItem("theme")) applyTheme()
})
window.toggleTheme = () => {
  const next = document.documentElement.getAttribute("data-theme") === "dark" ? "light" : "dark"
  localStorage.setItem("theme", next)
  document.documentElement.setAttribute("data-theme", next)
}

liveSocket.connect()
window.liveSocket = liveSocket
