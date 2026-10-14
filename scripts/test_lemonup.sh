#!/usr/bin/env bash
# Regression checks for bin/lemonup against a throwaway HOME, fake releases and
# a fake checkout. Launchers are stubs that log which root handled each command.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lemon-lemonup.XXXXXX")"
LISTENER_PID=""

cleanup() {
  if [[ "$LISTENER_PID" =~ ^[0-9]+$ ]] && kill -0 "$LISTENER_PID" 2>/dev/null; then
    kill "$LISTENER_PID" 2>/dev/null || true
    wait "$LISTENER_PID" 2>/dev/null || true
  fi
  if [[ "$TEST_DIR" == "${TMPDIR:-/tmp}"/lemon-lemonup.* ]]; then
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

# stub_checkout <dir>: a Lemon umbrella shape with a stub source launcher.
stub_checkout() {
  mkdir -p "$1/apps/lemon_cli"
  touch "$1/mix.exs"
  stub_launcher "$1/bin/lemon" "$2"
}

stub_launcher "$VERSIONS/2026.10.1/bin/lemon" release-1
stub_launcher "$VERSIONS/2026.10.2/bin/lemon" release-2
stub_launcher "$TEST_DIR/installed-launcher" installed
mkdir -p "$HOME/.lemon/bin"
ln -s 2026.10.1 "$VERSIONS/current"
ln -s ../versions/current/bin/lemon "$LAUNCHER"

CHECKOUT="$TEST_DIR/checkout"
stub_checkout "$CHECKOUT" local
cp "$ROOT/bin/lemonup" "$CHECKOUT/bin/lemonup"
# The installer stub resolves "latest" from $TEST_DIR/latest and, like the real
# one, flips versions/current and bin/lemon only after a successful install.
printf '2026.11.0\n' > "$TEST_DIR/latest"
cat > "$CHECKOUT/install.sh" <<EOF
#!/bin/sh
if [ "\${1:-}" = --resolve-version ]; then
  printf 'resolve %s %s\n' "\${LEMON_VERSION:-latest}" "\${LEMON_CHANNEL:-stable}" >> "$LOG"
  [ ! -e "$TEST_DIR/resolve-fails" ] || exit 1
  cat "$TEST_DIR/latest"
  exit 0
fi
printf 'install %s %s\n' "\${LEMON_VERSION:-latest}" "\$*" >> "$LOG"
[ ! -e "$TEST_DIR/install-fails" ] || exit 1
version="\${LEMON_VERSION:-\$(cat "$TEST_DIR/latest")}"
mkdir -p "$VERSIONS/\$version/bin"
cp "$TEST_DIR/installed-launcher" "$VERSIONS/\$version/bin/lemon"
ln -sfn "\$version" "$VERSIONS/current"
ln -sfn ../versions/current/bin/lemon "$LAUNCHER"
EOF
LEMONUP="$CHECKOUT/bin/lemonup"
CHECKOUT_REAL="$(cd "$CHECKOUT" && pwd -P)"

start_listener() {
  python3 -c 'import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(); time.sleep(600)' "$PORT" &
  LISTENER_PID=$!
  printf '%s\n' "$LISTENER_PID" > "$TEST_DIR/listener.pid"
  until (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; do sleep 0.05; done
}

stop_listener() {
  kill "$LISTENER_PID" 2>/dev/null || true
  wait "$LISTENER_PID" 2>/dev/null || true
}

[ "$("$LEMONUP" current)" = 2026.10.1 ] || fail "current reports the installer's release"
listing="$("$LEMONUP" list)"
grep -qx '\* 2026.10.1' <<<"$listing" || fail "list marks the active release"
grep -qx '  2026.10.2' <<<"$listing" || fail "list shows the inactive release"
ok "list and current read the installer layout"

"$LEMONUP" use 2026.10.2 >/dev/null
[ "$(readlink "$VERSIONS/current")" = 2026.10.2 ] || fail "use <version> flips versions/current"
[ "$(readlink "$LAUNCHER")" = ../versions/current/bin/lemon ] || fail "release launcher link stays canonical"
[ ! -s "$LOG" ] || fail "no launcher runs when nothing listens on the control port"
ok "use <version> flips only versions/current"

"$LEMONUP" use local >/dev/null
[ "$(readlink "$LAUNCHER")" = "$CHECKOUT_REAL/bin/lemon" ] || fail "use local links the checkout launcher"
[ "$(readlink "$VERSIONS/current")" = 2026.10.2 ] || fail "use local leaves versions/current for lemon update"
grep -q "^local $CHECKOUT_REAL " <<<"$("$LEMONUP" current)" || fail "current reports the local checkout"
grep -q "^\* local  $CHECKOUT_REAL " <<<"$("$LEMONUP" list)" || fail "list marks the local checkout"
ok "use local points the launcher at the checkout"

start_listener
: > "$LOG"
"$LEMONUP" use 2026.10.1 >/dev/null
[ "$(cat "$LOG")" = $'local stop\nrelease-1 daemon' ] || fail "runtime is stopped by the old launcher and started by the new one: $(cat "$LOG")"
[ "$(readlink "$LAUNCHER")" = ../versions/current/bin/lemon ] || fail "leaving local restores the installer link"
[ "$(readlink "$VERSIONS/current")" = 2026.10.1 ] || fail "leaving local selects the requested release"
ok "a running runtime moves to the new selection"

start_listener
touch "$TEST_DIR/stop-fails"
: > "$LOG"
if "$LEMONUP" use 2026.10.2 >/dev/null 2>&1; then fail "switch proceeds when the runtime cannot be stopped"; fi
[ "$(readlink "$VERSIONS/current")" = 2026.10.1 ] || fail "failed stop leaves the selection unchanged"
[ "$(cat "$LOG")" = "release-1 stop" ] || fail "failed stop starts nothing: $(cat "$LOG")"
rm "$TEST_DIR/stop-fails"
stop_listener
ok "a runtime that cannot be stopped blocks the switch"

: > "$LOG"
"$LEMONUP" use 2026.10.1 >/dev/null
[ ! -s "$LOG" ] || fail "re-selecting the active release is a no-op"
if "$LEMONUP" use 2099.01.0 2>/dev/null; then fail "use accepts a release that is not installed"; fi
if "$LEMONUP" use ../escape 2>/dev/null; then fail "use accepts a path as a version"; fi
if "$LEMONUP" use local "$TEST_DIR" 2>/dev/null; then fail "use local accepts a non-checkout"; fi
ok "invalid selections are refused"

"$LEMONUP" use local >/dev/null
"$LEMONUP" install 2026.11.0 >/dev/null
grep -qx 'install 2026.11.0 --skip-setup --no-modify-path' "$LOG" || fail "install pins the installer to the requested version"
[ "$("$LEMONUP" current)" = 2026.11.0 ] || fail "install activates the installed release"
ok "install runs the checkout's installer and activates the release"

if "$LEMONUP" uninstall 2026.11.0 2>/dev/null; then fail "uninstall removes versions/current"; fi
"$LEMONUP" uninstall 2026.10.2 >/dev/null
[ ! -e "$VERSIONS/2026.10.2" ] || fail "uninstall removes an inactive release"
ok "uninstall only removes inactive releases"

# update: latest is 2026.11.0, which is installed and active.
start_listener
: > "$LOG"
LEMON_VERSION=2026.10.1 LEMON_CHANNEL=preview "$LEMONUP" update > "$TEST_DIR/update.out"
grep -q 'already using the latest stable release, 2026.11.0' "$TEST_DIR/update.out" || fail "update reports an active latest release"
[ "$(cat "$LOG")" = "resolve latest stable" ] || fail "update resolves unpinned stable and does nothing else when already current: $(cat "$LOG")"
stop_listener
ok "update is a no-op when the latest release is already active"

"$LEMONUP" use 2026.10.1 >/dev/null
start_listener
: > "$LOG"
"$LEMONUP" update >/dev/null
[ "$(cat "$LOG")" = $'resolve latest stable\nrelease-1 stop\ninstalled daemon' ] || fail "update activates an installed latest without installing: $(cat "$LOG")"
[ "$("$LEMONUP" current)" = 2026.11.0 ] || fail "update activates the installed latest release"
ok "update activates an installed but inactive latest release"

printf '2026.12.0\n' > "$TEST_DIR/latest"
"$LEMONUP" use 2026.10.1 >/dev/null
start_listener
touch "$TEST_DIR/stop-fails"
: > "$LOG"
if "$LEMONUP" update >/dev/null 2>&1; then fail "update proceeds when the runtime cannot be stopped"; fi
[ "$(cat "$LOG")" = $'resolve latest stable\nrelease-1 stop' ] || fail "failed stop installs and starts nothing: $(cat "$LOG")"
[ "$("$LEMONUP" current)" = 2026.10.1 ] || fail "failed stop leaves the selection unchanged"
[ ! -e "$VERSIONS/2026.12.0" ] || fail "failed stop installs nothing"
rm "$TEST_DIR/stop-fails"
stop_listener
ok "a runtime that cannot be stopped blocks update"

touch "$TEST_DIR/resolve-fails"
: > "$LOG"
if "$LEMONUP" update >/dev/null 2>&1; then fail "update succeeds when the latest release cannot be resolved"; fi
[ "$(cat "$LOG")" = "resolve latest stable" ] || fail "failed resolution touches nothing: $(cat "$LOG")"
rm "$TEST_DIR/resolve-fails"
ok "update fails cleanly when the latest release cannot be resolved"

"$LEMONUP" use local >/dev/null
start_listener
touch "$TEST_DIR/install-fails"
: > "$LOG"
if "$LEMONUP" update >/dev/null 2>&1; then fail "update succeeds when the install fails"; fi
[ "$(cat "$LOG")" = $'resolve latest stable\nlocal stop\ninstall 2026.12.0 --skip-setup --no-modify-path\nlocal daemon' ] ||
  fail "failed install restarts the runtime on the old selection: $(cat "$LOG")"
[ "$(readlink "$LAUNCHER")" = "$CHECKOUT_REAL/bin/lemon" ] || fail "failed install leaves the local launcher"
[ "$(readlink "$VERSIONS/current")" = 2026.10.1 ] || fail "failed install leaves versions/current"
rm "$TEST_DIR/install-fails"
ok "a failed install leaves the selection unchanged"

start_listener
: > "$LOG"
"$LEMONUP" update >/dev/null
[ "$(cat "$LOG")" = $'resolve latest stable\nlocal stop\ninstall 2026.12.0 --skip-setup --no-modify-path\ninstalled daemon' ] ||
  fail "update from local installs the pinned latest and restarts on it: $(cat "$LOG")"
[ "$(readlink "$LAUNCHER")" = ../versions/current/bin/lemon ] || fail "update from local restores the installer link"
[ "$("$LEMONUP" current)" = 2026.12.0 ] || fail "update from local activates the latest release"
ok "update from local installs and activates the latest release"

# A launcher written before the rename: an absolute link to another
# checkout's bin/lemon, exactly the shape `use local` writes.
LEGACY="$TEST_DIR/legacy checkout"
stub_checkout "$LEGACY" legacy
LEGACY_REAL="$(cd "$LEGACY" && pwd -P)"
ln -sfn "$LEGACY_REAL/bin/lemon" "$LAUNCHER"
grep -q "^local $LEGACY_REAL " <<<"$("$LEMONUP" current)" || fail "current recognizes an earlier local link"
grep -q "^\* local  $LEGACY_REAL " <<<"$("$LEMONUP" list)" || fail "list marks an earlier local link"
start_listener
: > "$LOG"
"$LEMONUP" update >/dev/null
[ "$(cat "$LOG")" = $'resolve latest stable\nlegacy stop\ninstalled daemon' ] || fail "update leaves an earlier local link through its own launcher: $(cat "$LOG")"
[ "$("$LEMONUP" current)" = 2026.12.0 ] || fail "update switches an earlier local link to the latest release"
ok "a local launcher linked before the rename is managed"

rm "$LAUNCHER"
printf '#!/bin/sh\n' > "$LAUNCHER"
if "$LEMONUP" use 2026.10.1 2>/dev/null; then fail "use replaces an unmanaged launcher"; fi
if "$LEMONUP" update 2>/dev/null; then fail "update replaces an unmanaged launcher"; fi
[ "$(cat "$LAUNCHER")" = '#!/bin/sh' ] || fail "unmanaged launcher is left untouched"
ok "an unmanaged launcher is never replaced"
