# iOS app — not started this window

No Mac or Xcode is reachable on the machine this repo is being developed on, so no
Swift/RoomPlan code lives here yet. Writing it without being able to build or run it
against RoomPlan (real or simulator) would not be verifiable — see
`../docs/adr/0001-scan-service-stack.md` for how Phase 1 proves the Scan Service side
of the contract without it, using a fixture-based adapter input instead.

When Mac/Xcode access exists:

1. Confirm the fixture shape in `../scan-service/fixtures/roomplan_captured_room_single_room.json`
   against a real `CapturedRoom` export from Xcode's RoomPlan simulator; fix the adapter
   (not the fixture) if they disagree.
2. Build the guided capture flow against RoomPlan, with LiDAR/RoomPlan capability
   detection and a designed fallback message for unsupported devices (hard constraint
   #5 in `../CLAUDE.md`) — never a crash, never a silent empty feature.
3. Wire the capture upload to `POST /scan-sessions/{id}/capture` on the Scan Service
   (`../scan-service/README.md`).

This is a placeholder, not a stub implementation — there is nothing here to silently
regress.
