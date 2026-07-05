#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage:
  sh tools/triad-capture-status.sh [--watch|--once|--stdin] [--waybar|--text]

Formats Triad River v5 capture-session IPC for shell bars.

Modes:
  --watch   Subscribe to native capture events. This is the default.
  --once    Print the current capture-session state once.
  --stdin   Read native Triad JSON lines from stdin and format each one.

Formats:
  --waybar  Print Waybar custom module JSON. This is the default.
  --text    Print plain text.

Environment:
  TRIAD_BIN  Triad CLI to execute. Defaults to triad.
EOF
}

fail() {
  printf '%s\n' "triad-capture-status: $*" >&2
  exit 1
}

mode="watch"
format="waybar"
triad_bin="${TRIAD_BIN:-triad}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --watch)
      mode="watch"
      ;;
    --once)
      mode="once"
      ;;
    --stdin)
      mode="stdin"
      ;;
    --waybar)
      format="waybar"
      ;;
    --text)
      format="text"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || fail "jq is required"

format_line() {
  case "$format" in
    waybar)
      jq -c '
        def capture_sessions:
          .triad.capture_sessions? // .triad.state.capture_sessions? // empty;

        capture_sessions as $capture
        | (($capture.window_total // 0) + ($capture.output_total // 0)) as $total
        | if ($capture.active // false) then
            {
              text: ("CAP " + ($total | tostring)),
              alt: "active",
              class: "active",
              tooltip:
                ("Capture sessions active\nwindows: " +
                  (($capture.window_total // 0) | tostring) +
                  "\noutputs: " +
                  (($capture.output_total // 0) | tostring))
            }
          else
            {
              text: "",
              alt: "inactive",
              class: "inactive",
              tooltip: "No active capture sessions"
            }
          end
      '
      ;;
    text)
      jq -r '
        def capture_sessions:
          .triad.capture_sessions? // .triad.state.capture_sessions? // empty;

        capture_sessions as $capture
        | (($capture.window_total // 0) + ($capture.output_total // 0)) as $total
        | if ($capture.active // false) then
            "capture active: total=" + ($total | tostring) +
            " windows=" + (($capture.window_total // 0) | tostring) +
            " outputs=" + (($capture.output_total // 0) | tostring)
          else
            "capture inactive"
          end
      '
      ;;
  esac
}

format_stream() {
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' "$line" | format_line
  done
}

case "$mode" in
  once)
    "$triad_bin" msg captures | format_line
    ;;
  stdin)
    format_stream
    ;;
  watch)
    "$triad_bin" msg event-stream --native capture | format_stream
    ;;
esac
