// Runtime slice hooks (Settings).
//
// NotificationPrefs keeps the per-event notification toggles in localStorage
// under "lemon-notify" as JSON {runs: boolean, approvals: boolean}. A missing or
// invalid value means both are on; the shell only notifies when the browser
// permission is "granted". Changes dispatch "lemon:notify-prefs-changed" on
// document.body (detail = prefs) and other tabs resync via the storage event.

const NOTIFY_KEY = "lemon-notify"

export function readNotifyPrefs() {
  try {
    const parsed = JSON.parse(localStorage.getItem(NOTIFY_KEY) || "null")
    if (parsed && typeof parsed === "object") {
      return {runs: parsed.runs !== false, approvals: parsed.approvals !== false}
    }
  } catch (_) {}
  return {runs: true, approvals: true}
}

function writeNotifyPrefs(prefs) {
  try {
    localStorage.setItem(NOTIFY_KEY, JSON.stringify(prefs))
  } catch (_) {}
  document.body.dispatchEvent(new CustomEvent("lemon:notify-prefs-changed", {detail: prefs}))
}

const PERMISSION_TEXT = {
  granted: "Allowed — desktop alerts appear when this tab is in the background.",
  denied: "Blocked in this browser. Allow notifications for this site in the browser's site settings.",
  default: "Not requested yet.",
  unsupported: "This browser does not support desktop notifications."
}

export const NotificationPrefs = {
  mounted() {
    this.status = this.el.querySelector("[data-permission-status]")
    this.request = this.el.querySelector("[data-request-permission]")
    this.switches = Array.from(this.el.querySelectorAll("[data-pref]"))

    this.onClick = (event) => {
      const toggle = event.target.closest("[data-pref]")
      if (toggle) {
        const prefs = readNotifyPrefs()
        prefs[toggle.dataset.pref] = toggle.getAttribute("aria-checked") !== "true"
        writeNotifyPrefs(prefs)
        this.sync()
        return
      }
      if (event.target.closest("[data-request-permission]") && "Notification" in window) {
        Notification.requestPermission().then(() => this.sync())
      }
    }
    this.onExternal = () => this.sync()
    this.onStorage = (event) => event.key === NOTIFY_KEY && this.sync()

    this.el.addEventListener("click", this.onClick)
    document.body.addEventListener("lemon:notify-prefs-changed", this.onExternal)
    window.addEventListener("storage", this.onStorage)
    this.sync()
  },
  sync() {
    const prefs = readNotifyPrefs()
    this.switches.forEach((toggle) => toggle.setAttribute("aria-checked", String(prefs[toggle.dataset.pref] !== false)))
    const permission = "Notification" in window ? Notification.permission : "unsupported"
    this.el.dataset.permission = permission
    if (this.status) this.status.textContent = PERMISSION_TEXT[permission] || PERMISSION_TEXT.default
    if (this.request) this.request.hidden = permission !== "default"
  },
  destroyed() {
    this.el.removeEventListener("click", this.onClick)
    document.body.removeEventListener("lemon:notify-prefs-changed", this.onExternal)
    window.removeEventListener("storage", this.onStorage)
  }
}

export const RuntimeHooks = {NotificationPrefs}
