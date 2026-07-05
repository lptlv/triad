#!/bin/sh
set -eu

usage() {
  cat <<EOF
Usage:
  $prog [--notify|--text]

Formats the TRIAD_CAPTURE_* environment passed to capture-session hooks.

Modes:
  --notify  Send a desktop notification when notify-send is available. Default.
  --text    Print the notification title and body to stdout.

Environment:
  TRIAD_CAPTURE_EVENT         started, stopped, or none.
  TRIAD_CAPTURE_ACTIVE        1 when any capture session is active, else 0.
  TRIAD_CAPTURE_WINDOW_TOTAL  Active window capture count.
  TRIAD_CAPTURE_OUTPUT_TOTAL  Active output capture count.
  TRIAD_CAPTURE_TOTAL         Total active capture count.
  TRIAD_CAPTURE_JSON          Full capture_sessions JSON payload.
EOF
}

fail() {
  printf '%s\n' "triad-capture-hook: $*" >&2
  exit 1
}

prog="$(basename "$0")"
mode="notify"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --notify)
      mode="notify"
      ;;
    --text)
      mode="text"
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

event="${TRIAD_CAPTURE_EVENT:-none}"
active="${TRIAD_CAPTURE_ACTIVE:-0}"
window_total="${TRIAD_CAPTURE_WINDOW_TOTAL:-0}"
output_total="${TRIAD_CAPTURE_OUTPUT_TOTAL:-0}"
total="${TRIAD_CAPTURE_TOTAL:-0}"
capture_json="${TRIAD_CAPTURE_JSON:-{}}"

case "$event" in
  started)
    title="Screen sharing started"
    ;;
  stopped)
    title="Screen sharing stopped"
    ;;
  *)
    title="Screen sharing changed"
    ;;
esac

summary="active=$active total=$total windows=$window_total outputs=$output_total"

details=""
if command -v jq >/dev/null 2>&1; then
  details="$(
    printf '%s\n' "$capture_json" | jq -r '
      def window_label:
        (.app_id // "window") as $app
        | (.title // "") as $title
        | if $title == "" then $app else ($app + ": " + $title) end;

      [
        ((.windows // [])
          | map(select(.known // false) | window_label)
          | if length > 0 then "windows:\n" + join("\n") else empty end),
        ((.outputs // [])
          | map(select(.known // false) | (.name // ("output " + (.id | tostring))))
          | if length > 0 then "outputs:\n" + join("\n") else empty end)
      ]
      | map(select(. != null and . != ""))
      | join("\n\n")
    ' 2>/dev/null || true
  )"
fi

if [ -n "$details" ]; then
  body="$summary

$details"
else
  body="$summary"
fi

case "$mode" in
  notify)
    if ! command -v notify-send >/dev/null 2>&1 ||
      ! notify-send "Triad" "$title
$body"
    then
      printf '%s\n%s\n' "$title" "$body"
    fi
    ;;
  text)
    printf '%s\n%s\n' "$title" "$body"
    ;;
esac
