+++
title = "Shell Setup"
weight = 55
+++

# Shell Setup

Triad manages status bars and desktop shells through shell profiles. A profile
defines how to launch and stop a shell. Triad starts the active profile on
launch, can cycle between profiles at runtime, and sets `$TRIAD_SOCKET` for
native shell integrations.

## The `shells` Block

```kdl
shells {
  active "waybar"
  cycle  "waybar" "noctalia"

  watchdog {
    enabled  #true
    fallback "waybar"
  }

  profile "waybar" {
    launch "waybar"
    stop   "pkill" "-x" "waybar"
  }

  profile "noctalia" {
    launch "noctalia-shell"
    stop   "pkill" "-f" "noctalia-shell"
  }
}
```

| Setting | Type | Description |
|---|---|---|
| `active` | String | Profile to launch at startup. |
| `cycle` | List | Profiles to rotate through with `cycle-shell`. |
| `watchdog.enabled` | Bool | Restart the shell if it crashes. |
| `watchdog.fallback` | String | Profile to use if the active shell fails repeatedly. |

Each profile takes:

| Setting | Type | Description |
|---|---|---|
| `launch` | String argv | Command to start the shell. |
| `stop` | String argv | Command to stop it cleanly. |

Strict config validation rejects removed compatibility fields.

## Native IPC

Shell profiles receive `$TRIAD_SOCKET`. Native clients can query snapshots:

```bash
triad msg state
triad msg workspaces
triad msg windows
```

They can also subscribe to long-lived event streams:

```bash
triad msg event-stream layout,state,window
```

The event stream emits native Triad JSON events for layout changes, global
state changes, and incremental window changes.

## Workspace Names in Your Bar

Workspace names you set in `workspace-rules` flow through native IPC to your
shell automatically:

```kdl
workspaces {
  default-count 3
  default-layout "scroller"
}

workspace-rules {
  workspace 1 name="term"
  workspace 2 name="web"
  workspace 3 name="files"
  workspace 4 name="chat"  default-layout="deck"
  workspace 5 name="media" default-layout="monocle"
  workspace 6 name="code"  default-layout="center-tile"
}
```

## Exporting Sockets to the Session

Some launchers and systemd-activated services will not see `$TRIAD_SOCKET`
unless it is exported to the D-Bus activation environment. Add this to your
Triad config to handle it at startup:

```kdl
spawn-at-startup "sh" "-lc" \
  "dbus-update-activation-environment --systemd \
   WAYLAND_DISPLAY XDG_CURRENT_DESKTOP TRIAD_SOCKET"
```

## Shell Management Commands

Manage your shell profiles and UI focus at runtime:

| Command | Description |
|---|---|
| `switch-shell <name>` | Switch the active shell profile by name. |
| `cycle-shell` | Cycle through the profiles in `shells.cycle`. |
| `focus-shell-ui` | Shift focus to the shell UI surface. |

**Example Bindings:**

```kdl
bindings {
  bind "Super+Alt+s" "cycle-shell"
  bind "Super+Alt+w" "switch-shell waybar"
  bind "Super+Alt+n" "switch-shell noctalia"
}
```
