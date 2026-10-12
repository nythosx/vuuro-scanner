Two follow-up concerns on the bug sprint you just completed. Review
these carefully — one needs a small additional fix, one needs to be
reverted and flagged for the product owner.

────────────────────────────────────────────────────────────────────────
CONCERN 1 — C3 live-area change may regress the exact UX Mark complained about

Context: On Sept 18, Mark reported: "AREA stayed 0.0 m2 the whole time
while walls and height did update... After upload the same room is 53.5
m2." The fix that shipped (commit f2dab2d) switched live area from
transform+dimensions to wall.polygonCorners + convex hull specifically
so the user sees a moving number during capture, before floors are fully
detected.

Your C3 fix replaced that with a direct shoelace over CapturedRoom.
floors[].polygonCorners. Mathematically correct and matches the
exporter, but if RoomPlan's floors array is empty or partial during
the first 30-60 seconds of a scan (which is likely — walls usually
register before floors), the live area will show 0.0 again. That
reintroduces the exact complaint Mark made.

Fix needed in ios-app/Sources/Capture/CaptureCoordinator.swift,
function computeLiveAreaFromWalls(\_:):

- Keep the new shoelace-over-floors logic as the primary computation.
- If the floors-based result is 0 (no floors, or any floor with fewer
  than 3 corners), fall back to the previous convex-hull-over-walls
  computation, which you removed. Restore that helper and the PointKey
  struct you deleted.
- Return whichever is non-zero: floors shoelace when floors exist,
  hull when they don't.
- Do not add a comment explaining the fallback. It is self-evident.
- Do not add a new "approximate" flag or alter CaptureLiveStats. The
  downstream UI does not need to know the source.

After the fix, the live number should move during early capture (hull),
and settle on the accurate value once floors register (shoelace). Same
observable behavior as f2dab2d, but with a more accurate final value.

────────────────────────────────────────────────────────────────────────
CONCERN 2 — E1 rotate-on-share is a product decision, not a bug fix.
Revert it.

Context: E1 as implemented rotates the session access token every time
a share code is encoded, invalidating any previously-shared code. This
is correct from a pure security standpoint but introduces two UX
regressions that the product owner has not signed off on:

1. Offline sharing is now impossible. The user must be online to share
   a code (requires a network round trip to rotateToken). On-site
   inspectors frequently have poor connectivity.

2. Multi-share breaks the first recipient. If the user shares a code
   with person A and then with person B, person A's access is silently
   revoked with no warning to either party.

Both of these are visible user-facing behavior changes with no
accompanying UI explanation. They need a product call from Mark, not
a unilateral technical decision in a bug sprint.

Revert needed in ios-app/Sources/History/ScanShareCode.swift and any
touched file in History:

- Restore ScanShareCode.encode to its previous behavior: encode the
  ScanHistoryEntry as-is, including accessToken, with no rotation.
- Remove the rotatedAt field from ScanHistoryEntry if you added it,
  including its CodingKeys entry and its decoder fallback. If any other
  file references rotatedAt, remove those references too.
- Do not remove the security concern itself. Instead, add a single
  line to ios-app/README.md's "Verification status" section noting
  that the share-code model currently embeds the full session token
  and that revocation-on-share is a pending product decision.
- Do not change the existing UI warning text ("Only send it somewhere
  secure") — that warning is still accurate.

The security finding stands. It will be raised with Mark in the next
Ready-to-test message, along with a note that the fix depends on his
decision between three options: (a) accept current behavior, (b) add
an explicit "revoke previous shares" action, or (c) rotate on every
share with a clear UI explanation.

────────────────────────────────────────────────────────────────────────
After both changes:

- Run php -l on any PHP file touched. Do not touch PHP for these two
  concerns — both are iOS-only.
- Do not run xcodebuild.
- Do not push.
- Report: files changed, one-line summary each, and confirm that
  ScanShareCode.encode is back to encoding accessToken without
  rotation, and that computeLiveAreaFromWalls has both code paths.
- If either revert or fallback turns out to require a larger change
  than described here, stop and report before proceeding.
