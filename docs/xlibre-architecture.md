# XLibre Transition Architecture

This document is the transition charter for the `xlibre` branch. The branch is
an XLibre-only experiment, but the architectural goal is still to reuse Triad's
data-oriented core instead of copying window-management policy into X11 code.

## Goal

Triad currently runs as a River Wayland manager. River owns the compositor and
exposes high-level window, output, seat, manage, and render protocol objects.
The core model is more portable than the daemon: `types`, `state`, `entities`,
`systems`, layouts, config, IPC, Janet, and snapshots already mostly operate on
logical IDs plus external window/output handles.

The XLibre branch should keep that split:

1. XCB receives X11 events from XLibre or another compatible X server.
2. An X11 backend adapter translates those events into Triad `Msg` values.
3. `Model.update` applies Triad policy and returns `Effect` values.
4. An X11 effect adapter applies those effects through XCB.

The XLibre source tree is a reference checkout, not a vendored dependency. Use:

```sh
git clone --depth 1 https://github.com/X11Libre/xserver /home/niltempus/src/xlibre-xserver
```

The primary implementation contracts remain X11 client-side protocols and
libraries: X11 core, EWMH, ICCCM, RandR, and later XInput/XKB if needed.

## Backend Boundary

The reusable core boundary is `Msg -> Model -> Effect`. The XLibre transition
should protect that boundary and move backend-specific work behind adapters.

Reusable areas:

- model, entity storage, queries, and operations
- layout projection and placement policy
- config loading and window rules
- IPC, shell snapshots, and Janet scripting
- core tests that create windows, outputs, commands, and effects

River-bound areas:

- daemon startup and session validation
- Wayland registry and River protocol binding
- River manage/render phases
- River window, output, seat, layer-shell, and protocol-surface objects
- key and pointer bindings through River XKB protocols
- output management through `wlr-output-management`
- effect execution against River protocol objects

The first refactor target should be naming and adapter shape, not a broad
rewrite. `ExternalWindowId` and `ExternalOutputId` are already neutral. Helpers
that say `RiverId` should become backend-neutral only when touched by X11 work.

## X11 Backend Responsibilities

The X11 backend should be built with XCB first. The local development
environment already exposes `xcb`, `xcb-randr`, `xcb-ewmh`, and `xcb-icccm`
through `pkg-config`, which matches Triad's explicit event queue style better
than Xlib.

The adapter owns:

- connecting to `$DISPLAY` and claiming the window-manager selection
- selecting root events for map/configure/property/focus/output changes
- discovering existing top-level windows at startup
- reading `WM_CLASS`, `WM_NAME` / `_NET_WM_NAME`, transient relationships,
  normal size hints, window state, PID, and window type
- discovering outputs through RandR and mapping them to external output IDs
- translating X events into existing or newly neutralized `Msg` values
- applying focus, close, configure, stacking, fullscreen, maximized, minimized,
  and monitor/output effects through XCB

The first X11 milestone must not place windows. It should only prove that Triad
can connect to XLibre/X11, claim WM ownership, initialize EWMH/ICCCM/RandR
state, log existing windows and outputs, and feed a minimal event queue.

## Transition Phases

### Milestone 1: XCB Event Probe

The first runnable artifact is `triad_xlibre`. It connects to `$DISPLAY` or
`--display DISPLAY`, claims the window-manager selection, initializes required
atoms and EWMH basics, queries RandR outputs, logs existing top-level windows,
and then either exits with `--once` or logs X events until interrupted.

Use:

```sh
triad_xlibre --once
triad_xlibre --display :1
triad_xlibre --display :1 --mode admit
triad_xlibre --display :1 --mode manage --config ~/.config/triad/config.kdl
triad_xlibre --display :1 --mode manage --config ~/.config/triad/config.kdl --socket /tmp/triad-xlibre.sock
```

Default `observe` mode deliberately does not call `Model.update`, publish Triad
IPC, move windows, focus windows, map windows, or apply layout projection.
`admit` mode loads Triad config, keeps a live in-memory model, and runs
generated XCB requests through the dry-run executor. `manage` mode is opt-in
and executes whitelisted requests on the active WM-owned XCB connection,
including layout configure requests generated from Triad's layout projection.

Status: implemented. `nimble testXlibre` runs the pure X11 event mapping tests,
builds the probe, runs the `triad_xlibre --once` startup smoke harness, and
uses a synthetic XCB client to cover live map, configure, property, and destroy
events when `Xvfb` is available. The C/XCB probe emits typed `X11BackendEvent`
values into Nim; observe mode logs the Triad messages they would produce, while
admit and manage modes run those messages through `Model.update`.

Dry-run model admission is also available through `src/x11/admission.nim`. It
applies mapped X11 messages to an isolated `Model` and returns the resulting
effects for inspection without executing any XCB control operations.

The first effect adapter is available through `src/x11/effect_adapter.nim`. It
maps `EffSetPosition`, `EffFocusWindow`, and `EffCloseWindow` into pure X11
request intents. Those intents are testable without a live server and are
executed by the probe CLI only in explicit manage mode.

`src/x11/request_builder.nim` lowers those intents into stable XCB request
records for layout configure-window, input-focus, polite close, and X11
map-window operations.
`src/x11/request_executor.nim` can dry-run those records and report what would
be sent without mutating a live server. The same module also exposes a guarded
C/XCB boundary: dry-run mode does not connect to a display, while live mode
connects only when explicitly called with `dryRun = false` or from the active
WM-owned probe connection.

