#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
triad="$root/src/triad"
probe="$root/src/triad_xlibre"
executor="$root/tests/tx11_live_executor"
client_src="$root/tests/tx11_synthetic_client.c"
client="$root/tests/tx11_synthetic_client"
display="${TRIAD_X11_DISPLAY:-:73}"
external_display="${TRIAD_X11_EXTERNAL_DISPLAY:-0}"

case "$external_display" in
  1|true|TRUE|yes|YES|on|ON)
    external_display=1
    ;;
  *)
    external_display=0
    ;;
esac

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

log="$root/tests/tx11-probe-smoke.log"
event_log="$root/tests/tx11-probe-smoke-events.log"
manager_log="$root/tests/tx11-probe-smoke-manager.log"
client_log="$root/tests/tx11-probe-smoke-client.log"
managed_client_log="$root/tests/tx11-probe-smoke-managed-client.log"
executor_log="$root/tests/tx11-probe-smoke-executor.log"
ipc_windows_log="$root/tests/tx11-probe-smoke-ipc-windows.json"
ipc_capabilities_log="$root/tests/tx11-probe-smoke-ipc-capabilities.json"
ipc_status_log="$root/tests/tx11-probe-smoke-ipc-status.json"
ipc_focus_log="$root/tests/tx11-probe-smoke-ipc-focus.json"
ipc_focus_workspace_log="$root/tests/tx11-probe-smoke-ipc-focus-workspace.json"
ipc_move_workspace_log="$root/tests/tx11-probe-smoke-ipc-move-workspace.json"
ipc_close_log="$root/tests/tx11-probe-smoke-ipc-close.json"
ipc_stop_log="$root/tests/tx11-probe-smoke-ipc-stop.json"
config="$root/tests/tx11-probe-smoke-config.kdl"
ipc_socket="$root/tests/tx11-probe-smoke.sock"
rm -f "$log" "$event_log" "$manager_log" "$client_log" "$managed_client_log" "$executor_log" "$ipc_windows_log" "$ipc_capabilities_log" "$ipc_status_log" "$ipc_focus_log" "$ipc_focus_workspace_log" "$ipc_move_workspace_log" "$ipc_close_log" "$ipc_stop_log" "$config" "$ipc_socket"

xvfb_pid=""
if [ "$external_display" -eq 0 ]; then
  if ! command -v Xvfb >/dev/null 2>&1; then
    printf '%s\n' "tx11_probe_smoke: Xvfb not found; skipping"
    exit 0
  fi
  Xvfb "$display" -screen 0 800x600x24 >"$log.xvfb" 2>&1 &
  xvfb_pid="$!"
fi
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
  if [ -n "$xvfb_pid" ]; then
    kill "$xvfb_pid" 2>/dev/null || true
    wait "$xvfb_pid" 2>/dev/null || true
  fi
  rm -f "$log" "$event_log" "$manager_log" "$client_log" "$managed_client_log" "$executor_log" "$ipc_windows_log" "$ipc_capabilities_log" "$ipc_status_log" "$ipc_focus_log" "$ipc_focus_workspace_log" "$ipc_move_workspace_log" "$ipc_close_log" "$ipc_stop_log" "$log.xvfb" "$client" "$config" "$ipc_socket"
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
  "xkb version=" \
  "xinput version=" \
  "xinput devices count=" \
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

root_event_observed=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if grep -q "backend_event PropertyChanged" "$event_log" 2>/dev/null; then
    root_event_observed=1
    break
  fi
  sleep 0.2
done

if [ "$root_event_observed" -ne 1 ]; then
  printf '%s\n' "tx11_probe_smoke: observe loop did not receive root property events" >&2
  cat "$event_log" >&2
  exit 1
fi

for pattern in \
  "event PropertyNotify" \
  "backend_event PropertyChanged"; do
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
  '"app_id":"triad-smoke"'; do
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

if ! "$triad" msg --socket "$ipc_socket" request '{"triad":{"version":1,"request":"runtime-status"}}' >"$ipc_status_log" 2>&1; then
  cat "$manager_log" >&2
  cat "$ipc_status_log" >&2
  exit 1
fi

for pattern in \
  '"type":"runtime-status"' \
  '"backend":"xlibre"' \
  '"mode":"manage"' \
  '"socket_path":"'"$ipc_socket"'"' \
  '"writable_ipc":false' \
  '"window_count":1' \
  '"output_count":1'; do
  if ! grep -q "$pattern" "$ipc_status_log"; then
    printf '%s\n' "tx11_probe_smoke: missing runtime status pattern: $pattern" >&2
    cat "$ipc_status_log" >&2
    exit 1
  fi
done

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

managed_window_id="$(sed -n 's/^window=//p' "$managed_client_log" | head -n 1)"
if [ -z "$managed_window_id" ]; then
  printf '%s\n' "tx11_probe_smoke: managed client did not publish a window id" >&2
  cat "$managed_client_log" >&2
  exit 1
