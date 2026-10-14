// Session manager keyboard navigation (LemonWeb.ManagementLive).
//
// Rows are focusable (`tabindex=-1`); j/k and ↑/↓ move DOM focus between
// them, so the highlight survives LiveView patches (focus is preserved for
// elements with stable ids). Enter opens the focused row in chat, `i`
// inspects it, `x` toggles its selection and `/` focuses the search box.

import * as Shortcuts from "/assets/js/shortcuts.js"

const INTERACTIVE = "a,button,input,select,textarea,summary,[role=menuitem]"

function rows(root) {
  return Array.from(root.querySelectorAll("[data-session-row]"))
}

export const SessionsTable = {
  mounted() {
    const focusedRow = () => {
      const active = document.activeElement
      return active && active.matches?.("[data-session-row]") && this.el.contains(active) ? active : null
    }

    const move = (delta) => {
      const list = rows(this.el)
      if (list.length === 0) return false
      const current = focusedRow() || this.el.querySelector(`[data-key="${CSS.escape(this.lastKey || "")}"]`)
      let index = current ? list.indexOf(current) + delta : delta > 0 ? 0 : list.length - 1
      index = Math.max(0, Math.min(list.length - 1, index))
      const row = list[index]
      row.focus({preventScroll: true})
      row.scrollIntoView({block: "nearest"})
      this.lastKey = row.dataset.key
    }

    // Enter/i/x act only on a focused row so they never hijack links,
    // buttons or menus that have focus.
    const onRow = (selector) => (event) => {
      const row = focusedRow()
      if (!row || (event.target !== row && event.target.closest?.(INTERACTIVE))) return false
      row.querySelector(selector)?.click()
    }

    const bindings = [
      ["sessions.next", "j", "Next session", () => move(1)],
      ["sessions.next-arrow", "down", "Next session", () => move(1)],
      ["sessions.prev", "k", "Previous session", () => move(-1)],
      ["sessions.prev-arrow", "up", "Previous session", () => move(-1)],
      ["sessions.open", "enter", "Open focused session in chat", onRow("[data-open-chat]")],
      ["sessions.inspect", "i", "Inspect focused session", onRow("[data-inspect]")],
      ["sessions.select", "x", "Select focused session", onRow("[data-select]")],
      [
        "sessions.search",
        "/",
        "Search sessions",
        () => {
          const input = document.getElementById("session-search")
          if (!input) return false
          input.focus()
          input.select()
        }
      ]
    ]

    this.unregister = bindings.map(([id, keys, description, handler]) => Shortcuts.register(id, {keys, description, group: "Sessions", handler}))

    this.onFocusIn = (event) => {
      const row = event.target.closest?.("[data-session-row]")
      if (row) this.lastKey = row.dataset.key
    }
    this.el.addEventListener("focusin", this.onFocusIn)
  },
  destroyed() {
    this.unregister?.forEach((unregister) => unregister())
  }
}

export const SessionsHooks = {SessionsTable}
