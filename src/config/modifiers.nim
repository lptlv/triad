import std/strutils

type
  ModifierAlias* = object
    name*: string
    value*: uint32

  ModifierAliases* = object
    aliases*: seq[ModifierAlias]

const
  ModifierShift* = 1'u32
  ModifierCtrl* = 4'u32
  ModifierAlt* = 8'u32
  ModifierMod3* = 32'u32
  ModifierSuper* = 64'u32
  ModifierMod5* = 128'u32

  ShiftModifier* = ModifierShift

proc normalizedModifierName(name: string): string =
  name.strip().normalize()

proc physicalModifierValue*(name: string): uint32 =
  case name.normalizedModifierName()
  of "shift": ModifierShift
  of "ctrl", "control": ModifierCtrl
  of "mod1": ModifierAlt
  of "mod3": ModifierMod3
  of "mod4": ModifierSuper
  of "mod5": ModifierMod5
  of "none": 0'u32
  else: 0'u32

proc setAlias*(aliases: var ModifierAliases, name: string, value: uint32) =
  let normalized = name.normalizedModifierName()
  if normalized.len == 0:
    return
  for alias in aliases.aliases.mitems:
    if alias.name == normalized:
      alias.value = value
      return
  aliases.aliases.add(ModifierAlias(name: normalized, value: value))

proc defaultModifierAliases*(): ModifierAliases =
  for name in ["Shift"]:
    result.setAlias(name, ModifierShift)
  for name in ["Ctrl", "Control"]:
    result.setAlias(name, ModifierCtrl)
  for name in ["Alt"]:
    result.setAlias(name, ModifierAlt)
  for name in ["Super", "Logo"]:
    result.setAlias(name, ModifierSuper)
  for name in ["None"]:
    result.setAlias(name, 0'u32)

proc modifierValue*(aliases: ModifierAliases, name: string): uint32 =
  let physical = name.physicalModifierValue()
  if physical != 0 or name.normalizedModifierName() == "none":
    return physical
  let normalized = name.normalizedModifierName()
  for alias in aliases.aliases:
    if alias.name == normalized:
      return alias.value
  0'u32

proc modifierValue*(name: string): uint32 =
  defaultModifierAliases().modifierValue(name)

proc parseModifiers*(value: string, aliases: ModifierAliases): uint32 =
  for part in value.split("+"):
    result = result or aliases.modifierValue(part.strip())

proc parseModifiers*(value: string): uint32 =
  parseModifiers(value, defaultModifierAliases())

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
