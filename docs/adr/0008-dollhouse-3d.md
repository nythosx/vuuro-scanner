# ADR-0008: Dollhouse / 3D view

- Status: Proposed (built, not yet compiled on device or reviewed by Mark)
- Date: 2026-10-08
- Supersedes: none
- Related: ADR-0002 (export coordinate frame), contracts/floorplan.schema.json, docs/proposals/multi-room-fusion.md

## Context

The app already renders two-dimensional floor plans in three formats — SVG, PNG and PDF — all built from the same `FloorPlan` contract. What it did not have was any way to *look at a scanned unit as a three-dimensional object*. Users asked for a "dollhouse" view: an orbitable model of the captured space.

Three constraints shaped the answer before any code was written.

**Constraint 1 — RoomPlan gives surfaces, not meshes.** `CapturedRoom` exposes `walls`, `floors`, `doors`, `windows`, `openings`, `objects`. Each is a `Surface` or `Object` with a transform, dimensions, and (for surfaces) a `polygonCorners` array. There is **no material, no texture, no ceiling, and no furniture mesh**. A sofa captured by RoomPlan is a category string and a `dimensions_m` vector, not a model. This means any dollhouse built on this data will be a *diagrammatic* model — clean, flat-coloured, brand-consistent — not a photoreal walkthrough.

**Constraint 2 — The server does not have 3D data.** The `.vuuroscan` bundle persisted by the Scan Service contains the `FloorPlan` contract: room outlines in room-local 2D, opening positions in room-local 2D, object positions in room-local 2D, `height_m` per room, and `structure_origin_m` for rooms that were captured together. It does not contain the raw `polygonCorners` in world space — those live only on the iOS device, at capture time.

**Constraint 3 — SceneKit is soft-deprecated.** At WWDC 2025 Apple announced that SceneKit is soft-deprecated and pointed developers at RealityKit, whose native format is USD. RealityKit's `RealityView` requires iOS 18; this project targets iOS 17. Any on-screen viewer therefore cannot use RealityKit yet, and must isolate itself so the eventual migration is a single-file swap.

## Decision

### 1. A pure-Swift mesh builder

The mesh is built in a module with **zero rendering imports**. It takes `[FloorPlan.Room]` from the contract and produces a plain value type — vertices, indices, material, node path. Everything downstream — the on-screen viewer, the USDZ exporter — consumes that value type and does not care where the data came from.

The RoomPlan-native `.mesh` export option (true boolean cutouts for openings, real furniture geometry) is not used. The reconstructed path from the contract is simpler, works for both fresh captures and history, and gives one code path to maintain. Rooms that carry `structure_origin_m` and were captured together in one walkthrough are placed in a shared frame; rooms without it get their own section, matching the 2D renderer's tile behaviour.

### 2. SceneKit for the viewer, Model I/O for the export

The on-screen viewer uses SceneKit because it is the only supported option on iOS 17. The export uses **Model I/O** directly, not SceneKit's `write(to:)`, because Model I/O writes USDZ deterministically from explicit vertex buffers and materials. The two concerns are separate: "show this on screen" and "write this to a file" have different requirements.

When the deployment target reaches iOS 18, only `DollhouseSceneBuilder.swift` is rewritten. The mesh builder and the USDZ exporter are unchanged.

### 3. Cutaway is the default for the on-screen viewer

A full-height dollhouse — walls all the way up — is a worse 2D plan: the walls hide the interior. The default on-screen mode clips walls at **1.2 m**, leaving doors, furniture, and room shapes readable from any angle. A "Dollhouse" mode with full wall height is available as a segmented control. The user's choice is persisted per device.

The USDZ export ignores the viewer mode and always writes full-height walls: a file that opens in AR Quick Look should look like the real space, not like a viewer affordance.

### 4. One mesh per wall face, one node per mesh

The mesh builder emits one `DollhouseMesh` per wall face, per floor, per opening, per furniture object. The scene builder creates one `SCNNode` per mesh. A single room with 8 walls, 4 openings and 12 objects is roughly 24 nodes; a 5-room unit is 120; a 40-room capture sits close to SceneKit's practical comfort zone. A future merge pass — combining all faces of one material within a room into a single buffer — is planned as a change to `DollhouseSceneBuilder`, not to the mesh builder; the mesh builder's output already supports it since multiple meshes can share a material.

### 5. The server does not touch USDZ

The `.vuuroscan` bundle format is not extended. The server holds 2D data and cannot produce a 3D model. Adding a `dollhouse_usdz_base64` field that no client populates would be misleading; an earlier version of this work did exactly that and was removed. If a future client wants to ship a USDZ inside a bundle, it will build the bundle client-side.

### 6. The open edge is a dashed floor line, not a wall

A room that has been split or trimmed has an `open_edges` array naming the edges where a person drew a line. The 2D renderer draws these as dashed grey lines. The 3D view does the same on the floor plane: **no wall geometry is generated for an open edge**.

### 7. North and room labels are not yet implemented in the 3D view

`heading_deg` is a real compass reading taken at capture time, and the 2D SVG renderer draws a north arrow only when at least one room has a non-null `heading_deg`. The 3D view does not currently draw a north arrow, and it does not currently draw room labels. Both were considered — a floating 3D arrow and text sprites above each room — but neither is implemented. `DollhouseBuildConfiguration` exposes only `mode`, `showFurniture`, and `performanceMode`; when labels and north are built, their toggles return alongside the actual geometry.

## Consequences

### Gains

- A genuinely new way to look at a scan.
- A USDZ file that opens in AR Quick Look on any iPhone or iPad, no separate app needed.
- A single mesh representation shared by viewer and export.
- Honest division of labour: the iOS client builds geometry; the server persists and shares.

### Costs

- A SceneKit dependency that is deprecated. Isolated behind one file.
- The USDZ is regenerated on every share, not cached.

## Alternatives considered

**RealityKit from the start.** Rejected: requires iOS 18.

**Server-side USDZ generation.** Rejected: the server has no 3D data.

**One mesh per wall, simpler code.** Rejected: kept for now with the node count acceptable at typical sizes, and a merge pass planned.

**Photoreal materials and textures.** Rejected: RoomPlan provides no materials or textures.

**Full-height walls as the on-screen default.** Rejected: the resulting view is a worse 2D plan, not a better one.

**Extending the `.vuuroscan` format with a USDZ field.** Rejected: no client populates it; the field was removed.

## Non-goals

- Realistic furniture meshes.
- Wall or floor textures.
- AR placement of the dollhouse in the real room.
- First-person or walkthrough camera.
- Ceiling reconstruction.
- True CSG cutouts.
- Server-side USDZ generation.
- Editing geometry in 3D. Splits, trims, and object moves stay in the 2D views.
- North arrow and room labels (planned, not yet built).
- `.glb` / `.gltf` export.
- Shadows and ambient occlusion.

## References

- contracts/floorplan.schema.json — the `FloorPlan` contract consumed by the mesh builder
- docs/adr/0002-export-coordinate-frame.md — why outlines are room-local
- docs/proposals/multi-room-fusion.md — the shared-frame solver that `structure_origin_m` feeds
