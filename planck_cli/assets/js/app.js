import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {createLiveToastHook} from "live_toast"
import topbar from "../vendor/topbar"
import hljs from "highlight.js"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const Hooks = {}
Hooks.LiveToast = createLiveToastHook()

// Submit on Enter, newline on Shift+Enter.
// Auto-grow is handled by field-sizing: content (Chrome/Safari).
// When the command dropdown is open, ↑/↓ navigate, Enter selects,
// Escape closes — see CommandDropdown hook for the dropdown state.
Hooks.PromptInput = {
  mounted() {
    this.dropdownOpen = false
    this.selectedIndex = 0
    this.matches = []
    this.el.__promptHook = this

    this.handleEvent("select-textarea", ({text}) => {
      this.el.value = text
      this.el.focus()
      this.el.setSelectionRange(text.length, text.length)
    })

    this.el.addEventListener("keydown", (e) => {
      if (this.dropdownOpen) {
        if (e.key === "ArrowDown") {
          e.preventDefault()
          this.moveSelection(1)
        } else if (e.key === "ArrowUp") {
          e.preventDefault()
          this.moveSelection(-1)
        } else if (e.key === "Enter" && !e.shiftKey) {
          e.preventDefault()
          this.selectCurrent()
          return
        } else if (e.key === "Escape") {
          e.preventDefault()
          this.pushEventTo(this.el, "close_dropdown", {})
          this.dropdownOpen = false
          this.updateHighlight()
          return
        }
      } else if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault()
        this.el.closest("form").requestSubmit()
      }
    })
  },

  moveSelection(delta) {
    const n = this.matches.length
    if (n === 0) return
    this.selectedIndex = (this.selectedIndex + delta + n) % n
    this.pushEventTo(this.el, "navigate", { index: this.selectedIndex })
    this.updateHighlight()
    this.scrollIntoView()
  },

  selectCurrent() {
    if (this.matches.length === 0) return
    const cmd = this.matches[this.selectedIndex]
    if (!cmd) return
    this.pushEventTo(this.el, "select_command", { name: cmd })
    this.dropdownOpen = false
    this.matches = []
    this.updateHighlight()
  },

  updateHighlight() {
    const dropdown = this.el.closest(".border-t-2")?.querySelector(".command-dropdown")
    if (!dropdown) return
    dropdown.querySelectorAll("button[data-command-index]").forEach((btn) => {
      const idx = parseInt(btn.dataset.commandIndex, 10)
      if (idx === this.selectedIndex) {
        btn.classList.add("bg-muted")
        btn.classList.remove("hover:bg-muted/50")
      } else {
        btn.classList.remove("bg-muted")
        btn.classList.add("hover:bg-muted/50")
      }
    })
  },

  scrollIntoView() {
    const dropdown = this.el.closest(".border-t-2")?.querySelector(".command-dropdown")
    if (!dropdown) return
    const btn = dropdown.querySelector(`button[data-command-index="${this.selectedIndex}"]`)
    if (btn) btn.scrollIntoView({ block: "nearest" })
  }
}

// Tracks the command dropdown state from the server and keeps the
// PromptInput hook's local state in sync. Listens for dropdown open/close
// events by observing the DOM for the dropdown panel element.
Hooks.CommandDropdown = {
  mounted() {
    const container = this.el.closest(".border-t-2")
    const textarea = container?.querySelector("textarea")
    if (!textarea) return

    const syncState = () => {
      const promptHook = textarea.__promptHook
      const dropdown = container.querySelector(".command-dropdown")

      if (dropdown) {
        const buttons = dropdown.querySelectorAll("button[data-command-name]")
        const matches = Array.from(buttons).map((b) => b.dataset.commandName)
        const selectedBtn = dropdown.querySelector("button.bg-muted[data-command-name]")
        const selectedIndex = selectedBtn
          ? parseInt(selectedBtn.dataset.commandIndex, 10)
          : 0

        if (promptHook) {
          promptHook.dropdownOpen = true
          promptHook.matches = matches
          promptHook.selectedIndex = selectedIndex
        }
      } else {
        if (promptHook) {
          promptHook.dropdownOpen = false
          promptHook.matches = []
        }
      }
    }

    this.syncState = syncState
    this.observer = new MutationObserver(syncState)
    this.observer.observe(container, { childList: true, subtree: true })
    syncState()
  },

  updated() {
    this.syncState()
  },

  destroyed() {
    this.observer?.disconnect()
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

// Repositions the dropdown panel as position:fixed so it escapes any
// overflow:auto ancestor (e.g. the modal content scroll container).
// Attach with phx-hook="FloatingDropdown" on the dropdown root element.
Hooks.FloatingDropdown = {
  mounted() {
    const panel = document.getElementById(`${this.el.id}-panel`)
    const trigger = this.el.querySelector('button[type="button"]')
    if (!panel || !trigger) return

    const reposition = () => {
      if (panel.style.display === 'none') return
      const rect = trigger.getBoundingClientRect()
      panel.style.top    = `${rect.bottom}px`
      panel.style.left   = `${rect.left}px`
      panel.style.width  = `${rect.width}px`
    }

    this.observer = new MutationObserver(reposition)
    this.observer.observe(panel, { attributes: true, attributeFilter: ['style'] })
  },
  destroyed() { this.observer?.disconnect() }
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
