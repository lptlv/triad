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

if ! command -v pkg-config >/dev/null 2>&1 || ! pkg-config --exists xcb xcb-xkb; then
  printf '%s\n' "tx11_probe_smoke: xcb build flags unavailable; skipping"
  exit 0
fi

xtest_available=0
xtest_cflags=""
xtest_libs=""
if pkg-config --exists xcb-xtest; then
  xtest_available=1
  xtest_cflags="$(pkg-config --cflags xcb-xtest) -DTRIAD_X11_XTEST=1"
  xtest_libs="$(pkg-config --libs xcb-xtest)"
fi
x11_mod_shift=1
x11_mod_super=64
x11_mod_super_shift=$((x11_mod_super | x11_mod_shift))

cc -Wall -Wextra -Werror -o "$client" "$client_src" \
  $(pkg-config --cflags xcb xcb-xkb) $xtest_cflags \
  $(pkg-config --libs xcb xcb-xkb) $xtest_libs

log="$root/tests/tx11-probe-smoke.log"
event_log="$root/tests/tx11-probe-smoke-events.log"
manager_log="$root/tests/tx11-probe-smoke-manager.log"
client_log="$root/tests/tx11-probe-smoke-client.log"
managed_client_log="$root/tests/tx11-probe-smoke-managed-client.log"
close_key_client_log="$root/tests/tx11-probe-smoke-close-key-client.log"
focus_next_a_client_log="$root/tests/tx11-probe-smoke-focus-next-a-client.log"
focus_next_b_client_log="$root/tests/tx11-probe-smoke-focus-next-b-client.log"
executor_log="$root/tests/tx11-probe-smoke-executor.log"
ipc_windows_log="$root/tests/tx11-probe-smoke-ipc-windows.json"
ipc_capabilities_log="$root/tests/tx11-probe-smoke-ipc-capabilities.json"
ipc_status_log="$root/tests/tx11-probe-smoke-ipc-status.json"
ipc_focus_log="$root/tests/tx11-probe-smoke-ipc-focus.json"
ipc_focus_workspace_log="$root/tests/tx11-probe-smoke-ipc-focus-workspace.json"
ipc_binding_dispatch_log="$root/tests/tx11-probe-smoke-ipc-binding-dispatch.json"
key_press_log="$root/tests/tx11-probe-smoke-key-press.log"
shifted_key_press_log="$root/tests/tx11-probe-smoke-shifted-key-press.log"
close_key_press_log="$root/tests/tx11-probe-smoke-close-key-press.log"
focus_next_press_log="$root/tests/tx11-probe-smoke-focus-next-press.log"
maximize_column_press_log="$root/tests/tx11-probe-smoke-maximize-column-press.log"
maximize_edges_press_log="$root/tests/tx11-probe-smoke-maximize-edges-press.log"
fullscreen_press_log="$root/tests/tx11-probe-smoke-fullscreen-press.log"
layout_scroller_press_log="$root/tests/tx11-probe-smoke-layout-scroller-press.log"
vertical_scroller_press_log="$root/tests/tx11-probe-smoke-vertical-scroller-press.log"
switch_layout_press_log="$root/tests/tx11-probe-smoke-switch-layout-press.log"
spawn_press_log="$root/tests/tx11-probe-smoke-spawn-press.log"
spawn_terminal_press_log="$root/tests/tx11-probe-smoke-spawn-terminal-press.log"
button_press_log="$root/tests/tx11-probe-smoke-button-press.log"
back_button_press_log="$root/tests/tx11-probe-smoke-back-button-press.log"
device_button_press_log="$root/tests/tx11-probe-smoke-device-button-press.log"
mapping_notify_log="$root/tests/tx11-probe-smoke-mapping-notify.log"
xkb_state_log="$root/tests/tx11-probe-smoke-xkb-state.log"
axis_press_log="$root/tests/tx11-probe-smoke-axis-press.log"
pointer_drag_log="$root/tests/tx11-probe-smoke-pointer-drag.log"
pointer_resize_log="$root/tests/tx11-probe-smoke-pointer-resize.log"
ipc_move_workspace_log="$root/tests/tx11-probe-smoke-ipc-move-workspace.json"
ipc_close_log="$root/tests/tx11-probe-smoke-ipc-close.json"
ipc_stop_log="$root/tests/tx11-probe-smoke-ipc-stop.json"
config="$root/tests/tx11-probe-smoke-config.kdl"
ipc_socket="$root/tests/tx11-probe-smoke.sock"
spawn_marker="$root/tests/tx11-probe-smoke-spawn-marker"
spawn_terminal_marker="$root/tests/tx11-probe-smoke-spawn-terminal-marker"
rm -f "$log" "$event_log" "$manager_log" "$client_log" "$managed_client_log" "$close_key_client_log" "$focus_next_a_client_log" "$focus_next_b_client_log" "$executor_log" "$ipc_windows_log" "$ipc_capabilities_log" "$ipc_status_log" "$ipc_focus_log" "$ipc_focus_workspace_log" "$ipc_binding_dispatch_log" "$key_press_log" "$shifted_key_press_log" "$close_key_press_log" "$focus_next_press_log" "$maximize_column_press_log" "$maximize_edges_press_log" "$fullscreen_press_log" "$layout_scroller_press_log" "$vertical_scroller_press_log" "$switch_layout_press_log" "$spawn_press_log" "$spawn_terminal_press_log" "$button_press_log" "$back_button_press_log" "$device_button_press_log" "$mapping_notify_log" "$xkb_state_log" "$axis_press_log" "$pointer_drag_log" "$pointer_resize_log" "$ipc_move_workspace_log" "$ipc_close_log" "$ipc_stop_log" "$config" "$ipc_socket" "$spawn_marker" "$spawn_terminal_marker"

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
focus_next_a_pid=""
focus_next_b_pid=""

