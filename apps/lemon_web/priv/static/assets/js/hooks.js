// LiveView hooks shared by the whole UI. Feature hooks live in their own
// modules and are merged here so app.js has a single registry.

import * as Theme from "/assets/js/theme.js"
import {SessionsHooks} from "/assets/js/sessions.js"

let hljsPromise = null

// highlight.js is loaded lazily on first use (≈130 kB) with Elixir/Erlang/
// Dockerfile grammars added to the common bundle.
export function loadHighlighter() {
  if (!hljsPromise) {
    hljsPromise = Promise.all([
      import("/assets/vendor/highlight/highlight.min.js"),
      import("/assets/vendor/highlight/elixir.min.js"),
      import("/assets/vendor/highlight/erlang.min.js"),
      import("/assets/vendor/highlight/dockerfile.min.js")
    ]).then(([core, elixir, erlang, dockerfile]) => {
      const hljs = core.default
      hljs.registerLanguage("elixir", elixir.default)
      hljs.registerLanguage("erlang", erlang.default)
      hljs.registerLanguage("dockerfile", dockerfile.default)
      hljs.configure({ignoreUnescapedHTML: true, throwUnescapedHTML: false})
      return hljs
    })
  }
  return hljsPromise
}

const LANGUAGE_ALIASES = {ex: "elixir", exs: "elixir", heex: "xml", sh: "bash", zsh: "bash", shell: "bash", console: "bash", js: "javascript", jsx: "javascript", ts: "typescript", tsx: "typescript", py: "python", rb: "ruby", rs: "rust", yml: "yaml", md: "markdown", erl: "erlang", hrl: "erlang", patch: "diff"}

export function languageFor(name) {
  if (!name) return null
  const lower = String(name).toLowerCase()
  return LANGUAGE_ALIASES[lower] || lower
}

export function languageFromPath(path) {
  const match = /\.([A-Za-z0-9]+)$/.exec(path || "")
  if (!match) return /(^|\/)Dockerfile$/.test(path || "") ? "dockerfile" : null
  return languageFor(match[1])
}

// Highlights every <pre><code> inside `root` whose text changed since last run.
// Large blocks (>200 kB) are left plain to keep the main thread responsive.
export async function highlightWithin(root) {
  const blocks = root.matches?.("code") ? [root] : Array.from(root.querySelectorAll("pre code"))
  if (blocks.length === 0) return
  const hljs = await loadHighlighter()
  for (const block of blocks) {
    const text = block.textContent || ""
    if (block.dataset.hlSource === text || text.length > 200_000) continue
    const lang = languageFor(block.dataset.language || (/language-([\w+-]+)/.exec(block.className) || [])[1])
    try {
      const result = lang && hljs.getLanguage(lang) ? hljs.highlight(text, {language: lang, ignoreIllegals: true}) : text.length < 20_000 ? hljs.highlightAuto(text) : null
      if (result) {
        block.innerHTML = result.value
        block.classList.add("hljs")
      }
    } catch (_) {}
    block.dataset.hlSource = block.textContent || text
  }
}

export const Highlight = {
  mounted() {
    highlightWithin(this.el)
  },
  updated() {
    delete this.el.dataset.hlSource
    highlightWithin(this.el)
  }
}

export const CopyButton = {
  mounted() {
    this.el.addEventListener("click", async () => {
      const target = document.getElementById(this.el.dataset.copyTarget)
      const text = this.el.dataset.copyText ?? target?.innerText ?? ""
      try {
        await navigator.clipboard.writeText(text)
        this.el.dataset.copied = "true"
        const label = this.el.getAttribute("aria-label")
        this.el.setAttribute("aria-label", "Copied")
        setTimeout(() => {
          delete this.el.dataset.copied
          if (label) this.el.setAttribute("aria-label", label)
        }, 1200)
      } catch (_) {}
    })
  }
}

export const AutoDismiss = {
  mounted() {
    this.timer = setTimeout(() => this.el.click(), Number(this.el.dataset.timeout || 6000))
  },
  destroyed() {
    clearTimeout(this.timer)
  }
}

// Accessible disclosure menu used by LemonWeb.UI.dropdown/1: click or
// Enter/Space opens, arrows move, Esc/outside click closes and restores focus.
export const Dropdown = {
  mounted() {
    this.trigger = this.el.querySelector("[data-dropdown-trigger]")
    this.menu = this.el.querySelector("[data-dropdown-menu]")
    this.onDocClick = (event) => !this.el.contains(event.target) && this.close(false)
    this.trigger.addEventListener("click", (event) => {
      event.preventDefault()
      this.menu.hidden ? this.open() : this.close(true)
    })
    this.trigger.addEventListener("keydown", (event) => {
      if (event.key === "ArrowDown") {
        event.preventDefault()
        this.open()
      }
    })
    this.menu.addEventListener("keydown", (event) => {
      const items = this.items()
      const index = items.indexOf(document.activeElement)
      if (event.key === "Escape") {
        event.preventDefault()
        event.stopPropagation()
        this.close(true)
      } else if (event.key === "ArrowDown") {
        event.preventDefault()
        items[(index + 1) % items.length]?.focus()
      } else if (event.key === "ArrowUp") {
        event.preventDefault()
        items[(index - 1 + items.length) % items.length]?.focus()
      } else if (event.key === "Tab") {
        this.close(false)
      }
    })
    this.menu.addEventListener("click", (event) => {
      if (event.target.closest('[role="menuitem"],[role="menuitemradio"]')) this.close(false)
    })
  },
  items() {
    return Array.from(this.menu.querySelectorAll('[role="menuitem"],[role="menuitemradio"]')).filter((el) => !el.disabled)
  },
  open() {
    this.menu.hidden = false
    this.trigger.setAttribute("aria-expanded", "true")
    document.addEventListener("click", this.onDocClick, true)
    const checked = this.menu.querySelector('[aria-checked="true"]')
    ;(checked || this.items()[0])?.focus()
  },
  close(restoreFocus) {
    this.menu.hidden = true
    this.trigger.setAttribute("aria-expanded", "false")
    document.removeEventListener("click", this.onDocClick, true)
    if (restoreFocus) this.trigger.querySelector("button,[tabindex]")?.focus?.() || this.trigger.focus()
  },
  updated() {
    // Server re-render resets `hidden`; keep the menu closed after patches.
    if (this.trigger.getAttribute("aria-expanded") !== "true") this.menu.hidden = true
  },
  destroyed() {
    document.removeEventListener("click", this.onDocClick, true)
  }
}

export const ThemeSwitcher = {
  mounted() {
    const sync = () => {
      const pref = Theme.preference()
      this.el.querySelectorAll("[data-theme-choice]").forEach((button) => button.setAttribute("aria-pressed", String(button.dataset.themeChoice === pref)))
    }
    this.el.addEventListener("click", (event) => {
      const button = event.target.closest("[data-theme-choice]")
      if (button) Theme.set(button.dataset.themeChoice)
    })
    this.onChange = sync
    document.body.addEventListener("lemon:theme-changed", this.onChange)
    sync()
  },
  destroyed() {
    document.body.removeEventListener("lemon:theme-changed", this.onChange)
  }
}

// Feature hooks register here (one import line per module).
export const Hooks = {Highlight, CopyButton, AutoDismiss, Dropdown, ThemeSwitcher, ...SessionsHooks}
