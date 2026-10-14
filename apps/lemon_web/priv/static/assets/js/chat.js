// Chat workspace hooks (LemonWeb.ChatLive + LemonWeb.Chat.PaneLive).
//
// Palette / shortcut contract: anything may dispatch
//   document.body.dispatchEvent(new CustomEvent("lemon:chat-action", {detail: {action}}))
// with action one of:
//   new-session | fork | toggle-plan | stop | compact | toggle-inspector |
//   toggle-split | focus-composer | model-picker | thinking-picker |
//   toggle-sidebar | prev-session | next-session | toggle-tools | expand-latest
// Workspace actions are handled by the ChatWorkspace hook; pane actions go to
// the active pane (the last pane that received focus or a pointer event, else
// the primary pane).

import * as Shortcuts from "/assets/js/shortcuts.js"
import {highlightWithin} from "/assets/js/hooks.js"

const ACTION_EVENT = "lemon:chat-action"
const WORKSPACE_ACTIONS = new Set(["new-session", "toggle-split", "toggle-sidebar", "prev-session", "next-session"])
const panes = new Map()
let activePane = null

function currentPane() {
  if (activePane && panes.has(activePane)) return panes.get(activePane)
  for (const hook of panes.values()) if (hook.el.dataset.role === "primary") return hook
  return panes.values().next().value || null
}

function dispatchAction(action) {
  Shortcuts.dispatch(ACTION_EVENT, {action})
}

// ── Document title prefix (● while running / awaiting approval) ──────────

let baseTitle = null

function syncTitle() {
  const current = document.title.replace(/^[●◐] /, "")
  if (baseTitle === null || current !== baseTitle) baseTitle = current
  const states = Array.from(panes.values()).map((hook) => hook.el.dataset.runState)
  const prefix = states.includes("approval") ? "◐ " : states.includes("running") ? "● " : ""
  const next = prefix + baseTitle
  if (document.title !== next) document.title = next
}

const titleObserver = new MutationObserver(() => {
  if (!document.title.match(/^[●◐] /) && panes.size > 0) syncTitle()
})

function observeTitle() {
  const titleEl = document.querySelector("title")
  if (titleEl) titleObserver.observe(titleEl, {childList: true, characterData: true, subtree: true})
}

// ── Shortcuts ────────────────────────────────────────────────────────────

const SHORTCUTS = [
  ["chat.focus", "mod+/", "Focus the message box", "Chat", "focus-composer", true],
  ["chat.stop", "mod+.", "Stop the running turn", "Chat", "stop", true],
  ["chat.plan", "mod+shift+p", "Toggle plan mode", "Chat", "toggle-plan", true],
  ["chat.model", "mod+shift+m", "Choose a model", "Chat", "model-picker", true],
  ["chat.tools", "alt+o", "Expand / collapse all tool output", "Chat", "toggle-tools", false],
  ["chat.latest", "alt+r", "Expand the latest tool or thought", "Chat", "expand-latest", false],
  ["chat.new", "mod+shift+o", "New session", "Workspace", "new-session", true],
  ["chat.sidebar", "mod+b", "Toggle sessions sidebar", "Workspace", "toggle-sidebar", true],
  ["chat.inspector", "mod+i", "Toggle inspector", "Workspace", "toggle-inspector", true],
  ["chat.split", "mod+\\", "Toggle split view", "Workspace", "toggle-split", true],
  ["chat.prev", "alt+up", "Previous session", "Workspace", "prev-session", true],
  ["chat.next", "alt+down", "Next session", "Workspace", "next-session", true]
]

export const ChatWorkspace = {
  mounted() {
    this.unregister = SHORTCUTS.map(([id, keys, description, group, action, allowInInput]) =>
      Shortcuts.register(id, {keys, description, group, allowInInput, handler: () => dispatchAction(action)})
    )
    this.onAction = (event) => {
      const action = event.detail?.action
      if (!WORKSPACE_ACTIONS.has(action)) return
      switch (action) {
        case "new-session":
          this.pushEvent("new-session", {})
          break
        case "toggle-split":
          this.pushEvent("toggle-split", {})
          break
        case "prev-session":
          this.pushEvent("nav-session", {dir: "prev"})
          break
        case "next-session":
          this.pushEvent("nav-session", {dir: "next"})
          break
        case "toggle-sidebar":
          this.toggleSidebar()
          break
      }
    }
    document.body.addEventListener(ACTION_EVENT, this.onAction)
    observeTitle()
  },
  toggleSidebar() {
    const sidebar = document.getElementById("chat-sidebar")
    if (!sidebar) return
    if (window.matchMedia("(min-width: 768px)").matches) {
      this.pushEvent("toggle-sidebar", {})
    } else {
      this.js().toggleAttribute(sidebar, "data-mobile-open", "true", "false")
    }
  },
  destroyed() {
    this.unregister.forEach((fn) => fn())
    document.body.removeEventListener(ACTION_EVENT, this.onAction)
  }
}

