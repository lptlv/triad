import std/[os, osproc, strtabs, strutils]

import ../core/effects
import ../types/model
import ../utils/process_options
import ../utils/terminal

type X11SpawnRunResult* = object
  code*: int
  logs*: seq[string]

proc commandArgs(command: seq[string]): seq[string] =
  if command.len > 1:
    command[1 ..^ 1]
  else:
    @[]

proc configuredProcessEnv(model: Model): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value

  for entry in model.environment:
    if entry.unset:
      result.del(entry.name)
    else:
      result[entry.name] = entry.value

proc commandExistsInEnv(command: string, env: StringTableRef): bool =
  if command.len == 0:
    return false
  if command.contains($DirSep) or (AltSep != '\0' and command.contains($AltSep)):
    return fileExists(command)
  let path = env.getOrDefault("PATH", getEnv("PATH", ""))
  for dir in path.split(PathSep):
    if dir.len > 0 and fileExists(dir / command):
      return true
  false

proc executeXlibreSpawn*(model: Model, command: seq[string]): X11SpawnRunResult =
  if command.len == 0:
    result.code = 1
    result.logs.add("spawn failed reason=empty-command")
    return

  try:
    let process = startProcess(
      command[0],
      args = command.commandArgs(),
      env = model.configuredProcessEnv(),
      options = InheritedProcessOptions,
    )
    let pid = process.processID
    process.close()
    result.logs.add("spawned command=" & command[0] & " pid=" & $pid)
  except CatchableError as e:
    result.code = 1
    result.logs.add("spawn failed command=" & command[0] & " error=" & e.msg)

proc executeXlibreTerminalSpawn*(model: Model): X11SpawnRunResult =
  let env = model.configuredProcessEnv()
  for command in terminalCandidates(model.terminal.command):
    if command.len == 0 or not commandExistsInEnv(command[0], env):
      continue
    result = model.executeXlibreSpawn(command)
    if result.code == 0:
      result.logs.add("spawn-terminal command=" & command[0])
      return

  result.code = 1
  result.logs.add("spawn-terminal failed reason=no-terminal-command")

proc executeXlibreSpawnEffects*(
    model: Model, effects: openArray[Effect]
): X11SpawnRunResult =
  for effect in effects:
    if effect.kind != EffectKind.EffSpawn:
      continue
    let run = model.executeXlibreSpawn(effect.spawnCommand)
    result.logs.add(run.logs)
    if run.code != 0:
      result.code = run.code
