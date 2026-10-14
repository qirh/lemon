// Keyboard shortcuts for the /omp page (LemonWeb.OmpLive).
//
// <div id="omp-page" phx-hook="OmpKeys">
//
// Mirrors the TUI /omp panel: `/` focuses the filter, `s` / `f` open the
// composer in steer / follow-up mode, `c` cancels the selected session's
// running turn, `x` asks to close it, `n` starts a session, `d` resumes a
// stored one, `r` refreshes, `j` / `k` move the selection and ⌘/Ctrl+Enter
// submits the form being typed in. The server decides whether an action
// applies (it knows the selection and its state); bindings exist only while
// the page is mounted.

import * as Shortcuts from "/assets/js/shortcuts.js"

const GROUP = "omp"

export const OmpKeys = {
  mounted() {
    this.unregister = []
    const bind = (id, keys, description, handler) =>
      this.unregister.push(Shortcuts.register(`omp:${id}`, {keys, description, group: GROUP, handler}))

    bind("filter", "/", "Focus the session filter", () => {
      const input = document.getElementById("omp-filter")
      if (!input || input.offsetParent === null) return false
      input.focus()
      input.select()
    })
    bind("steer", "s", "Steer the selected session", () => this.compose("steer"))
    bind("follow-up", "f", "Queue a follow-up for the selected session", () => this.compose("followUp"))
    bind("cancel", "c", "Cancel the selected session's running turn", () => this.pushEvent("cancel_turn", {}))
    bind("close", "x", "Close the selected session…", () => this.pushEvent("preview_close", {}))
    bind("new", "n", "Start a new omp session", () => this.pushEvent("open_start", {}))
    bind("resume", "d", "Resume a stored omp session…", () => this.pushEvent("open_resume", {}))
    bind("refresh", "r", "Refresh omp sessions", () => this.pushEvent("refresh", {}))
    bind("next", "j", "Next session", () => this.pushEvent("select_step", {delta: 1}))
    bind("previous", "k", "Previous session", () => this.pushEvent("select_step", {delta: -1}))

    // ⌘/Ctrl+Enter sends the composer, start or resume form being typed in.
    this.unregister.push(
      Shortcuts.register("omp:submit", {
        keys: "mod+enter",
        description: "Send the message / submit the dialog",
        group: GROUP,
        allowInInput: true,
        allowInModal: true,
        handler: () => {
          const form = document.activeElement?.closest?.("#omp-composer, #omp-start-form, #omp-resume-form")
          if (!form) return false
          form.requestSubmit()
        }
      })
    )
  },

  compose(mode) {
    this.pushEvent("compose_mode", {mode}, (reply) => {
      if (!reply || !reply.ok) return
      const input = document.getElementById("omp-composer-input")
      if (input) input.focus()
    })
  },

  destroyed() {
    this.unregister.forEach((unregister) => unregister())
  }
}

export const Hooks = {OmpKeys}
