// Theme preference: "light" | "dark" | "system" (default). The inline script
// in root.html.heex applies it before first paint; this module keeps it in
// sync with user choices and OS changes.

const KEY = "lemon-theme"
const media = window.matchMedia("(prefers-color-scheme: dark)")

export function preference() {
  try {
    return localStorage.getItem(KEY) || "system"
  } catch (_) {
    return "system"
  }
}

export function apply(pref = preference()) {
  const dark = pref === "dark" || (pref === "system" && media.matches)
  const root = document.documentElement
  root.dataset.theme = dark ? "dark" : "light"
  root.dataset.themePref = pref
  document.body?.dispatchEvent(new CustomEvent("lemon:theme-changed", {detail: {pref, theme: root.dataset.theme}}))
}

export function set(pref) {
  try {
    localStorage.setItem(KEY, pref)
  } catch (_) {}
  apply(pref)
}

export function cycle() {
  const order = ["light", "dark", "system"]
  set(order[(order.indexOf(preference()) + 1) % order.length])
}

export function init() {
  media.addEventListener("change", () => preference() === "system" && apply("system"))
  window.addEventListener("storage", (event) => event.key === KEY && apply())
}