fi
managed_window_dec="$(printf '%d' "$managed_window_id")"
focus_payload='{"triad":{"version":1,"request":"xlibre-focus-window","id":'"$managed_window_dec"'}}'
if ! "$triad" msg --socket "$ipc_socket" request "$focus_payload" >"$ipc_focus_log" 2>&1; then
  cat "$manager_log" >&2
  cat "$ipc_focus_log" >&2
  exit 1
fi

for pattern in \
  '"type":"xlibre-focus-window"' \
  '"applied":true'; do
  if ! grep -q "$pattern" "$ipc_focus_log"; then
    printf '%s\n' "tx11_probe_smoke: missing ipc focus pattern: $pattern" >&2
    cat "$ipc_focus_log" >&2
    exit 1
  fi
done

focus_workspace_payload='{"triad":{"version":1,"request":"xlibre-focus-workspace","workspace":1}}'
if ! "$triad" msg --socket "$ipc_socket" request "$focus_workspace_payload" >"$ipc_focus_workspace_log" 2>&1; then
  cat "$manager_log" >&2
  cat "$ipc_focus_workspace_log" >&2
  exit 1
fi

for pattern in \
  '"type":"xlibre-focus-workspace"' \
  '"workspace":1' \
  '"applied":true'; do
  if ! grep -q "$pattern" "$ipc_focus_workspace_log"; then
    printf '%s\n' "tx11_probe_smoke: missing ipc focus workspace pattern: $pattern" >&2
    cat "$ipc_focus_workspace_log" >&2
    exit 1
  fi
done

move_workspace_payload='{"triad":{"version":1,"request":"xlibre-move-window-to-workspace","id":'"$managed_window_dec"',"workspace":2}}'
if ! "$triad" msg --socket "$ipc_socket" request "$move_workspace_payload" >"$ipc_move_workspace_log" 2>&1; then
  cat "$manager_log" >&2
  cat "$ipc_move_workspace_log" >&2
  exit 1
fi

for pattern in \
  '"type":"xlibre-move-window-to-workspace"' \
  '"window":'"$managed_window_dec" \
  '"workspace":2' \
  '"follow":true' \
  '"applied":true'; do
  if ! grep -q "$pattern" "$ipc_move_workspace_log"; then
    printf '%s\n' "tx11_probe_smoke: missing ipc move workspace pattern: $pattern" >&2
    cat "$ipc_move_workspace_log" >&2
    exit 1
  fi
done

close_payload='{"triad":{"version":1,"request":"xlibre-close-window","id":'"$managed_window_dec"'}}'
if ! "$triad" msg --socket "$ipc_socket" request "$close_payload" >"$ipc_close_log" 2>&1; then
  cat "$manager_log" >&2
  cat "$ipc_close_log" >&2
  exit 1
fi

for pattern in \
  '"type":"xlibre-close-window"' \
  '"applied":true'; do
  if ! grep -q "$pattern" "$ipc_close_log"; then
    printf '%s\n' "tx11_probe_smoke: missing ipc close pattern: $pattern" >&2
    cat "$ipc_close_log" >&2
    exit 1
  fi
done

managed_closed=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if ! kill -0 "$client_pid" 2>/dev/null; then
    managed_closed=1
    break
  fi
  sleep 0.2
done

if [ "$managed_closed" -ne 1 ]; then
  printf '%s\n' "tx11_probe_smoke: managed client did not close from xlibre ipc" >&2
  cat "$manager_log" >&2
  cat "$managed_client_log" >&2
  cat "$ipc_close_log" >&2
  exit 1
fi
wait "$client_pid" 2>/dev/null || true
client_pid=""

stop_payload='{"triad":{"version":1,"request":"xlibre-stop"}}'
if ! "$triad" msg --socket "$ipc_socket" request "$stop_payload" >"$ipc_stop_log" 2>&1; then
  cat "$manager_log" >&2
  cat "$ipc_stop_log" >&2
  exit 1
fi

for pattern in \
  '"type":"xlibre-stop"' \
  '"applied":true'; do
  if ! grep -q "$pattern" "$ipc_stop_log"; then
    printf '%s\n' "tx11_probe_smoke: missing ipc stop pattern: $pattern" >&2
    cat "$ipc_stop_log" >&2
    exit 1
  fi
done

manager_stopped=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if ! kill -0 "$probe_pid" 2>/dev/null; then
    manager_stopped=1
    break
  fi
  sleep 0.2
done

if [ "$manager_stopped" -ne 1 ]; then
  printf '%s\n' "tx11_probe_smoke: manager did not stop from xlibre ipc" >&2
  cat "$manager_log" >&2
  cat "$ipc_stop_log" >&2
  exit 1
fi
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
