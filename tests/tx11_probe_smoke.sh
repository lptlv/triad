#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
triad="$root/src/triad"
probe="$root/src/triad_xlibre"
executor="$root/tests/tx11_live_executor"
client_src="$root/tests/tx11_synthetic_client.c"
client="$root/tests/tx11_synthetic_client"

if ! command -v Xvfb >/dev/null 2>&1; then
  printf '%s\n' "tx11_probe_smoke: Xvfb not found; skipping"
  exit 0
fi

if [ ! -x "$probe" ]; then
  printf '%s\n' "tx11_probe_smoke: probe binary missing: $probe" >&2
  exit 1
fi

if [ ! -x "$executor" ]; then
  printf '%s\n' "tx11_probe_smoke: live executor binary missing: $executor" >&2
  exit 1
fi

if [ ! -x "$triad" ]; then
  printf '%s\n' "tx11_probe_smoke: triad binary missing: $triad" >&2
  exit 1
fi

if ! command -v cc >/dev/null 2>&1; then
  printf '%s\n' "tx11_probe_smoke: cc not found; skipping"
  exit 0
fi

if ! command -v pkg-config >/dev/null 2>&1 || ! pkg-config --exists xcb; then
  printf '%s\n' "tx11_probe_smoke: xcb build flags unavailable; skipping"
  exit 0
fi

cc -Wall -Wextra -Werror -o "$client" "$client_src" $(pkg-config --cflags --libs xcb)

display=":73"
log="$root/tests/tx11-probe-smoke.log"
event_log="$root/tests/tx11-probe-smoke-events.log"
manager_log="$root/tests/tx11-probe-smoke-manager.log"
client_log="$root/tests/tx11-probe-smoke-client.log"
managed_client_log="$root/tests/tx11-probe-smoke-managed-client.log"
executor_log="$root/tests/tx11-probe-smoke-executor.log"
ipc_windows_log="$root/tests/tx11-probe-smoke-ipc-windows.json"
ipc_capabilities_log="$root/tests/tx11-probe-smoke-ipc-capabilities.json"
config="$root/tests/tx11-probe-smoke-config.kdl"
ipc_socket="$root/tests/tx11-probe-smoke.sock"
rm -f "$log" "$event_log" "$manager_log" "$client_log" "$managed_client_log" "$executor_log" "$ipc_windows_log" "$ipc_capabilities_log" "$config" "$ipc_socket"

Xvfb "$display" -screen 0 800x600x24 >"$log.xvfb" 2>&1 &
xvfb_pid="$!"
probe_pid=""
client_pid=""

cleanup() {
  if [ -n "$client_pid" ]; then
    kill "$client_pid" 2>/dev/null || true
    wait "$client_pid" 2>/dev/null || true
  fi
  if [ -n "$probe_pid" ]; then
    kill "$probe_pid" 2>/dev/null || true
    wait "$probe_pid" 2>/dev/null || true
  fi
  kill "$xvfb_pid" 2>/dev/null || true
  wait "$xvfb_pid" 2>/dev/null || true
  rm -f "$log" "$event_log" "$manager_log" "$client_log" "$managed_client_log" "$executor_log" "$ipc_windows_log" "$ipc_capabilities_log" "$log.xvfb" "$client" "$config" "$ipc_socket"
}

trap cleanup EXIT INT TERM

sleep 0.5

if ! "$probe" --display "$display" --once >"$log" 2>&1; then
  cat "$log" >&2
  exit 1
fi

for pattern in \
  "connected display=\"$display\"" \
  "atoms initialized" \
  "ewmh initialized" \
  "wm claimed" \
  "windows count=" \
  "backend_event OutputDiscovered" \
  "dry_run_msg WlOutput" \
  "probe complete once=true"; do
  if ! grep -q "$pattern" "$log"; then
    printf '%s\n' "tx11_probe_smoke: missing log pattern: $pattern" >&2
    cat "$log" >&2
    exit 1
  fi
done

"$probe" --display "$display" >"$event_log" 2>&1 &
probe_pid="$!"

started=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if grep -q "event loop started" "$event_log" 2>/dev/null; then
    started=1
    break
  fi
  sleep 0.2
done

if [ "$started" -ne 1 ]; then
  printf '%s\n' "tx11_probe_smoke: event loop did not start" >&2
  cat "$event_log" >&2
  exit 1
fi

"$client" "$display"

observed=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if grep -q "backend_event WindowDestroyed" "$event_log" 2>/dev/null; then
    observed=1
    break
  fi
  sleep 0.2
done

if [ "$observed" -ne 1 ]; then
  printf '%s\n' "tx11_probe_smoke: synthetic client events did not complete" >&2
  cat "$event_log" >&2
  exit 1
fi

for pattern in \
  "event MapRequest" \
  "backend_event MapRequested" \
  "dry_run_msg WlWindowCreated" \
  "dry_run_msg WlWindowDimensions" \
  "dry_run_msg WlWindowPid" \
  "event ConfigureRequest" \
  "backend_event ConfigureRequested" \
  "event PropertyNotify" \
  "backend_event PropertyChanged" \
  "dry_run_msg WlWindowTitle" \
  "dry_run_msg WlWindowStateChanged" \
  "event DestroyNotify" \
  "backend_event WindowDestroyed" \
  "dry_run_msg WlWindowDestroyed"; do
  if ! grep -q "$pattern" "$event_log"; then
    printf '%s\n' "tx11_probe_smoke: missing event log pattern: $pattern" >&2
    cat "$event_log" >&2
    exit 1
  fi
