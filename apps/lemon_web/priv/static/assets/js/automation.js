// Page-level keyboard shortcuts for the automation, blueprint and memory pages.
//
// <div phx-hook="PageKeys" data-search="input-id" data-tabs="a,b,c"
//      data-tab-labels="A,B,C" data-tab-event="tab" data-group="Automation">
//
// `/` focuses the search input; number keys 1..n switch tabs by pushing
// `data-tab-event` (default "tab") with {tab}. Bindings are unregistered when
// the element is removed, so they only exist while the page is mounted.

import * as Shortcuts from "/assets/js/shortcuts.js"

export const PageKeys = {
  mounted() {
    const group = this.el.dataset.group || "Page"
    const scope = `page:${this.el.id}`
    const tabs = (this.el.dataset.tabs || "").split(",").filter(Boolean)
    const labels = (this.el.dataset.tabLabels || "").split(",")
    const event = this.el.dataset.tabEvent || "tab"
    this.unregister = []

    if (this.el.dataset.search) {
      this.unregister.push(
        Shortcuts.register(`${scope}:search`, {
          keys: "/",
          description: "Focus search",
          group,
          handler: () => {
            const input = document.getElementById(this.el.dataset.search)
            if (!input) return false
            input.focus()
            input.select?.()
          }
        })
      )
    }

    tabs.forEach((tab, index) => {
      this.unregister.push(
        Shortcuts.register(`${scope}:tab:${index + 1}`, {
          keys: String(index + 1),
          description: `Show ${labels[index] || tab}`,
          group,
          handler: () => this.pushEvent(event, {tab})
        })
      )
    })
  },
  destroyed() {
    this.unregister.forEach((unregister) => unregister())
  }
}

export const Hooks = {PageKeys}
