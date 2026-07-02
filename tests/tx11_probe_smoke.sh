#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
probe="$root/src/triad_xlibre"
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
rm -f "$log" "$event_log"

Xvfb "$display" -screen 0 800x600x24 >"$log.xvfb" 2>&1 &
xvfb_pid="$!"
probe_pid=""

cleanup() {
  if [ -n "$probe_pid" ]; then
    kill "$probe_pid" 2>/dev/null || true
    wait "$probe_pid" 2>/dev/null || true
  fi
  kill "$xvfb_pid" 2>/dev/null || true
  wait "$xvfb_pid" 2>/dev/null || true
  rm -f "$log" "$event_log" "$log.xvfb" "$client"
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
  "backend_event WindowDiscovered" \
  "dry_run_msg WlWindowCreated" \
  "dry_run_msg WlWindowDimensions" \
  "dry_run_msg WlWindowPid" \
  "event ConfigureRequest" \
  "backend_event ConfigureRequested" \
  "event PropertyNotify" \
  "backend_event PropertyChanged" \
  "event DestroyNotify" \
  "backend_event WindowDestroyed" \
  "dry_run_msg WlWindowDestroyed"; do
  if ! grep -q "$pattern" "$event_log"; then
    printf '%s\n' "tx11_probe_smoke: missing event log pattern: $pattern" >&2
    cat "$event_log" >&2
    exit 1
  fi
done

printf '%s\n' "tx11_probe_smoke: pass"