export const ChatPane = {
  mounted() {
    this.key = this.el.dataset.pane
    panes.set(this.key, this)
    if (!activePane || this.el.dataset.role === "primary") activePane = activePane || this.key
    this.activate = () => (activePane = this.key)
    this.el.addEventListener("focusin", this.activate)
    this.el.addEventListener("pointerdown", this.activate)
    this.onAction = (event) => {
      const action = event.detail?.action
      if (!action || WORKSPACE_ACTIONS.has(action) || currentPane() !== this) return
      this.run(action)
    }
    document.body.addEventListener(ACTION_EVENT, this.onAction)
    this.handleEvent("chat:focus-composer", ({pane}) => pane === this.key && this.focusComposer())
    syncTitle()
  },
  updated() {
    syncTitle()
  },
  destroyed() {
    panes.delete(this.key)
    if (activePane === this.key) activePane = null
    document.body.removeEventListener(ACTION_EVENT, this.onAction)
    syncTitle()
  },
  composer() {
    return this.el.querySelector("textarea[phx-hook=Composer]")
  },
  focusComposer() {
    const textarea = this.composer()
    if (!textarea) return
    textarea.focus()
    textarea.setSelectionRange(textarea.value.length, textarea.value.length)
  },
  run(action) {
    switch (action) {
      case "focus-composer":
        return this.focusComposer()
      case "stop":
        if (this.el.dataset.runState !== "idle") this.pushEvent("stop", {})
        return
      case "toggle-plan":
        return this.pushEvent("toggle-plan", {})
      case "compact":
        return this.pushEvent("compact", {})
      case "toggle-inspector":
        return this.pushEvent("toggle-inspector", {})
      case "model-picker":
        return this.pushEvent("open-model-picker", {})
      case "thinking-picker": {
        const trigger = this.el.querySelector(`#thinking-${this.key}-trigger`)
        if (trigger) trigger.click()
        return
      }
      case "fork":
        return this.pushEvent("fork", {})
      case "toggle-tools": {
        const cards = Array.from(this.el.querySelectorAll("details.tool-card, details.thinking-block"))
        const open = cards.some((card) => !card.open)
        cards.forEach((card) => (card.open = open))
        return
      }
      case "expand-latest": {
        const cards = this.el.querySelectorAll("details.tool-card, details.thinking-block")
        const last = cards[cards.length - 1]
        if (last) {
          last.open = true
          last.scrollIntoView({block: "nearest"})
        }
        return
      }
    }
  }
}

// ── Composer ─────────────────────────────────────────────────────────────

function autosize(textarea) {
  textarea.style.height = "auto"
  textarea.style.height = Math.min(textarea.scrollHeight, 288) + "px"
}

export const Composer = {
  mounted() {
    const el = this.el
    autosize(el)
    el.addEventListener("input", () => autosize(el))
    el.addEventListener("keydown", (event) => {
      if (event.isComposing) return
      const mod = document.documentElement.dataset.platform === "mac" ? event.metaKey : event.ctrlKey
      if (event.key === "Enter" && !event.shiftKey && !event.altKey) {
        event.preventDefault()
        if (mod) {
          const steer = el.form?.querySelector('button[phx-value-mode="steer"]')
          if (steer) {
            steer.click()
            setTimeout(() => el.form?.requestSubmit(), 30)
            return
          }
        }
        if (el.value.trim() !== "" || el.form?.querySelector("[id^=upload-]")) el.form?.requestSubmit()
      } else if (event.key === "Tab" && event.shiftKey && el.dataset.pane !== "home") {
        event.preventDefault()
        this.pushEventTo(el, "cycle-thinking", {})
      } else if (event.key === "Escape") {
        el.blur()
      }
    })
    el.addEventListener("paste", (event) => {
      const files = Array.from(event.clipboardData?.files || []).filter((file) => file.type.startsWith("image/"))
      const input = el.form?.querySelector("input[type=file]")
      if (files.length > 0 && input) {
        event.preventDefault()
        this.upload(input.name || "files", files)
      }
    })
    this.handleEvent("chat:composer-reset", ({pane}) => {
      if (pane !== el.dataset.pane) return
      el.value = ""
      autosize(el)
    })
  },
  updated() {
    autosize(this.el)
  }
}

