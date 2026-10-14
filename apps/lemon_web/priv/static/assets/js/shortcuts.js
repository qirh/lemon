// Global keyboard shortcut manager.
//
// Bindings are registered with a combo ("mod+k", "shift+tab", "?", "alt+up")
// or a two-key chord ("g c"). `mod` is ⌘ on macOS and Ctrl elsewhere.
// Handlers run only when no modal/menu claims the key and, unless
// `allowInInput` is set, never while the user types in a field.
//
// Features communicate through DOM CustomEvents on document.body
// ("lemon:palette", "lemon:shortcuts", ...) so LiveView hooks stay decoupled.

const isMac = document.documentElement.dataset.platform === "mac"
const bindings = new Map()
let chordPrefix = null
let chordTimer = null

function normalizeKey(key) {
  const map = {" ": "space", ArrowUp: "up", ArrowDown: "down", ArrowLeft: "left", ArrowRight: "right", Escape: "esc", Enter: "enter", Tab: "tab", Backspace: "backspace"}
  return (map[key] || key).toLowerCase()
}

function comboFromEvent(event) {
  const parts = []
  const mod = isMac ? event.metaKey : event.ctrlKey
  if (mod) parts.push("mod")
  if (isMac && event.ctrlKey) parts.push("ctrl")
  if (event.altKey) parts.push("alt")
  let key = normalizeKey(event.key)
  // Alt on macOS changes event.key (e.g. ∂); fall back to the physical key.
  if (event.altKey && event.code && /^Key[A-Z]$/.test(event.code)) key = event.code.slice(3).toLowerCase()
  if (event.altKey && event.code && /^Digit\d$/.test(event.code)) key = event.code.slice(5)
  // Shift is implied by printable symbols like "?"; only record it for named keys/letters.
  if (event.shiftKey && (key.length > 1 || /[a-z0-9]/.test(key) || mod)) parts.push("shift")
  parts.push(key)
  return parts.join("+")
}

function typingTarget(target) {
  if (!target || !(target instanceof Element)) return false
  if (target.isContentEditable) return true
  const tag = target.tagName
  if (tag === "TEXTAREA" || tag === "SELECT") return true
  if (tag === "INPUT") {
    const type = (target.getAttribute("type") || "text").toLowerCase()
    return !["checkbox", "radio", "button", "submit", "reset", "range", "color"].includes(type)
  }
  return false
}

function modalOpen() {
  return !!document.querySelector('[role="dialog"][aria-modal="true"]:not([hidden])') &&
    Array.from(document.querySelectorAll('[role="dialog"][aria-modal="true"]')).some((el) => el.offsetParent !== null)
}

/**
 * Register a shortcut.
 * @param {string} id unique id (re-registering replaces)
 * @param {{keys: string, description: string, group?: string, allowInInput?: boolean, allowInModal?: boolean, handler: (e: KeyboardEvent) => (void|boolean)}} binding
 * @returns {() => void} unregister
 */
export function register(id, binding) {
  bindings.set(id, {group: "General", ...binding})
  return () => {
    if (bindings.get(id) && bindings.get(id).handler === binding.handler) bindings.delete(id)
  }
}

export function list() {
  return Array.from(bindings.entries()).map(([id, b]) => ({id, keys: b.keys, description: b.description, group: b.group}))
}

export function dispatch(name, detail = {}) {
  document.body.dispatchEvent(new CustomEvent(name, {detail, bubbles: true}))
}

function run(binding, event) {
  const result = binding.handler(event)
  if (result !== false) {
    event.preventDefault()
    event.stopPropagation()
  }
}

function onKeydown(event) {
  if (event.isComposing || event.defaultPrevented) return
  const combo = comboFromEvent(event)
  const typing = typingTarget(event.target)
  const inModal = modalOpen()

  if (chordPrefix) {
    const chord = `${chordPrefix} ${combo}`
    chordPrefix = null
    clearTimeout(chordTimer)
    for (const binding of bindings.values()) {
      if (binding.keys === chord && !typing && (!inModal || binding.allowInModal)) return run(binding, event)
    }
  }

  for (const binding of bindings.values()) {
    if (binding.keys !== combo) continue
    if (typing && !binding.allowInInput) continue
    if (inModal && !binding.allowInModal) continue
    return run(binding, event)
  }

  if (!typing && !inModal && combo.length === 1) {
    const prefix = `${combo} `
    for (const binding of bindings.values()) {
      if (binding.keys.startsWith(prefix)) {
        chordPrefix = combo
        chordTimer = setTimeout(() => (chordPrefix = null), 1200)
        return
      }
    }
  }
}

export function init() {
  window.addEventListener("keydown", onKeydown, true)
}
