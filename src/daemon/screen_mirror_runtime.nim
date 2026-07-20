import std/[options, os, osproc, strutils, tables, times]
import chronicles
import ../state/engine
import ../systems/outputs
import ../types/core
import ../utils/process_options
import process_runner, state

type MirrorSpec = object
  sourceOutput: OutputId
  targetOutput: OutputId
  sourceName: string
  targetName: string

proc unixMs(): int64 =
  int64(epochTime() * 1000.0)

proc outputConnectorName(model: Model, outputId: OutputId): string =
  let outputOpt = model.outputData(outputId)
  if outputOpt.isNone:
    return ""
  result = outputOpt.get().name.strip()
  if result.len == 0:
    result = model.shellOutputName(outputId)

proc desiredScreenMirrors(model: Model): Table[OutputId, MirrorSpec] =
  for rule in model.outputRules:
    if not rule.mirrorSet:
      continue
    let targetOutput = model.outputForTarget(rule.target)
    let sourceOutput = model.outputForTarget(rule.mirrorSource)
    if targetOutput == NullOutputId or sourceOutput == NullOutputId or
        targetOutput == sourceOutput:
      continue
    let sourceName = model.outputConnectorName(sourceOutput)
    let targetName = model.outputConnectorName(targetOutput)
    if sourceName.len == 0 or targetName.len == 0:
      continue
    result[targetOutput] = MirrorSpec(
      sourceOutput: sourceOutput,
      targetOutput: targetOutput,
      sourceName: sourceName,
      targetName: targetName,
    )

proc stopMirror(runtime: var ScreenMirrorRuntime, reason: string) =
  if runtime.process == nil:
    return
  let pid = runtime.process.processID
  try:
    runtime.process.terminate()
    var code = runtime.process.pollProcessExitCode(1000)
    if code == -1:
      runtime.process.kill()
      code = runtime.process.waitForExit()
    info "Stopped screen mirror",
      pid = pid, target = runtime.targetName, reason = reason, exitCode = code
  except CatchableError as e:
    warn "Failed to stop screen mirror",
      pid = pid, target = runtime.targetName, reason = reason, error = e.msg
  try:
    runtime.process.close()
  except CatchableError:
    discard
  runtime.process = nil

proc startMirror(model: Model, spec: MirrorSpec): ScreenMirrorRuntime =
  result = ScreenMirrorRuntime(
    sourceOutput: spec.sourceOutput,
    targetOutput: spec.targetOutput,
    sourceName: spec.sourceName,
    targetName: spec.targetName,
  )
  var executable = getEnv("TRIAD_MIRROR_BIN", "").strip()
  if executable.len == 0:
    let sibling = getAppFilename().parentDir() / "triad_mirror"
    if fileExists(sibling):
      executable = sibling
    else:
      executable = findExe("triad_mirror")
  if executable.len == 0:
    result.failed = true
    result.retryAfterMs = unixMs() + 5_000
    warn "Configured screen mirror unavailable; bundled triad_mirror was not found",
      source = spec.sourceName, target = spec.targetName
    return
  try:
    let process = startProcess(
      executable,
      args = @[spec.sourceName, spec.targetName],
      env = model.configuredProcessEnv(),
      options = InheritedProcessOptions,
    )
    let code = process.pollProcessExitCode(250)
    if code == -1:
      result.process = process
      info "Started screen mirror",
        pid = process.processID, source = spec.sourceName, target = spec.targetName
    else:
      result.failed = true
      result.retryAfterMs = unixMs() + 2_000
      warn "Screen mirror exited during startup",
        source = spec.sourceName, target = spec.targetName, exitCode = code
      process.close()
  except CatchableError as e:
    result.failed = true
    result.retryAfterMs = unixMs() + 2_000
    warn "Unable to start screen mirror",
      source = spec.sourceName, target = spec.targetName, error = e.msg

proc sameMirror(runtime: ScreenMirrorRuntime, spec: MirrorSpec): bool =
  runtime.sourceOutput == spec.sourceOutput and runtime.targetOutput == spec.targetOutput and
    runtime.sourceName == spec.sourceName and runtime.targetName == spec.targetName

proc syncScreenMirrors*(daemon: var TriadDaemon) =
  let desired = daemon.runtimeState.model.desiredScreenMirrors()
  let nowMs = unixMs()
  var staleTargets: seq[OutputId]
  for targetOutput, runtime in daemon.screenMirrors.pairs:
    if not desired.hasKey(targetOutput) or not runtime.sameMirror(desired[targetOutput]):
      staleTargets.add(targetOutput)
  for targetOutput in staleTargets:
    var runtime = daemon.screenMirrors[targetOutput]
    runtime.stopMirror("configuration or outputs changed")
    daemon.screenMirrors.del(targetOutput)

  for targetOutput, spec in desired.pairs:
    if daemon.screenMirrors.hasKey(targetOutput):
      var runtime = daemon.screenMirrors[targetOutput]
      if runtime.process != nil:
        let code = runtime.process.pollProcessExitCode(0)
        if code != -1:
          warn "Screen mirror exited",
            source = runtime.sourceName, target = runtime.targetName, exitCode = code
          try:
            runtime.process.close()
          except CatchableError:
            discard
          runtime.process = nil
          runtime.failed = true
          runtime.retryAfterMs = nowMs + 1_000
          daemon.screenMirrors[targetOutput] = runtime
      elif nowMs >= runtime.retryAfterMs:
        daemon.screenMirrors[targetOutput] = daemon.runtimeState.model.startMirror(spec)
      continue
    daemon.screenMirrors[targetOutput] = daemon.runtimeState.model.startMirror(spec)

proc stopScreenMirrors*(daemon: var TriadDaemon, reason: string) =
  var targets: seq[OutputId]
  for targetOutput in daemon.screenMirrors.keys:
    targets.add(targetOutput)
  for targetOutput in targets:
    var runtime = daemon.screenMirrors[targetOutput]
    runtime.stopMirror(reason)
  daemon.screenMirrors.clear()
