// Client half of LemonWeb.ShellLive (sticky): command palette, shortcut help,
// `g <key>` navigation chords and notifications.
//
// The server ranks and renders palette results; this hook opens/closes the
// palette instantly, moves the active option (mirrored to the server so
// patches agree), runs the chosen item, remembers recent picks in
// localStorage, reports the current location/visibility (foreground
// suppression) and raises browser notifications while the tab is hidden.

import * as Shortcuts from "/assets/js/shortcuts.js"
import * as Theme from "/assets/js/theme.js"

const RECENT_KEY = "lemon-palette-recent"
const NOTIFY_KEY = "lemon-notify"
const MAX_RECENT = 8

function readJSON(key, fallback) {
  try {
    const value = JSON.parse(localStorage.getItem(key))
    return value ?? fallback
  } catch (_) {
    return fallback
  }
}

function writeJSON(key, value) {
  try {
    localStorage.setItem(key, JSON.stringify(value))
  } catch (_) {}
}

function notifyPrefs() {
  const value = readJSON(NOTIFY_KEY, null)
  const prefs = value && typeof value === "object" ? value : {}
  return {runs: prefs.runs !== false, approvals: prefs.approvals !== false}
}

function permission() {
  return "Notification" in window ? Notification.permission : "unsupported"
}

function currentPath() {
  return window.location.pathname + window.location.search
}

