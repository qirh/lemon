#!/usr/bin/env bash
# Regression checks for bin/lvm against a throwaway HOME, fake releases and a
# fake checkout. Launchers are stubs that log which root handled each command.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lemon-lvm.XXXXXX")"
LISTENER_PID=""

cleanup() {
  if [[ "$LISTENER_PID" =~ ^[0-9]+$ ]] && kill -0 "$LISTENER_PID" 2>/dev/null; then
    kill "$LISTENER_PID" 2>/dev/null || true
    wait "$LISTENER_PID" 2>/dev/null || true
  fi
  if [[ "$TEST_DIR" == "${TMPDIR:-/tmp}"/lemon-lvm.* ]]; then
    rm -rf -- "$TEST_DIR"
  fi
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf 'ok - %s\n' "$1"; }

export HOME="$TEST_DIR/home"
LOG="$TEST_DIR/launcher.log"
PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
export LEMON_CONTROL_PLANE_PORT="$PORT"
VERSIONS="$HOME/.lemon/versions"
LAUNCHER="$HOME/.lemon/bin/lemon"

# stub_launcher <path> <label>: logs "<label> <command>"; `stop` kills the
# listener recorded in $TEST_DIR/listener.pid unless $TEST_DIR/stop-fails exists.
stub_launcher() {
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "$2" "\$1" >> "$LOG"
if [ "\$1" = stop ]; then
  [ ! -e "$TEST_DIR/stop-fails" ] || exit 1
  kill "\$(cat "$TEST_DIR/listener.pid")"
  while kill -0 "\$(cat "$TEST_DIR/listener.pid")" 2>/dev/null; do sleep 0.05; done
fi
EOF
  chmod +x "$1"
}

stub_launcher "$VERSIONS/2026.10.1/bin/lemon" release-1
stub_launcher "$VERSIONS/2026.10.2/bin/lemon" release-2
mkdir -p "$HOME/.lemon/bin"
ln -s 2026.10.1 "$VERSIONS/current"
ln -s ../versions/current/bin/lemon "$LAUNCHER"

CHECKOUT="$TEST_DIR/checkout"
mkdir -p "$CHECKOUT/apps/lemon_cli"
touch "$CHECKOUT/mix.exs"
stub_launcher "$CHECKOUT/bin/lemon" local
cp "$ROOT/bin/lvm" "$CHECKOUT/bin/lvm"
cat > "$CHECKOUT/install.sh" <<EOF
#!/bin/sh
printf 'install %s %s\n' "\${LEMON_VERSION:-latest}" "\$*" >> "$LOG"
mkdir -p "$VERSIONS/2026.11.0/bin"
cp "$VERSIONS/2026.10.2/bin/lemon" "$VERSIONS/2026.11.0/bin/lemon"
ln -sfn 2026.11.0 "$VERSIONS/current"
ln -sfn ../versions/current/bin/lemon "$LAUNCHER"
EOF
LVM="$CHECKOUT/bin/lvm"
CHECKOUT_REAL="$(cd "$CHECKOUT" && pwd -P)"

start_listener() {
  python3 -c 'import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(); time.sleep(600)' "$PORT" &
  LISTENER_PID=$!
  printf '%s\n' "$LISTENER_PID" > "$TEST_DIR/listener.pid"
  until (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; do sleep 0.05; done
}

[ "$("$LVM" current)" = 2026.10.1 ] || fail "current reports the installer's release"
listing="$("$LVM" list)"
grep -qx '\* 2026.10.1' <<<"$listing" || fail "list marks the active release"
grep -qx '  2026.10.2' <<<"$listing" || fail "list shows the inactive release"
ok "list and current read the installer layout"

"$LVM" use 2026.10.2 >/dev/null
[ "$(readlink "$VERSIONS/current")" = 2026.10.2 ] || fail "use <version> flips versions/current"
[ "$(readlink "$LAUNCHER")" = ../versions/current/bin/lemon ] || fail "release launcher link stays canonical"
[ ! -s "$LOG" ] || fail "no launcher runs when nothing listens on the control port"
ok "use <version> flips only versions/current"

"$LVM" use local >/dev/null
[ "$(readlink "$LAUNCHER")" = "$CHECKOUT_REAL/bin/lemon" ] || fail "use local links the checkout launcher"
[ "$(readlink "$VERSIONS/current")" = 2026.10.2 ] || fail "use local leaves versions/current for lemon update"
grep -q "^local $CHECKOUT_REAL " <<<"$("$LVM" current)" || fail "current reports the local checkout"
grep -q "^\* local  $CHECKOUT_REAL " <<<"$("$LVM" list)" || fail "list marks the local checkout"
ok "use local points the launcher at the checkout"

start_listener
: > "$LOG"
"$LVM" use 2026.10.1 >/dev/null
[ "$(cat "$LOG")" = $'local stop\nrelease-1 daemon' ] || fail "runtime is stopped by the old launcher and started by the new one: $(cat "$LOG")"
[ "$(readlink "$LAUNCHER")" = ../versions/current/bin/lemon ] || fail "leaving local restores the installer link"
[ "$(readlink "$VERSIONS/current")" = 2026.10.1 ] || fail "leaving local selects the requested release"
ok "a running runtime moves to the new selection"

start_listener
touch "$TEST_DIR/stop-fails"
: > "$LOG"
if "$LVM" use 2026.10.2 >/dev/null 2>&1; then fail "switch proceeds when the runtime cannot be stopped"; fi
[ "$(readlink "$VERSIONS/current")" = 2026.10.1 ] || fail "failed stop leaves the selection unchanged"
[ "$(cat "$LOG")" = "release-1 stop" ] || fail "failed stop starts nothing: $(cat "$LOG")"
rm "$TEST_DIR/stop-fails"
kill "$LISTENER_PID"; wait "$LISTENER_PID" 2>/dev/null || true
ok "a runtime that cannot be stopped blocks the switch"

: > "$LOG"
"$LVM" use 2026.10.1 >/dev/null
[ ! -s "$LOG" ] || fail "re-selecting the active release is a no-op"
if "$LVM" use 2099.01.0 2>/dev/null; then fail "use accepts a release that is not installed"; fi
if "$LVM" use ../escape 2>/dev/null; then fail "use accepts a path as a version"; fi
if "$LVM" use local "$TEST_DIR" 2>/dev/null; then fail "use local accepts a non-checkout"; fi
ok "invalid selections are refused"

"$LVM" use local >/dev/null
"$LVM" install 2026.11.0 >/dev/null
grep -qx 'install 2026.11.0 --skip-setup --no-modify-path' "$LOG" || fail "install pins the installer to the requested version"
[ "$("$LVM" current)" = 2026.11.0 ] || fail "install activates the installed release"
ok "install runs the checkout's installer and activates the release"

if "$LVM" uninstall 2026.11.0 2>/dev/null; then fail "uninstall removes versions/current"; fi
"$LVM" uninstall 2026.10.2 >/dev/null
[ ! -e "$VERSIONS/2026.10.2" ] || fail "uninstall removes an inactive release"
ok "uninstall only removes inactive releases"

rm "$LAUNCHER"
printf '#!/bin/sh\n' > "$LAUNCHER"
if "$LVM" use 2026.10.1 2>/dev/null; then fail "use replaces an unmanaged launcher"; fi
[ "$(cat "$LAUNCHER")" = '#!/bin/sh' ] || fail "unmanaged launcher is left untouched"
ok "an unmanaged launcher is never replaced"
