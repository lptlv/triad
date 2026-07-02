import std/[os, parseutils, strutils]

import ../src/core/effects
import ../src/x11/effect_adapter
import ../src/x11/request_builder
import ../src/x11/request_executor

proc fail(message: string) =
  stderr.writeLine("tx11_live_executor: " & message)
  quit 1

proc hexDigitValue(ch: char): int =
  if ch >= '0' and ch <= '9':
    ord(ch) - ord('0')
  elif ch >= 'a' and ch <= 'f':
    ord(ch) - ord('a') + 10
  elif ch >= 'A' and ch <= 'F':
    ord(ch) - ord('A') + 10
  else:
    -1

proc parseWindowId(value: string): uint32 =
  if value.startsWith("0x") or value.startsWith("0X"):
    let digits = value.substr(2)
    if digits.len == 0:
      fail("invalid window id: " & value)
    var parsed: uint64
    for ch in digits:
      let digit = ch.hexDigitValue()
      if digit < 0:
        fail("invalid window id: " & value)
      parsed = parsed * 16'u64 + uint64(digit)
      if parsed > uint64(high(uint32)):
        fail("window id out of range: " & value)
    if parsed == 0:
      fail("window id out of range: " & value)
    return uint32(parsed)

  var parsed: BiggestInt
  let consumed = parseBiggestInt(value, parsed)
  if consumed <= 0 or consumed != value.len:
    fail("invalid window id: " & value)
  if parsed <= 0 or parsed > BiggestInt(high(uint32)):
    fail("window id out of range: " & value)
  uint32(parsed)

when isMainModule:
  let args = commandLineParams()
  if args.len != 2:
    fail("usage: tx11_live_executor DISPLAY WINDOW_ID")

  let display = args[0]
  let windowId = parseWindowId(args[1])
  let requests =
    @[
      Effect(
        kind: EffectKind.EffSetPosition,
        windowId: windowId,
        x: 120,
        y: 140,
        w: 400,
        h: 260,
      ),
      Effect(kind: EffectKind.EffFocusWindow, focusId: windowId),
      Effect(kind: EffectKind.EffCloseWindow, closeId: windowId),
    ].x11IntentsFor().x11RequestsFor()

  let run = requests.executeWithXcb(displayName = display, dryRun = false)
  for line in run.logs:
    stdout.writeLine(line)
  quit run.code