done

kill "$probe_pid" 2>/dev/null || true
wait "$probe_pid" 2>/dev/null || true
probe_pid=""
sleep 0.2

cat >"$config" <<'EOF'
layout {
  gaps 10
}

workspaces {
  default-count 3
}
EOF

"$probe" --display "$display" --mode manage --config "$config" --socket "$ipc_socket" >"$manager_log" 2>&1 &
probe_pid="$!"

started=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if grep -q "event loop started" "$manager_log" 2>/dev/null; then
    started=1
    break
  fi
  sleep 0.2
done

if [ "$started" -ne 1 ]; then
  printf '%s\n' "tx11_probe_smoke: manager loop did not start" >&2
  cat "$manager_log" >&2
  exit 1
fi

"$client" "$display" --managed-hold >"$managed_client_log" 2>&1 &
client_pid="$!"

managed_observed=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if grep -q "live_xcb applied map" "$manager_log" 2>/dev/null; then
    managed_observed=1
    break
  fi
  sleep 0.2
done

if [ "$managed_observed" -ne 1 ]; then
  printf '%s\n' "tx11_probe_smoke: manager did not map managed client" >&2
  cat "$manager_log" >&2
  cat "$managed_client_log" >&2
  exit 1
fi

for pattern in \
  "config loaded path=\"$config\"" \
  "ipc listening path=\"$ipc_socket\" mode=read-only" \
  "backend_event MapRequested" \
  "model_msg WlWindowCreated" \
  "layout_x11_request configure window=" \
  "live_xcb applied configure window=" \
  "x11_request map window=" \
  "live_xcb applied map window=" \
  "live_xcb applied focus window="; do
  if ! grep -q "$pattern" "$manager_log"; then
    printf '%s\n' "tx11_probe_smoke: missing manager log pattern: $pattern" >&2
    cat "$manager_log" >&2
    exit 1
  fi
done

if ! "$triad" msg --socket "$ipc_socket" windows >"$ipc_windows_log" 2>&1; then
  cat "$manager_log" >&2
  cat "$ipc_windows_log" >&2
  exit 1
fi

for pattern in \
  '"type":"windows"' \
  '"app_id":"triad-smoke/triad-smoke"'; do
  if ! grep -q "$pattern" "$ipc_windows_log"; then
    printf '%s\n' "tx11_probe_smoke: missing ipc windows pattern: $pattern" >&2
    cat "$ipc_windows_log" >&2
    exit 1
  fi
done

if ! "$triad" msg --socket "$ipc_socket" capabilities >"$ipc_capabilities_log" 2>&1; then
  cat "$manager_log" >&2
  cat "$ipc_capabilities_log" >&2
  exit 1
fi

if ! grep -q '"type":"capabilities"' "$ipc_capabilities_log"; then
  printf '%s\n' "tx11_probe_smoke: capabilities ipc reply missing type" >&2
  cat "$ipc_capabilities_log" >&2
  exit 1
fi

configured=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if grep -q '^configure=' "$managed_client_log" 2>/dev/null; then
    configured=1
    break
  fi
  sleep 0.2
done

if [ "$configured" -ne 1 ]; then
  printf '%s\n' "tx11_probe_smoke: managed client did not observe configure" >&2
  cat "$manager_log" >&2
  cat "$managed_client_log" >&2
  exit 1
fi

kill "$client_pid" 2>/dev/null || true
wait "$client_pid" 2>/dev/null || true
client_pid=""
kill "$probe_pid" 2>/dev/null || true
wait "$probe_pid" 2>/dev/null || true
probe_pid=""
sleep 0.2

"$client" "$display" --hold >"$client_log" 2>&1 &
client_pid="$!"

window_id=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if grep -q '^window=0x' "$client_log" 2>/dev/null; then
    window_id="$(sed -n 's/^window=//p' "$client_log" | head -n 1)"
    break
  fi
  sleep 0.2
done

if [ -z "$window_id" ]; then
  printf '%s\n' "tx11_probe_smoke: held synthetic client did not publish a window id" >&2
  cat "$client_log" >&2
  exit 1
fi

if ! "$executor" "$display" "$window_id" >"$executor_log" 2>&1; then
  cat "$executor_log" >&2
  exit 1
fi

closed=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if ! kill -0 "$client_pid" 2>/dev/null; then
    closed=1
    break
  fi
  sleep 0.2
done

if [ "$closed" -ne 1 ]; then
  printf '%s\n' "tx11_probe_smoke: held synthetic client did not close" >&2
  cat "$executor_log" >&2
  cat "$client_log" >&2
  exit 1
fi
wait "$client_pid" 2>/dev/null || true
client_pid=""

for pattern in \
  "applied configure window=$window_id" \
  "applied focus window=$window_id" \
  "applied close window=$window_id" \
  "request execution complete dry_run=0 count=3"; do
  if ! grep -q "$pattern" "$executor_log"; then
    printf '%s\n' "tx11_probe_smoke: missing executor log pattern: $pattern" >&2
    cat "$executor_log" >&2
    exit 1
  fi
done

printf '%s\n' "tx11_probe_smoke: pass"
