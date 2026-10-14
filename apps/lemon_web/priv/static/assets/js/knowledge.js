// Hooks for the Skills, MCP and Nodes pages.

import * as Shortcuts from "/assets/js/shortcuts.js"

// `/` focuses the page's search field (outside inputs/dialogs); Esc inside the
// field clears a non-empty query first, then blurs.
export const SearchShortcut = {
  mounted() {
    this.unregister = Shortcuts.register(`search:${this.el.id}`, {
      keys: "/",
      description: "Focus search",
      group: "Page",
      handler: () => {
        this.el.focus()
        this.el.select()
      }
    })
    this.onKeydown = (event) => {
      if (event.key !== "Escape") return
      event.stopPropagation()
      if (this.el.value) {
        this.el.value = ""
        this.el.dispatchEvent(new Event("input", {bubbles: true}))
      } else {
        this.el.blur()
      }
    }
    this.el.addEventListener("keydown", this.onKeydown)
  },
  destroyed() {
    this.unregister?.()
    this.el.removeEventListener("keydown", this.onKeydown)
  }
}

export const Hooks = {SearchShortcut}
