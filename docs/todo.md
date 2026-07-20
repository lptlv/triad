# Triad TODO

## Visible Frame Tabs For frame-tree plan

- Remaining follow-ups: drag/drop between frames and window-rule frame targeting.

## BSP layout follow-ups

- Add optional BSP rotate/flip/circulate commands if users ask for deeper tree
  editing.

## Native output mirroring

- Future feature, blocked on stock River exposing compositor-level output
  cloning through a supported protocol.
- One logical output must be rendered to multiple physical outputs, including
  the final cursor and layer-shell composition; the target must not remain a
  separately navigable desktop.
- Define explicit aspect-ratio policy (`fit`, `fill`, or `stretch`) for physical
  outputs with different modes, such as 1920x1200 mirrored to 1920x1080.
- Do not treat a fullscreen screencopy window as output mirroring and do not
  maintain a River fork to implement the feature.

## Blocked / Watchlist

- Janet follow-ups: additional prelude helpers as real scripts need them.
- Revisit target-viewport layout projection only if compositor-owned animation
  or another projection consumer needs final-position coordinates.
- Watch upstream River for a native logical-to-physical output cloning surface.
