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
// Auto-scroll fires when near the bottom (preserving manual scroll position)
// or whenever a new entry is appended (e.g. user sends a message).
Hooks.Chat = {
  mounted()  {
    this.entryCount = this.countEntries();
    this.scrollBottom(true);
    this.highlight();
    this.formatTimes();
    this.proxyImages()
  },
  updated()  {
    const count = this.countEntries()
    const newEntry = count > this.entryCount
    this.entryCount = count
    const nearBottom = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 80
    this.scrollBottom(newEntry || nearBottom)
    this.highlight()
    this.formatTimes()
    this.proxyImages()
  },
  countEntries() { return this.el.querySelectorAll('[data-entry]').length },
  scrollBottom(force) {
    const el = this.el
    if (force) el.scrollTop = el.scrollHeight
  },
  highlight() {
    this.el.querySelectorAll('pre code:not([data-highlighted])').forEach(el => {
      hljs.highlightElement(el)
    })
  },
  // Rewrite external image src through the server-side proxy so they load
  // regardless of CORS restrictions. Skips images already proxied.
  proxyImages() {
    this.el.querySelectorAll('img[src]:not([data-proxied])').forEach(img => {
      const src = img.getAttribute('src')
      if (!src || src.startsWith('data:') || src.startsWith('/') || src.startsWith('blob:') || src.startsWith('http://localhost')) return
      img.setAttribute('data-proxied', '1')
      img.src = '/api/proxy?url=' + encodeURIComponent(src)
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
