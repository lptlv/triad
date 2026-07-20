+++
title = "Monitors"
weight = 20
+++

# Monitors

Triad treats each monitor as a distinct output with its own visible workspace. Windows are laid out within individual monitors rather than a single large desktop canvas.

## Core Model

Each monitor shows one active workspace. Each workspace remembers its assigned output. Focusing a workspace shows it on its remembered output. Every connected output maintains at least one visible workspace. Empty dynamic workspaces are pruned when you leave them.

Workspaces stay on their assigned monitors unless moved or pinned elsewhere. If a monitor is disconnected, its workspaces fall back to a connected monitor and return once the original monitor reconnects.

## Configuring Outputs

Use the `output` block to configure your monitors. Identify targets using connector names shown by tools like `wlr-randr`.

```kdl
output {
  monitor "DP-1" {
    mode "preferred"
    position "auto-right"
    scale "auto"
  }

  monitor "DP-2" {
    mode "2560x1440@120"
    position "0x0"
    focus-at-startup
    vrr 2
    reserved_area top=8 bottom=8
  }

  default {
    scale "auto"
  }
}
```

`position` defines the monitor arrangement; it does not tile windows across combined rectangles. Each output tiles windows within its own resolution and usable area.

### Output Settings

| Field | Format | Purpose |
| :--- | :--- | :--- |
| `focus-at-startup` | Flag or bool | Select the startup-focused output. |
| `workspaces` | Positive integers | Pin workspace IDs to this output. |
| `mode` | `W H Hz`, `"WxH"`, `"WxH@Hz"`, `"preferred"`, `"highres"`, `"highrr"`, `"maxwidth"` | Request an advertised mode or a custom string mode. |
| `scale` | Float or `"auto"` | Set the output scale (0.01..64.0). `"auto"` uses the compositor's current scale. |
| `position` | `X Y`, `"XxY"`, `"auto"`, `"auto-right"`, `"auto-left"`, `"auto-up"`, `"auto-down"`, `"auto-center-*"` | Set or auto-arrange global output coordinates. |
| `transform` | String or `0..7` | Rotation: `normal`, `90`, `180`, `270`, or `flipped` variants (e.g., `flipped-90`). Integers follow Wayland transform order. |
| `adaptive-sync` | Bool | Request VRR/Adaptive Sync. |
| `vrr` | `0..3` | Alias for `adaptive-sync`. `0` disables; nonzero enables. |
| `enabled` / `disabled` | Bool | Enable or disable the output. |
| `reserved_area` | Ints or properties | Add a top/right/bottom/left inset on top of bar reservations. |

Use `default` for fallback rules. Fallback rules apply to connected monitors that do not match a specific rule.

**Note on Validation:** Triad strictly validates output fields. Unsupported properties such as bit depth and HDR are rejected to prevent configuration errors.

## Mirroring limitation and roadmap

Triad does not currently support true monitor mirroring on stock River. River
exposes every physical display as a separate logical output and does not yet
provide a protocol request that clones one logical output to multiple physical
displays.

A fullscreen screencopy client is not a substitute: the target remains a second
desktop, pointer coordinates stay independent, shell bars and docks are composed
again, and differing aspect ratios introduce cropping, distortion, or black
bars. Triad will not fork River to work around this limitation.

Native mirroring remains a future roadmap item. It will require an upstream
River protocol and compositor implementation that mirrors the final composed
scene, including the cursor and layer-shell surfaces, while exposing only one
logical input/output area.

## Hotplugging

Triad keeps workspaces and windows managed when monitors are connected or disconnected. When a monitor disappears, its workspaces move to a connected monitor. When the monitor returns, Triad restores the original workspaces.

Verify your setup with:

```sh
wlr-randr
triad msg state
```

## Windows and Launchers

New windows open on the active monitor's workspace. Triad sets the default layer-shell output to the active monitor, ensuring launchers and shell bars appear where focus is.

For workspace rules, pinning, and dynamic creation, see [Workspaces](@/configuration/workspaces.md).