When XLibre is already installed locally, the smoke harness can attach to an
externally started, isolated XLibre display instead of launching `Xvfb`:

```sh
TRIAD_X11_EXTERNAL_DISPLAY=1 TRIAD_X11_DISPLAY=:73 sh tests/tx11_probe_smoke.sh
```

The target display must not already have another window manager, because
`triad_xlibre` claims WM ownership during the smoke run.

### Phase 1: Inventory and Vocabulary

Keep the current River daemon intact where possible, but document and isolate
backend-specific code paths. Avoid moving pure model behavior.

Concrete targets:

- inventory `daemon/app.nim`, `effects_runtime.nim`, `river_manager_runtime.nim`,
  `render_runtime.nim`, `bindings_runtime.nim`, and `protocol_surface_runtime.nim`
- keep `systems/daemon_view.nim` as the first place to neutralize helper names
- preserve existing model tests as the portability baseline

### Phase 2: Event Mapping

After the typed probe path is stable on an isolated X server, keep expanding
the adapter functions that produce backend-neutral window, output, focus, and
property updates. Keep these functions testable without a live X server.

Expected event inputs:

- `MapRequest`, `UnmapNotify`, `DestroyNotify`
- `ConfigureRequest`, `ConfigureNotify`
- `PropertyNotify`
- `FocusIn`, `FocusOut`, `EnterNotify`
- RandR screen/output change notifications

### Phase 3: Model Admission and Minimal Effect Adapter

Dry-run model admission is implemented for discovered windows, map requests,
outputs, focus, destroyed windows, and explicit observed-only no-ops. Pure
request-intent mapping plus request-record construction is implemented for
configure, focus, close, and map operations, with non-mutating dry-run execution
and guarded C/XCB execution boundaries. Live execution is validated against the
synthetic Xvfb client for configure, focus, polite close, and WM-owned map
requests. Layout projection now lowers `RenderInstruction` geometry into XCB
configure-window requests after layout-affecting X11 events. The controlled
admission-to-executor loop is available through `src/x11/pipeline.nim`;
`triad_xlibre --mode admit` runs it dry, and `triad_xlibre --mode manage`
executes whitelisted requests on the active probe connection. Admit and manage
mode load real Triad config through the strict config loader and fail explicitly
on invalid config. Configure requests, metadata notifications, and
`_NET_WM_STATE` changes for fullscreen, maximized, minimized, and urgent windows
now update isolated model state through existing Triad messages. Per-window
urgency is also aggregated into workspace-level shell snapshot urgency.
Manage mode can also expose opt-in read-only native Triad IPC with
`--socket PATH`. That socket reuses the existing Triad JSON request schema for
`state`, `workspaces`, `outputs`, `windows`, `focused-window`, and
`capabilities` while rejecting command, binding-dispatch, text-command, and
event-stream requests. It also exposes an XLibre-specific `runtime-status`
request with backend, mode, socket path, read-only/writable flags, and live
window/output counts. The XCB event loop pumps this socket from a single
threaded tick so IPC snapshots read the live X11 model without introducing
cross-thread state access. `triad msg --socket PATH ...` can target this socket
for the supported read-only requests.
The initial writable exceptions are explicit XLibre-only requests:
`xlibre-close-window`, `xlibre-focus-window`, `xlibre-focus-workspace`, and
`xlibre-move-window-to-workspace`. Window-targeted requests accept a live X11
window id and verify it against the current shell snapshot. Direct window
requests lower to one existing XCB request record; workspace requests are vetted
Triad model messages that run through `Model.update`, layout projection, and the
X11 request executor. General Triad command IPC remains disabled on the XLibre
socket.
Startup now also probes XKB and XInput2 capabilities, logging the server
extension versions plus aggregate input device counts. This is discovery only:
the XLibre branch does not grab keys/buttons or dispatch configured bindings
yet.

The next step is to expand runtime usability cautiously:

- keep general command IPC disabled until additional X11-side action semantics
  are modeled and tested as request intents
- expand the explicit XLibre action set only one command family at a time
- use XInput/XKB discovery to model a minimal tested binding path before
  enabling normal user bindings

Only after this subset works should the branch attempt bindings, overlays, shell
compatibility, or live-session packaging.

## Non-Goals

The first transition milestone does not need:

- River compatibility on this branch
- full tiling or scroller behavior under X11
- decorations, overlays, recent-window previews, or frame tabs
- shell compatibility guarantees
- screenshots, idle inhibit, monitor power, or lock-session integration
- vendoring or linking against XLibre server internals

## Test Strategy

For documentation-only changes, manual Markdown review is enough.

For implementation work:

- add unit tests for X event to `Msg` mapping before managing real windows
- add unit tests for `Effect` to XCB request mapping where practical
- keep existing model, layout, config, IPC, and Janet tests green when reused
- keep the Xvfb/XLibre smoke test covering one-shot startup and live synthetic
  client events
- log startup ownership failures clearly so another window manager is obvious
- keep live smoke dependencies in the Nix dev shell

## References

- XLibre organization: <https://github.com/X11Libre>
- XLibre X server: <https://github.com/X11Libre/xserver>
- Local reference checkout: `/home/niltempus/src/xlibre-xserver`
