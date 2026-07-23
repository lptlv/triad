# Triad TODO

## Visible Frame Tabs For frame-tree plan

- Remaining follow-ups: drag/drop between frames and window-rule frame targeting.

## BSP layout follow-ups

- Add optional BSP rotate/flip/circulate commands if users ask for deeper tree
  editing.

## Native output mirroring

**Status: blocked by stock River.** River does not currently provide either the
compositor semantics or a public protocol request for native output cloning.
Triad cannot add proper mirroring from the client side alone.

River must first provide all of the following in an unmodified upstream release:

- one logical desktop rendered to multiple physical outputs, rather than two
  independently navigable outputs placed at the same coordinates;
- correct final composition of workspaces, cursor, layer-shell surfaces, and
  session-lock content across every member of the mirror group;
- per-head mode, scale, transform, refresh, damage, and aspect-ratio handling;
- atomic creation, update, removal, and state reporting for mirror groups; and
- a public Wayland protocol through which output-management clients can request
  and observe that relationship.

The existing
[COSMIC output-management extension](https://wayland.app/protocols/cosmic-output-management-unstable-v1)
is a concrete protocol model: it extends a wlroots output-management
configuration with a `mirror_head` request. River does not advertise or
implement that extension today. Once stock River exposes this protocol or an
equivalent public interface, Triad can:

1. bind the interface only when the compositor advertises it;
2. translate the reserved `mirror "SOURCE"` output rule into the compositor's
   atomic output configuration;
3. expose a generic `output_mirroring` capability to shells and IPC clients; and
4. report mirroring as unavailable without changing the current output layout
   when the protocol is absent.

Client-side screencopy, `wl-mirror`, overlapping logical outputs, DRM leasing,
and capture/presentation clients are not substitutes. They leave the target as
a separate desktop or present a delayed image instead of making the compositor
own one logical output backed by multiple physical heads. Triad will not fork
River or require a private River build to bridge this gap.

Upstream review on 2026-07-22 found no dedicated open River issue for native
mirroring. The relevant tracker items are:

- [river#282](https://codeberg.org/river/river/issues/282), an accepted proposal
  to reject overlapping output layouts. The maintainer states that
  [mirroring is orthogonal and will be supported separately](https://codeberg.org/river/river/issues/282#issuecomment-11718495),
  so output overlap is not a forward-compatible implementation path.
- [river#1474](https://codeberg.org/river/river/issues/1474), a DRM lease request
  for wired VR. A lease hands a connector to another client and does not define
  desktop mirroring.

## Blocked / Watchlist

- Janet follow-ups: additional prelude helpers as real scripts need them.
- Revisit target-viewport layout projection only if compositor-owned animation
  or another projection consumer needs final-position coordinates.
- Watch upstream River for a native logical-to-physical output cloning surface.
