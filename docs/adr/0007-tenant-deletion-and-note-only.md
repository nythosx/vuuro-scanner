# ADR 0007 — Tenant self-service deletion and notes-only fallback

Status: Accepted
Date: 2026-09-26

## Context

Two gaps were blocking pilot use: no way for a tenant to request their data be deleted without contacting an operator, and no fallback for phones without LiDAR (non-Pro iPhones) so a landlord couldn't contribute anything at all.

## Decision

Tenant deletion: `POST /scan-sessions/{id}/request-deletion` marks the session with a timestamp. A retention sweep (opportunistic on every tenth session creation, and on-demand via `POST /admin/run-retention`) removes any session whose `deletion_requested_at` is older than 7 days. `GET /scan-sessions/{id}/deletion-request` returns the current status (`requested`, `deletion_requested_at`, `purge_after`), and `POST /scan-sessions/{id}/cancel-deletion` clears the request during the grace period; the app's saved-report screen shows the pending request with a cancel button. This is minimum-viable tenant control, not full GDPR erasure — the operator still controls the retention schedule. Requests and cancellations appear in the session's access log (`request_deletion`, `cancel_deletion`); there is no admin-panel list of pending requests yet.

Notes-only fallback: `POST /scan-sessions/{id}/note-only` creates an empty FloorPlan with `capture_provider: note_only` and `measurement_basis: no_geometry_note_only`. Photos and notes can then be attached through the existing per-session endpoints, and the read-only report shows the session with no floor plan image. No floor plan means PNG and SVG exports return `422 no_floor_plan_geometry` with a message pointing to the PDF; the PDF export still works and degrades to a notes-and-photos-only sheet. The app hides the floor-plan card and "Scan another room" on phones that cannot capture.

## Consequences

- Tenant deletion adds one nullable column and one endpoint; no change to existing rows.
- Notes-only sessions are indistinguishable from LiDAR sessions in History except by the `capture_provider` field. No user-facing flag yet; can be added later.
- Neither decision touches the share-code model; share revocation remains explicit via rotate-token.
- Revisit if the pilot grows to multi-tenant: per-org isolation will need a new ADR.

