import std/strutils

const
  ModifierShift* = 1'u32
  ModifierCtrl* = 4'u32
  ModifierAlt* = 8'u32
  ModifierMod3* = 32'u32
  ModifierSuper* = 64'u32
  ModifierMod5* = 128'u32

  ShiftModifier* = ModifierShift

proc modifierValue*(name: string): uint32 =
  case name
  of "Shift", "shift", "SHIFT":
    ModifierShift
  of "Ctrl", "Control", "ctrl", "control", "CTRL", "CONTROL":
    ModifierCtrl
  of "Alt", "Mod1", "alt", "mod1", "ALT", "MOD1":
    ModifierAlt
  of "Mod3", "mod3", "MOD3":
    ModifierMod3
  of "Super", "Logo", "Mod4", "super", "logo", "mod4", "SUPER", "LOGO", "MOD4":
    ModifierSuper
  of "Mod5", "mod5", "MOD5":
    ModifierMod5
  of "None", "none", "NONE":
    0'u32
  else:
    0'u32

proc parseModifiers*(value: string): uint32 =
  for part in value.split("+"):
    result = result or modifierValue(part.strip())

proc modifierLabels*(modifiers: uint32): seq[string] =
  if (modifiers and ModifierSuper) != 0:
    result.add("Super")
  if (modifiers and ModifierCtrl) != 0:
    result.add("Ctrl")
  if (modifiers and ModifierShift) != 0:
    result.add("Shift")
  if (modifiers and ModifierAlt) != 0:
    result.add("Alt")
  if (modifiers and ModifierMod3) != 0:
    result.add("Mod3")
  if (modifiers and ModifierMod5) != 0:
    result.add("Mod5")

proc bindingSpec*(modifiers: uint32, key: string): string =
  var parts = modifierLabels(modifiers)
  parts.add(key)
  parts.join("+")