cleanup() {
  if [ -n "$client_pid" ]; then
    kill "$client_pid" 2>/dev/null || true
    wait "$client_pid" 2>/dev/null || true
  fi
  if [ -n "$focus_next_a_pid" ]; then
    kill "$focus_next_a_pid" 2>/dev/null || true
    wait "$focus_next_a_pid" 2>/dev/null || true
  fi
  if [ -n "$focus_next_b_pid" ]; then
    kill "$focus_next_b_pid" 2>/dev/null || true
    wait "$focus_next_b_pid" 2>/dev/null || true
  fi
  if [ -n "$probe_pid" ]; then
    kill "$probe_pid" 2>/dev/null || true
    wait "$probe_pid" 2>/dev/null || true
  fi
  if [ -n "$xvfb_pid" ]; then
    kill "$xvfb_pid" 2>/dev/null || true
    wait "$xvfb_pid" 2>/dev/null || true
  fi
  rm -f "$log" "$event_log" "$manager_log" "$client_log" "$managed_client_log" "$close_key_client_log" "$focus_next_a_client_log" "$focus_next_b_client_log" "$executor_log" "$ipc_windows_log" "$ipc_capabilities_log" "$ipc_status_log" "$ipc_focus_log" "$ipc_focus_workspace_log" "$ipc_binding_dispatch_log" "$key_press_log" "$shifted_key_press_log" "$close_key_press_log" "$focus_next_press_log" "$maximize_column_press_log" "$maximize_edges_press_log" "$fullscreen_press_log" "$layout_scroller_press_log" "$vertical_scroller_press_log" "$switch_layout_press_log" "$spawn_press_log" "$spawn_terminal_press_log" "$button_press_log" "$back_button_press_log" "$device_button_press_log" "$mapping_notify_log" "$xkb_state_log" "$axis_press_log" "$pointer_drag_log" "$pointer_resize_log" "$ipc_move_workspace_log" "$ipc_close_log" "$ipc_stop_log" "$log.xvfb" "$client" "$config" "$ipc_socket" "$spawn_marker" "$spawn_terminal_marker"
}

trap cleanup EXIT INT TERM

sleep 0.5

if ! "$probe" --display "$display" --trace-xinput-motion --once >"$log" 2>&1; then
  cat "$log" >&2
  exit 1
fi

for pattern in \
  "connected display=\"$display\"" \
  "atoms initialized" \
  "ewmh initialized" \
  "wm claimed" \
  "xkb version=" \
  "xinput config mouse(natural_set=0 natural=0 factor_milli=1000)" \
  "xinput version=" \
  "xinput devices count=" \
  "xinput motion events selected" \
  "scroll_axes=" \
  "cached_scroll_axes=" \
  "gesture_class=" \
  "windows count=" \
  "backend_event OutputDiscovered" \
  "dry_run_msg Output" \
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