// ── Transcript ───────────────────────────────────────────────────────────

// Keeps the transcript pinned to the bottom while new output streams in,
// unless the reader scrolled up; then a "Latest" button appears.
export const ChatScroll = {
  mounted() {
    this.pinned = true
    this.jump = this.el.querySelector("[data-jump-latest]")
    this.onScroll = () => {
      const distance = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
      this.pinned = distance < 80
      this.jump?.classList.toggle("hidden", this.pinned)
      this.jump?.classList.toggle("inline-flex", !this.pinned)
    }
    this.el.addEventListener("scroll", this.onScroll, {passive: true})
    this.jump?.addEventListener("click", () => this.toBottom(true))
    this.observer = new MutationObserver(() => {
      if (this.pinned) this.toBottom(false)
      this.el.querySelectorAll("pre[data-autoscroll=true]").forEach((pre) => (pre.scrollTop = pre.scrollHeight))
    })
    this.observer.observe(this.el, {childList: true, subtree: true, characterData: true})
    this.toBottom(false)
  },
  toBottom(smooth) {
    this.el.scrollTo({top: this.el.scrollHeight, behavior: smooth ? "smooth" : "auto"})
    this.pinned = true
  },
  destroyed() {
    this.observer.disconnect()
  }
}

// Highlights fenced code in rendered markdown and adds a copy button to each block.
export const ChatMarkdown = {
  mounted() {
    this.decorate()
  },
  updated() {
    this.decorate()
  },
  decorate() {
    this.el.querySelectorAll("pre").forEach((pre) => {
      if (pre.querySelector(":scope > [data-copy-code]")) return
      const button = document.createElement("button")
      button.type = "button"
      button.dataset.copyCode = ""
      button.className = "btn btn-ghost btn-icon btn-sm absolute right-1 top-1 h-6 w-6 opacity-60 hover:opacity-100"
      button.setAttribute("aria-label", "Copy code")
      button.innerHTML = '<svg viewBox="0 0 24 24" class="h-3.5 w-3.5" fill="none" stroke="currentColor" stroke-width="1.75" aria-hidden="true"><rect width="14" height="14" x="8" y="8" rx="2"/><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/></svg>'
      button.addEventListener("click", async () => {
        const code = pre.querySelector("code")?.innerText ?? pre.innerText
        try {
          await navigator.clipboard.writeText(code)
          button.setAttribute("aria-label", "Copied")
          setTimeout(() => button.setAttribute("aria-label", "Copy code"), 1200)
        } catch (_) {}
      })
      pre.appendChild(button)
    })
    highlightWithin(this.el)
  }
}

// Live clock: `data-since` (elapsed) or `data-deadline` (remaining), in ms epoch.
export const Countdown = {
  mounted() {
    this.tick = () => {
      const now = Date.now()
      const since = Number(this.el.dataset.since)
      const deadline = Number(this.el.dataset.deadline)
      const ms = since ? now - since : deadline - now
      if (deadline && ms <= 0) {
        this.el.textContent = "expired"
        return
      }
      const s = Math.max(0, Math.floor(ms / 1000))
      const text = s < 60 ? `${s}s` : s < 3600 ? `${Math.floor(s / 60)}m ${s % 60}s` : `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`
      this.el.textContent = (this.el.dataset.prefix || "") + text
    }
    this.tick()
    this.timer = setInterval(this.tick, 1000)
  },
  updated() {
    this.tick()
  },
  destroyed() {
    clearInterval(this.timer)
  }
}

// Arrow-key navigation inside a list of links/buttons ([data-list-item] or role=option).
export const ListNav = {
  mounted() {
    this.el.addEventListener("keydown", (event) => {
      if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return
      const items = Array.from(this.el.querySelectorAll("[data-list-item],[role=option]"))
      if (items.length === 0) return
      const index = items.indexOf(document.activeElement)
      if (index === -1 && !this.el.contains(document.activeElement)) return
      event.preventDefault()
      const next = event.key === "ArrowDown" ? Math.min(index + 1, items.length - 1) : Math.max(index - 1, 0)
      items[next]?.focus()
    })
  }
}

export const ChatHooks = {ChatWorkspace, ChatPane, Composer, ChatScroll, ChatMarkdown, Countdown, ListNav}