export const Shell = {
  mounted() {
    this.cleanups = []
    const listen = (target, name, fn, opts) => {
      target.addEventListener(name, fn, opts)
      this.cleanups.push(() => target.removeEventListener(name, fn, opts))
    }

    // `g <key>` chords from LemonWeb.Nav (rendered into data-nav).
    for (const item of JSON.parse(this.el.dataset.nav || "[]")) {
      if (!item.shortcut) continue
      this.cleanups.push(
        Shortcuts.register(`nav-${item.shortcut}`, {
          keys: `g ${item.shortcut}`,
          description: `Go to ${item.label}`,
          group: "Navigation",
          handler: () => this.navigate(item.path)
        })
      )
    }

    listen(document.body, "lemon:palette", () => (this.isOpen() ? this.closePalette(true) : this.openPalette()))
    listen(document.body, "lemon:shortcuts", () => this.openShortcuts())
    listen(document.body, "lemon:notifications", () => this.pushEvent("panel:open", {}))
    listen(document.body, "lemon:notify-prefs-changed", (event) => this.pushEvent("notify:prefs", {prefs: event.detail || notifyPrefs()}))
    listen(window, "storage", (event) => event.key === NOTIFY_KEY && this.pushEvent("notify:prefs", {prefs: notifyPrefs()}))

    const report = () => this.reportLocation()
    listen(window, "phx:navigate", () => setTimeout(report, 0))
    listen(window, "phx:page-loading-stop", report)
    listen(document, "visibilitychange", report)

    listen(this.el, "click", (event) => this.onClick(event))
    listen(this.el, "mousemove", (event) => {
      const option = event.target.closest?.("[data-palette-item]")
      if (option && option.getAttribute("aria-selected") !== "true") this.setActive(Number(option.dataset.index), false)
    })
    listen(this.el, "keydown", (event) => event.target.id === "palette-input" && this.onInputKeydown(event))

    this.handleEvent("lemon:notify", (payload) => this.desktopNotify(payload))
    this.handleEvent("lemon:notify-prefs", (prefs) => {
      writeJSON(NOTIFY_KEY, {runs: prefs.runs !== false, approvals: prefs.approvals !== false})
      document.body.dispatchEvent(new CustomEvent("lemon:notify-prefs-changed", {detail: notifyPrefs()}))
    })

    this.pushEvent("notify:init", {prefs: notifyPrefs(), permission: permission()})
    this.reportLocation()
  },

  destroyed() {
    for (const cleanup of this.cleanups || []) cleanup()
  },

  // ── Location ──────────────────────────────────────────────────────────

  reportLocation() {
    this.pushEvent("location", {path: currentPath(), visible: !document.hidden})
  },

  navigate(href) {
    this.js().navigate(href)
  },

  // ── Palette ───────────────────────────────────────────────────────────

  palette() {
    return document.getElementById("palette")
  },

  input() {
    return document.getElementById("palette-input")
  },

  isOpen() {
    const palette = this.palette()
    return !!palette && getComputedStyle(palette).display !== "none"
  },

  openPalette() {
    const palette = this.palette()
    if (!palette) return
    this.restoreFocus = document.activeElement
    // JS commands are sticky across server patches (unlike raw style edits).
    this.js().show(palette, {display: "block"})
    const input = this.input()
    input.value = ""
    input.focus()
    this.pushEvent("palette:open", {
      recent: readJSON(RECENT_KEY, []),
      chat: !!document.querySelector("[data-chat-workspace]"),
      path: currentPath(),
      visible: !document.hidden
    })
  },

  closePalette(restoreFocus) {
    if (!this.isOpen()) return
    this.js().hide(this.palette())
    this.pushEvent("palette:close", {})
    const target = this.restoreFocus
    this.restoreFocus = null
    if (restoreFocus && target?.isConnected && typeof target.focus === "function") target.focus()
  },

  options() {
    return Array.from(this.el.querySelectorAll("[data-palette-item]"))
  },

  activeIndex() {
    const options = this.options()
    const index = options.findIndex((el) => el.getAttribute("aria-selected") === "true")
    return index < 0 ? 0 : index
  },

  setActive(index, scroll = true) {
    const options = this.options()
    if (options.length === 0) return
    const next = (index + options.length) % options.length
    options.forEach((el, i) => el.setAttribute("aria-selected", String(i === next)))
    this.input()?.setAttribute("aria-activedescendant", options[next].id)
    if (scroll) options[next].scrollIntoView({block: "nearest"})
    this.pushEvent("palette:active", {index: Number(options[next].dataset.index)})
  },

  onInputKeydown(event) {
    const mod = document.documentElement.dataset.platform === "mac" ? event.metaKey : event.ctrlKey

    switch (event.key) {
      case "ArrowDown":
      case "ArrowUp":
        event.preventDefault()
        this.setActive(this.activeIndex() + (event.key === "ArrowDown" ? 1 : -1))
        break
      case "Enter": {
        event.preventDefault()
        const option = this.options()[this.activeIndex()]
        if (option) this.execute(option, mod)
        break
      }
      case "Tab":
        if (event.shiftKey) return
        event.preventDefault()
        this.pushEvent("palette:mode", {q: event.target.value})
        break
      case "Escape":
        event.preventDefault()
        event.stopPropagation()
        this.closePalette(true)
        break
    }
  },

  onClick(event) {
    if (event.target.closest("[data-palette-backdrop]")) return this.closePalette(true)

    const option = event.target.closest("[data-palette-item]")
    if (option) return this.execute(option, document.documentElement.dataset.platform === "mac" ? event.metaKey : event.ctrlKey)

    if (event.target.closest("[data-request-notification-permission]") && "Notification" in window) {
      Notification.requestPermission().then((result) => this.pushEvent("notify:permission", {permission: result}))
    }
  },

  execute(option, split) {
    const {kind, href, splitHref, action} = option.dataset
    this.remember(option)
    this.closePalette(kind === "action")

    if (kind === "navigate") {
      const target = split && splitHref ? splitHref : href
      if (target) this.navigate(target)
    } else if (kind === "chat") {
      Shortcuts.dispatch("lemon:chat-action", {action})
    } else if (kind === "action") {
      this.runAction(action)
    }
  },

  runAction(action) {
    switch (action) {
      case "toggle-theme":
        return Theme.cycle()
      case "shortcuts":
        return this.openShortcuts()
      case "notifications":
        return this.pushEvent("panel:open", {})
      case "sign-out":
        return this.signOut()
    }
  },

  remember(option) {
    const id = option.dataset.recentId
    if (!id || /^(memory|cron):/.test(id)) return
    const entry = {id, label: String(option.dataset.recentLabel || "").slice(0, 90)}
    const recent = readJSON(RECENT_KEY, [])
    const list = Array.isArray(recent) ? recent.filter((e) => e && e.id !== id) : []
    writeJSON(RECENT_KEY, [entry, ...list].slice(0, MAX_RECENT))
  },

  signOut() {
    const form = document.createElement("form")
    form.method = "post"
    form.action = "/logout"
    form.hidden = true
    const fields = {_method: "delete", _csrf_token: document.querySelector("meta[name='csrf-token']")?.content || ""}
    for (const [name, value] of Object.entries(fields)) {
      const input = document.createElement("input")
      input.type = "hidden"
      input.name = name
      input.value = value
      form.appendChild(input)
    }
    document.body.appendChild(form)
    form.submit()
  },

  // ── Shortcut help ─────────────────────────────────────────────────────

  openShortcuts() {
    this.closePalette(false)
    this.pushEvent("shortcuts:open", {shortcuts: Shortcuts.list()})
  },

  // ── Notifications ─────────────────────────────────────────────────────

  desktopNotify({title, body, href, tag}) {
    if (!document.hidden || permission() !== "granted") return
    try {
      const notification = new Notification(title, {body, tag, icon: "/favicon.svg"})
      notification.onclick = () => {
        window.focus()
        if (href) this.navigate(href)
        notification.close()
      }
    } catch (_) {}
  }
}
