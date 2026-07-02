#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
probe="$root/src/triad_xlibre"

if ! command -v Xvfb >/dev/null 2>&1; then
  printf '%s\n' "tx11_probe_smoke: Xvfb not found; skipping"
  exit 0
fi

if [ ! -x "$probe" ]; then
  printf '%s\n' "tx11_probe_smoke: probe binary missing: $probe" >&2
  exit 1
fi

display=":73"
log="$root/tests/tx11-probe-smoke.log"
rm -f "$log"

Xvfb "$display" -screen 0 800x600x24 >"$log.xvfb" 2>&1 &
xvfb_pid="$!"
trap 'kill "$xvfb_pid" 2>/dev/null || true; rm -f "$log" "$log.xvfb"' EXIT INT TERM

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
  "probe complete once=true"; do
  if ! grep -q "$pattern" "$log"; then
    printf '%s\n' "tx11_probe_smoke: missing log pattern: $pattern" >&2
    cat "$log" >&2
    exit 1
  fi
done

printf '%s\n' "tx11_probe_smoke: pass"
