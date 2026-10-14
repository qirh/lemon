import {Socket} from "/assets/vendor/phoenix.mjs"
import {LiveSocket} from "/assets/vendor/phoenix_live_view.esm.js"
import {Hooks} from "/assets/js/hooks.js"
import * as Shortcuts from "/assets/js/shortcuts.js"
import * as Theme from "/assets/js/theme.js"

Theme.init()
Shortcuts.init()

// Login page: `/login#token=…` (opened by `lemon web`) signs in without the
// token ever reaching the server log, history or Referer: read the fragment,
// drop it from history, then submit the regular POST form.
function autoLoginFromFragment() {
  const form = document.getElementById("login-form")
  if (!form || !window.location.hash.startsWith("#token=")) return
  const token = decodeURIComponent(window.location.hash.slice("#token=".length))
  window.history.replaceState(null, "", window.location.pathname + window.location.search)
  if (!token) return
  form.querySelector("input[name=token]").value = token
  form.submit()
}

autoLoginFromFragment()

// Global shortcuts owned by the shell. Feature hooks register their own.
Shortcuts.register("help", {keys: "?", description: "Show keyboard shortcuts", group: "General", handler: () => Shortcuts.dispatch("lemon:shortcuts")})
Shortcuts.register("palette", {keys: "mod+k", description: "Open command palette", group: "General", allowInInput: true, allowInModal: true, handler: () => Shortcuts.dispatch("lemon:palette")})
Shortcuts.register("theme", {keys: "mod+shift+l", description: "Cycle light / dark / system theme", group: "General", allowInInput: true, handler: () => Theme.cycle()})

const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")

if (document.querySelector("[data-phx-session]")) {
  const liveSocket = new LiveSocket("/live", Socket, {
    params: {_csrf_token: csrfToken},
    hooks: Hooks
  })

  liveSocket.connect()
  window.liveSocket = liveSocket
}

window.Lemon = {Shortcuts, Theme}