cat >"$config" <<EOF
layout {
  gaps 10
}

workspaces {
  default-count 3
}

terminal {
  command "touch" "$spawn_terminal_marker"
}

input {
  mouse {
    natural-scroll #true
    scroll-factor 1.5
  }
  touchpad {
    natural-scroll #true
    scroll-factor 0.5
  }
  trackball {
    scroll-factor 0.75
  }
}

window-rule {
  match app-id="triad-smoke"
  open-floating #true
  floating {
    width 320
    height 200
  }
}

bindings {
  bind "Super+h" "focus-workspace 1"
  bind "Super+q" "close-window"
  bind "Super+Tab" "focus-next"
  bind "Super+m" "maximize-column"
  bind "Super+f" "maximize-window-to-edges"
  bind "Super+Shift+f" "fullscreen-window"
  bind "Super+c" "scroller"
  bind "Super+v" "vertical-scroller"
  bind "Super+n" "switch-layout"
  bind "Super+x" "spawn touch $spawn_marker"
  bind "Super+t" "spawn-terminal"
  bind "Super+Question" "focus-workspace 1"
  pointer-bind "Super+left" "move"
  pointer-bind "Super+right" "resize"
  pointer-bind "Super+middle" "focus-workspace 2"
  pointer-bind "Super+btn_back" "focus-workspace 2"
  pointer-bind "Super+button10" "focus-workspace 2"
  axis-bind "Super+wheel-up" "focus-workspace 3"
  gesture-bind "Super+swipe-left" "focus-workspace 4" fingers=3
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

if ! "$client" "$display" --send-mapping-notify >"$mapping_notify_log" 2>&1; then
  cat "$manager_log" >&2
  cat "$mapping_notify_log" >&2
  exit 1
fi

mapping_refresh_observed=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if grep -q 'backend_event MappingChanged' "$manager_log" &&
      grep -q 'xlibre_input_grabs invalidated reason=mapping-changed' "$manager_log"; then
    mapping_refresh_observed=1
    break
  fi
  sleep 0.2
done

if [ "$mapping_refresh_observed" -ne 1 ]; then
  printf '%s\n' "tx11_probe_smoke: mapping notify did not invalidate input grabs" >&2
  cat "$manager_log" >&2
  cat "$mapping_notify_log" >&2
  exit 1
fi

if ! "$client" "$display" --send-xkb-state >"$xkb_state_log" 2>&1; then
  cat "$manager_log" >&2
  cat "$xkb_state_log" >&2
  exit 1
fi

xkb_refresh_observed=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if grep -q 'backend_event XkbChanged' "$manager_log" &&
      grep -q 'xlibre_input_grabs invalidated reason=xkb-changed' "$manager_log"; then
    xkb_refresh_observed=1
    break
  fi
  sleep 0.2
done

if [ "$xkb_refresh_observed" -ne 1 ]; then
  printf '%s\n' "tx11_probe_smoke: XKB state change did not invalidate input grabs" >&2
  cat "$manager_log" >&2
  cat "$xkb_state_log" >&2
  exit 1
fi

for pattern in \
  "config loaded path=\"$config\"" \
  "ipc listening path=\"$ipc_socket\" mode=read-only" \
  "xinput config mouse(natural_set=1 natural=1 factor_milli=1500)" \
  "touchpad(natural_set=1 natural=1 factor_milli=500)" \
  "trackball(natural_set=0 natural=0 factor_milli=750)" \
  "key grabs configured count=" \
  "xlibre_key_grabs requested=" \
  "button grabs configured count=" \
  "xlibre_button_grabs requested=" \
  "axis grabs configured count=" \
  "xlibre_axis_grabs requested=" \
  "gesture grabs configured count=" \
  "xlibre_gesture_grabs requested=" \
  "xinput motion events selected" \
  "backend_event MapRequested" \
  "model_msg WindowCreated" \
  "model_msg WindowParentedRoleHint" \
  "layout_x11_request configure window=" \
  "live_xcb applied configure window=" \
  "x11_request map window=" \
  "live_xcb applied map window=" \
  "live_xcb applied focus window=" \
  "live_xcb applied take-focus window="; do
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
  '"writable_ipc":true' \
  '"binding_dispatch_ipc":true' \
  '"general_command_ipc":false' \
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

if ! "$triad" msg --socket "$ipc_socket" dispatch-binding key Super+h >"$ipc_binding_dispatch_log" 2>&1; then
  cat "$manager_log" >&2
  cat "$ipc_binding_dispatch_log" >&2
  exit 1
fi

for pattern in \
  '"type":"xlibre-binding-dispatch"' \
  '"kind":"key"' \
  '"binding":"Super+h"' \
  '"command":"focus-workspace 1"' \
  '"dispatched":1' \
  '"applied":true'; do
  if ! grep -q "$pattern" "$ipc_binding_dispatch_log"; then
    printf '%s\n' "tx11_probe_smoke: missing ipc binding dispatch pattern: $pattern" >&2
    cat "$ipc_binding_dispatch_log" >&2
    exit 1
  fi
done

if [ "$xtest_available" -eq 1 ]; then
  if ! "$client" "$display" --fake-key 0x68 "$x11_mod_super" >"$key_press_log" 2>&1; then
    cat "$manager_log" >&2
    cat "$key_press_log" >&2
    exit 1
  fi

  key_dispatched=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if grep -q 'backend_event KeyBinding binding="Super+h"' "$manager_log" &&
        grep -q 'xlibre_key_binding_reply .*"type":"xlibre-binding-dispatch"' "$manager_log"; then
      key_dispatched=1
      break
    fi
    sleep 0.2
  done
  if [ "$key_dispatched" -ne 1 ]; then
    printf '%s\n' "tx11_probe_smoke: fake Super+h did not dispatch through key grab" >&2
    cat "$manager_log" >&2
    cat "$key_press_log" >&2
    exit 1
  fi

  if ! "$client" "$display" --fake-key 0x2f "$x11_mod_super_shift" >"$shifted_key_press_log" 2>&1; then
    cat "$manager_log" >&2
    cat "$shifted_key_press_log" >&2
    exit 1
  fi

  shifted_key_dispatched=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if grep -q 'backend_event KeyBinding binding="Super+Question"' "$manager_log" &&
        grep -q 'xlibre_key_binding_reply .*"binding":"Super+Question"' "$manager_log"; then
      shifted_key_dispatched=1
      break
    fi
    sleep 0.2
  done
  if [ "$shifted_key_dispatched" -ne 1 ]; then
    printf '%s\n' "tx11_probe_smoke: fake Super+Shift+/ did not dispatch through key grab" >&2
    cat "$manager_log" >&2
    cat "$shifted_key_press_log" >&2
    exit 1
  fi

  if ! "$client" "$display" --fake-drag 1 "$x11_mod_super" 220 170 270 205 >"$pointer_drag_log" 2>&1; then
    cat "$manager_log" >&2
    cat "$pointer_drag_log" >&2
    exit 1
  fi

  pointer_dragged=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if grep -q 'backend_event PointerBinding binding="Super+left"' "$manager_log" &&
        grep -q 'backend_event PointerMotion' "$manager_log" &&
        grep -q 'backend_event PointerRelease' "$manager_log" &&
        grep -q 'xlibre_pointer_xcb applied configure window=' "$manager_log"; then
      pointer_dragged=1
      break
    fi
    sleep 0.2
  done
  if [ "$pointer_dragged" -ne 1 ]; then
    printf '%s\n' "tx11_probe_smoke: fake Super+left drag did not move floating window" >&2
    cat "$manager_log" >&2
    cat "$pointer_drag_log" >&2
    exit 1
  fi

  if ! "$client" "$display" --fake-drag 3 "$x11_mod_super" 300 220 360 260 >"$pointer_resize_log" 2>&1; then
    cat "$manager_log" >&2
    cat "$pointer_resize_log" >&2
    exit 1
  fi

  pointer_resized=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if grep -q 'backend_event PointerBinding binding="Super+right"' "$manager_log" &&
        grep -q 'xlibre_pointer_xcb applied configure window=0x00400000' "$manager_log" &&
        grep -q 'xlibre_pointer_request configure window=0x00400000 x=310 y=225 w=260 h=160' "$manager_log"; then
      pointer_resized=1
      break
    fi
    sleep 0.2
  done
  if [ "$pointer_resized" -ne 1 ]; then
    printf '%s\n' "tx11_probe_smoke: fake Super+right drag did not resize floating window" >&2
    cat "$manager_log" >&2
    cat "$pointer_resize_log" >&2
    exit 1
  fi

  if ! "$client" "$display" --fake-key 0x66 "$x11_mod_super" >"$maximize_edges_press_log" 2>&1; then
    cat "$manager_log" >&2
    cat "$maximize_edges_press_log" >&2
    exit 1
  fi

  maximize_edges_dispatched=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if grep -q 'backend_event KeyBinding binding="Super+f"' "$manager_log" &&
        grep -q 'xlibre_key_binding_reply .*"binding":"Super+f"' "$manager_log" &&
        grep -q 'xlibre_key_binding_reply .*"command":"maximize-window-to-edges"' "$manager_log" &&
        grep -q 'xlibre_ipc_xcb applied maximized window=' "$manager_log"; then
      maximize_edges_dispatched=1
      break
    fi
    sleep 0.2
  done

  if [ "$maximize_edges_dispatched" -ne 1 ]; then
    printf '%s\n' "tx11_probe_smoke: fake Super+f did not maximize to edges" >&2
    cat "$manager_log" >&2
    cat "$maximize_edges_press_log" >&2
    exit 1
  fi

  if ! "$client" "$display" --fake-key 0x66 "$x11_mod_super_shift" >"$fullscreen_press_log" 2>&1; then
    cat "$manager_log" >&2
    cat "$fullscreen_press_log" >&2
    exit 1
  fi

  fullscreen_dispatched=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if grep -q 'backend_event KeyBinding binding="Super+Shift+f"' "$manager_log" &&
        grep -q 'xlibre_key_binding_reply .*"binding":"Super+Shift+f"' "$manager_log" &&
        grep -q 'xlibre_key_binding_reply .*"command":"fullscreen-window"' "$manager_log" &&
        grep -q 'xlibre_ipc_xcb applied fullscreen window=' "$manager_log"; then
      fullscreen_dispatched=1
      break
    fi
    sleep 0.2
  done

  if [ "$fullscreen_dispatched" -ne 1 ]; then
    printf '%s\n' "tx11_probe_smoke: fake Super+Shift+f did not toggle fullscreen" >&2
    cat "$manager_log" >&2
    cat "$fullscreen_press_log" >&2
    exit 1
  fi

  if ! "$client" "$display" --fake-key 0x6d "$x11_mod_super" >"$maximize_column_press_log" 2>&1; then
    cat "$manager_log" >&2
    cat "$maximize_column_press_log" >&2
    exit 1
  fi

  maximize_column_dispatched=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if grep -q 'backend_event KeyBinding binding="Super+m"' "$manager_log" &&
        grep -q 'xlibre_key_binding_reply .*"binding":"Super+m"' "$manager_log" &&
        grep -q 'xlibre_key_binding_reply .*"command":"maximize-column"' "$manager_log" &&
        grep -q 'xlibre_ipc_xcb applied configure window=' "$manager_log"; then
      maximize_column_dispatched=1
      break
    fi
    sleep 0.2
  done

  if [ "$maximize_column_dispatched" -ne 1 ]; then
    printf '%s\n' "tx11_probe_smoke: fake Super+m did not maximize column" >&2
    cat "$manager_log" >&2
    cat "$maximize_column_press_log" >&2
    exit 1
  fi

  if ! "$client" "$display" --fake-key 0x76 "$x11_mod_super" >"$vertical_scroller_press_log" 2>&1; then
    cat "$manager_log" >&2
    cat "$vertical_scroller_press_log" >&2
    exit 1
  fi

  vertical_scroller_dispatched=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if grep -q 'backend_event KeyBinding binding="Super+v"' "$manager_log" &&
        grep -q 'xlibre_key_binding_reply .*"binding":"Super+v"' "$manager_log" &&
        grep -q 'xlibre_key_binding_reply .*"command":"vertical-scroller"' "$manager_log" &&
        grep -q 'xlibre_ipc_xcb applied configure window=' "$manager_log"; then
      vertical_scroller_dispatched=1
      break
    fi
    sleep 0.2
  done

  if [ "$vertical_scroller_dispatched" -ne 1 ]; then
    printf '%s\n' "tx11_probe_smoke: fake Super+v did not set vertical scroller layout" >&2
    cat "$manager_log" >&2
    cat "$vertical_scroller_press_log" >&2
    exit 1
  fi

  if ! "$client" "$display" --fake-key 0x63 "$x11_mod_super" >"$layout_scroller_press_log" 2>&1; then
    cat "$manager_log" >&2
    cat "$layout_scroller_press_log" >&2
    exit 1
  fi

  layout_scroller_dispatched=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if grep -q 'backend_event KeyBinding binding="Super+c"' "$manager_log" &&
        grep -q 'xlibre_key_binding_reply .*"binding":"Super+c"' "$manager_log" &&
        grep -q 'xlibre_key_binding_reply .*"command":"scroller"' "$manager_log" &&
        grep -q 'xlibre_ipc_xcb applied configure window=' "$manager_log"; then
      layout_scroller_dispatched=1
      break
    fi
    sleep 0.2
  done

  if [ "$layout_scroller_dispatched" -ne 1 ]; then
    printf '%s\n' "tx11_probe_smoke: fake Super+c did not set scroller layout" >&2
    cat "$manager_log" >&2
    cat "$layout_scroller_press_log" >&2
    exit 1
  fi

  if ! "$client" "$display" --fake-key 0x6e "$x11_mod_super" >"$switch_layout_press_log" 2>&1; then
    cat "$manager_log" >&2
    cat "$switch_layout_press_log" >&2
    exit 1
  fi

  switch_layout_dispatched=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if grep -q 'backend_event KeyBinding binding="Super+n"' "$manager_log" &&
        grep -q 'xlibre_key_binding_reply .*"binding":"Super+n"' "$manager_log" &&
        grep -q 'xlibre_key_binding_reply .*"command":"switch-layout"' "$manager_log" &&
        grep -q 'xlibre_ipc_xcb applied configure window=' "$manager_log"; then
      switch_layout_dispatched=1
      break
    fi
    sleep 0.2
  done

  if [ "$switch_layout_dispatched" -ne 1 ]; then
    printf '%s\n' "tx11_probe_smoke: fake Super+n did not switch layout" >&2
    cat "$manager_log" >&2
    cat "$switch_layout_press_log" >&2
    exit 1
  fi

  if ! "$client" "$display" --fake-key 0x78 "$x11_mod_super" >"$spawn_press_log" 2>&1; then
    cat "$manager_log" >&2
    cat "$spawn_press_log" >&2
    exit 1
  fi

  spawn_dispatched=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if [ -f "$spawn_marker" ] &&
        grep -q 'backend_event KeyBinding binding="Super+x"' "$manager_log" &&
        grep -q 'xlibre_key_binding_reply .*"binding":"Super+x"' "$manager_log" &&
        grep -q 'xlibre_key_binding_reply .*"command":"spawn touch ' "$manager_log" &&
        grep -q 'xlibre_ipc_spawn spawned command=touch pid=' "$manager_log"; then
      spawn_dispatched=1
      break
    fi
    sleep 0.2
  done

  if [ "$spawn_dispatched" -ne 1 ]; then
    printf '%s\n' "tx11_probe_smoke: fake Super+x did not spawn configured command" >&2
    cat "$manager_log" >&2
    cat "$spawn_press_log" >&2
    exit 1
  fi

  if ! "$client" "$display" --fake-key 0x74 "$x11_mod_super" >"$spawn_terminal_press_log" 2>&1; then
    cat "$manager_log" >&2
    cat "$spawn_terminal_press_log" >&2
    exit 1
  fi

  spawn_terminal_dispatched=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if [ -f "$spawn_terminal_marker" ] &&
        grep -q 'backend_event KeyBinding binding="Super+t"' "$manager_log" &&
        grep -q 'xlibre_key_binding_reply .*"binding":"Super+t"' "$manager_log" &&
        grep -q 'xlibre_key_binding_reply .*"command":"spawn-terminal"' "$manager_log" &&
        grep -q 'xlibre_ipc_spawn spawn-terminal command=touch' "$manager_log"; then
      spawn_terminal_dispatched=1
      break
    fi
    sleep 0.2
  done

  if [ "$spawn_terminal_dispatched" -ne 1 ]; then
    printf '%s\n' "tx11_probe_smoke: fake Super+t did not spawn configured terminal command" >&2
    cat "$manager_log" >&2
    cat "$spawn_terminal_press_log" >&2
    exit 1
  fi

  if ! "$client" "$display" --fake-button 2 "$x11_mod_super" >"$button_press_log" 2>&1; then
    cat "$manager_log" >&2
    cat "$button_press_log" >&2
    exit 1
  fi

  button_dispatched=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if grep -q 'backend_event PointerBinding binding="Super+middle"' "$manager_log" &&
        grep -q 'xlibre_pointer_binding_reply .*"type":"xlibre-binding-dispatch"' "$manager_log"; then
      button_dispatched=1
      break
    fi
    sleep 0.2
  done
  if [ "$button_dispatched" -ne 1 ]; then
    printf '%s\n' "tx11_probe_smoke: fake Super+middle did not dispatch through button grab" >&2
    cat "$manager_log" >&2
    cat "$button_press_log" >&2
    exit 1
  fi

  if ! "$client" "$display" --fake-button 8 "$x11_mod_super" >"$back_button_press_log" 2>&1; then
    cat "$manager_log" >&2
    cat "$back_button_press_log" >&2
    exit 1
  fi

  back_button_dispatched=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if grep -q 'backend_event PointerBinding binding="Super+back"' "$manager_log" &&
        grep -q 'xlibre_pointer_binding_reply .*"binding":"Super+back"' "$manager_log"; then
      back_button_dispatched=1
      break
    fi
    sleep 0.2
  done
  if [ "$back_button_dispatched" -ne 1 ]; then
    printf '%s\n' "tx11_probe_smoke: fake Super+back did not dispatch through button grab" >&2
    cat "$manager_log" >&2
    cat "$back_button_press_log" >&2
    exit 1
  fi

  if ! "$client" "$display" --fake-button 10 "$x11_mod_super" >"$device_button_press_log" 2>&1; then
    cat "$manager_log" >&2
    cat "$device_button_press_log" >&2
    exit 1
  fi

  device_button_dispatched=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if grep -q 'backend_event PointerBinding binding="Super+button10"' "$manager_log" &&
        grep -q 'xlibre_pointer_binding_reply .*"binding":"Super+button10"' "$manager_log"; then
      device_button_dispatched=1
      break
    fi
    sleep 0.2
  done
  if [ "$device_button_dispatched" -ne 1 ]; then
    printf '%s\n' "tx11_probe_smoke: fake Super+button10 did not dispatch through button grab" >&2
    cat "$manager_log" >&2
    cat "$device_button_press_log" >&2
    exit 1
  fi

  if ! "$client" "$display" --fake-button 4 "$x11_mod_super" >"$axis_press_log" 2>&1; then
    cat "$manager_log" >&2
    cat "$axis_press_log" >&2
    exit 1
  fi

  axis_dispatched=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if grep -q 'backend_event AxisBinding binding="Super+wheel-up"' "$manager_log" &&
        grep -q 'xlibre_axis_binding_reply .*"type":"xlibre-binding-dispatch"' "$manager_log"; then
      axis_dispatched=1
      break
    fi
    sleep 0.2
  done
  if [ "$axis_dispatched" -ne 1 ]; then
    printf '%s\n' "tx11_probe_smoke: fake Super+wheel-up did not dispatch through axis grab" >&2
    cat "$manager_log" >&2
    cat "$axis_press_log" >&2
    exit 1
  fi

else
  printf '%s\n' "tx11_probe_smoke: xcb-xtest unavailable; skipping fake input"
fi

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

if [ "$xtest_available" -eq 1 ]; then
  "$client" "$display" --managed-hold >"$close_key_client_log" 2>&1 &
  client_pid="$!"

  close_key_window_id=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if grep -q '^window=0x' "$close_key_client_log" 2>/dev/null; then
      close_key_window_id="$(sed -n 's/^window=//p' "$close_key_client_log" | head -n 1)"
      break
    fi
    sleep 0.2
  done

  if [ -z "$close_key_window_id" ]; then
    printf '%s\n' "tx11_probe_smoke: close-key client did not publish a window id" >&2
    cat "$manager_log" >&2
    cat "$close_key_client_log" >&2
    exit 1
  fi

  if ! "$client" "$display" --fake-key 0x71 "$x11_mod_super" >"$close_key_press_log" 2>&1; then
    cat "$manager_log" >&2
    cat "$close_key_press_log" >&2
    exit 1
  fi

  close_key_closed=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ! kill -0 "$client_pid" 2>/dev/null; then
      close_key_closed=1
      break
    fi
    sleep 0.2
  done

  if [ "$close_key_closed" -ne 1 ]; then
    printf '%s\n' "tx11_probe_smoke: fake Super+q did not close focused client" >&2
    cat "$manager_log" >&2
    cat "$close_key_client_log" >&2
    cat "$close_key_press_log" >&2
    exit 1
  fi
  wait "$client_pid" 2>/dev/null || true
  client_pid=""

  for pattern in \
    'backend_event KeyBinding binding="Super+q"' \
    'xlibre_key_binding_reply .*"binding":"Super+q"' \
    'xlibre_key_binding_reply .*"command":"close-window"' \
    "xlibre_ipc_xcb applied close window=$close_key_window_id"; do
    if ! grep -q "$pattern" "$manager_log"; then
      printf '%s\n' "tx11_probe_smoke: missing close-key pattern: $pattern" >&2
      cat "$manager_log" >&2
      cat "$close_key_client_log" >&2
      cat "$close_key_press_log" >&2
      exit 1
    fi
  done
fi

if [ "$xtest_available" -eq 1 ]; then
  "$client" "$display" --managed-hold >"$focus_next_a_client_log" 2>&1 &
  focus_next_a_pid="$!"

  focus_next_a_window_id=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if grep -q '^window=0x' "$focus_next_a_client_log" 2>/dev/null; then
      focus_next_a_window_id="$(sed -n 's/^window=//p' "$focus_next_a_client_log" | head -n 1)"
      break
    fi
    sleep 0.2
  done

  if [ -z "$focus_next_a_window_id" ]; then
    printf '%s\n' "tx11_probe_smoke: first focus-next client did not publish a window id" >&2
    cat "$manager_log" >&2
    cat "$focus_next_a_client_log" >&2
    exit 1
  fi

  "$client" "$display" --managed-hold >"$focus_next_b_client_log" 2>&1 &
  focus_next_b_pid="$!"

  focus_next_b_window_id=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if grep -q '^window=0x' "$focus_next_b_client_log" 2>/dev/null; then
      focus_next_b_window_id="$(sed -n 's/^window=//p' "$focus_next_b_client_log" | head -n 1)"
      break
    fi
    sleep 0.2
  done

  if [ -z "$focus_next_b_window_id" ]; then
    printf '%s\n' "tx11_probe_smoke: second focus-next client did not publish a window id" >&2
    cat "$manager_log" >&2
    cat "$focus_next_b_client_log" >&2
    exit 1
  fi

  if ! "$client" "$display" --fake-key 0xff09 "$x11_mod_super" >"$focus_next_press_log" 2>&1; then
    cat "$manager_log" >&2
    cat "$focus_next_press_log" >&2
    exit 1
  fi

  focus_next_dispatched=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if grep -q 'backend_event KeyBinding binding="Super+Tab"' "$manager_log" &&
        grep -q 'xlibre_key_binding_reply .*"binding":"Super+Tab"' "$manager_log" &&
        grep -q 'xlibre_key_binding_reply .*"command":"focus-next"' "$manager_log" &&
        grep -q "xlibre_ipc_xcb applied focus window=$focus_next_a_window_id" "$manager_log"; then
      focus_next_dispatched=1
      break
    fi
    sleep 0.2
  done

  if [ "$focus_next_dispatched" -ne 1 ]; then
    printf '%s\n' "tx11_probe_smoke: fake Super+Tab did not focus next managed client" >&2
    cat "$manager_log" >&2
    cat "$focus_next_a_client_log" >&2
    cat "$focus_next_b_client_log" >&2
    cat "$focus_next_press_log" >&2
    exit 1
  fi
fi

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
