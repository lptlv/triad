import std/[os, osproc, strtabs]

import ../core/effects
import ../types/model
import ../utils/process_options

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
