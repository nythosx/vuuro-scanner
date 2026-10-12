# Real estate platform integration API

## Overview

This is the interface the Scan Service exposes for a real estate platform to
pull finished floor-plan scans out of Vuuro Scan. Today it's used for
internal test scans and manual `.vuuroscan` file handoff; the same endpoints
are meant to be the eventual production path for a platform to look up a
property's scans, export a floor plan, or import a `.vuuroscan` bundle
someone hands it directly.

Base URL is wherever the Scan Service is deployed, e.g.
`https://scan.example.com`. All request/response bodies are JSON unless
noted otherwise.

## Authentication

Platform-facing endpoints require an admin key, sent as:

```
X-Admin-Api-Key: <key>
```

The key is whatever value the server was started with in
`SCAN_SERVICE_ADMIN_API_KEY`. If that env var is unset or empty, every
admin-gated endpoint returns `401 invalid_or_missing_admin_api_key` —
there's no way to reach them at all until the operator sets it.

Per-session endpoints (capture, attach photos/notes, most reads) instead use
a per-session `X-Scan-Access-Token` issued when the session was created —
see `README.md`'s main API reference for those. A subset of read-only
per-session actions (`read`, `view_access_log`, `export_png`, `export_pdf`,
`export_svg`, `export_vuuroscan`) also accept the admin key as an
alternative to the session's own token, which is what lets the platform
pull any session's floor plan/exports without needing each session's
individual token.

## Endpoint reference

### `GET /scan-sessions?property_id=X&unit_id=Y&organisation_id=Z`

Admin-only. Looks up sessions by filter. At least one of `property_id`,
`unit_id`, or `organisation_id` must be given, or the request is rejected
with `422 missing_filter`.

**Headers:** `X-Admin-Api-Key: <key>`

**Query params:** `property_id`, `unit_id`, `organisation_id` — all
optional individually, but at least one required.

**Response shape:**

```json
{
  "sessions": [
    {
      "id": "…",
      "property_id": "…",
      "unit_id": "…",
      "organisation_id": "…",
      "purpose": "listing",
      "status": "captured",
      "created_at": "2026-09-01T10:00:00+00:00",
      "occupied": false,
      "consent_obtained": true
    }
  ]
}
```

**Example request:**

```
GET /scan-sessions?property_id=prop-123&unit_id=unit-4b HTTP/1.1
X-Admin-Api-Key: <key>
```

**Example response:** `200 OK`, body as above with one or more `sessions`
entries (empty array if nothing matches).

---

### `GET /scan-sessions/{id}`

Returns the session's captured floor plan, if any.

**Headers:** `X-Admin-Api-Key: <key>` (or the session's own
`X-Scan-Access-Token`).

**Response shape (no capture yet):**

```json
{ "scan_session_id": "…", "status": "pending", "floor_plan": null }
```

**Response shape (captured):** the full `floor_plan` object — same shape
returned from every capture endpoint (`rooms`, `photos`, `notes`,
`capture_location`, etc.). See `README.md`'s API reference for the field
list.

**Example request:**

```
GET /scan-sessions/8f2c…/HTTP/1.1
X-Admin-Api-Key: <key>
```

**Example response:** `200 OK` with either shape above, or `401
invalid_or_missing_access_token` if neither an admin key nor a valid
session token was presented.

---

### `GET /scan-sessions/{id}/access-log`

Returns the audit trail of every authorization attempt against this
session (granted, denied, expired, admin reads, etc.).

**Headers:** `X-Admin-Api-Key: <key>` (or the session's own token).

**Response shape:**

```json
{
  "scan_session_id": "…",
  "access_log": [
    { "action": "read", "outcome": "granted_admin", "occurred_at": "…" }
  ]
}
```

**Example request:**

```
GET /scan-sessions/8f2c…/access-log HTTP/1.1
X-Admin-Api-Key: <key>
```

**Example response:** `200 OK` with the shape above.

---

### `GET /scan-sessions/{id}/export/floorplan.png`

Renders the floor plan as a PNG image.

**Headers:** `X-Admin-Api-Key: <key>` (or the session's own token).

**Query params (all optional):**
- `layout` — `auto` (default) or `tiles`
- `room_id` — render a single room instead of the whole unit
- `unit` — `metric` (default) or `imperial`
- `label` — text label printed on the image, max 120 characters

**Response:** raw PNG bytes, `Content-Type: image/png`. `404
no_floor_plan_yet` if the session has no captured floor plan.

**Example request:**

```
GET /scan-sessions/8f2c…/export/floorplan.png?unit=imperial HTTP/1.1
X-Admin-Api-Key: <key>
```

**Example response:** `200 OK`, binary PNG body.

---

### `GET /scan-sessions/{id}/export/floorplan.pdf`

Same parameters and auth as the PNG export. Returns a multi-page PDF
(`Content-Type: application/pdf`) with the rendered floor plan plus any
attached photos/notes.

**Example request:**

```
GET /scan-sessions/8f2c…/export/floorplan.pdf HTTP/1.1
X-Admin-Api-Key: <key>
```

**Example response:** `200 OK`, binary PDF body.

---

### `GET /scan-sessions/{id}/export/floorplan.svg`

Same parameters and auth as the PNG export. Returns
`Content-Type: image/svg+xml`.

**Example request:**

```
GET /scan-sessions/8f2c…/export/floorplan.svg HTTP/1.1
X-Admin-Api-Key: <key>
```

**Example response:** `200 OK`, SVG markup body.

---

### `GET /scan-sessions/{id}/export/vuuroscan`

Returns the full `.vuuroscan` bundle — the format described below — as a
downloadable JSON file (`Content-Disposition: attachment`).

**Headers:** `X-Admin-Api-Key: <key>` (or the session's own token).

**Example request:**

```
GET /scan-sessions/8f2c…/export/vuuroscan HTTP/1.1
X-Admin-Api-Key: <key>
```

**Example response:** `200 OK`, `Content-Type: application/json`, body is
a `.vuuroscan` bundle (see next section for the shape). `404
no_floor_plan_yet` if nothing's been captured yet.

---

### `POST /imported-scans`

Admin-only. Accepts a `.vuuroscan` bundle uploaded as
`multipart/form-data` and stores it as an import record. This is how the
platform hands a scan it received some other way (e.g. emailed a file)
back into the Scan Service for reference.

**Headers:** `X-Admin-Api-Key: <key>`

**Body:** `multipart/form-data` with one field, `file`, containing the
`.vuuroscan` file.

**Validation:** rejects anything that isn't valid JSON, isn't `format:
"vuuroscan/1"`, is missing the `session` or `floor_plan` block, or (if
`SCAN_SERVICE_EXPORT_SECRET` is configured) has a signature that doesn't
verify.

**Example request:**

```
POST /imported-scans HTTP/1.1
X-Admin-Api-Key: <key>
Content-Type: multipart/form-data; boundary=----X

------X
Content-Disposition: form-data; name="file"; filename="scan-prop-123-unit-4b.vuuroscan"
Content-Type: application/json

{ "format": "vuuroscan/1", … }
------X--
```

**Example response:** `201 Created`

```json
{
  "import_id": "…",
  "format": "vuuroscan/1",
  "session_id": "…",
  "property_id": "…",
  "unit_id": "…",
  "organisation_id": "…",
  "purpose": "listing",
  "signature_status": "verified",
  "imported_at": "2026-09-22T10:00:00+00:00"
}
```

---

### `GET /imported-scans`

Admin-only. Lists previously imported scans, optionally filtered by
`property_id`, `unit_id`, `organisation_id` (all optional, any combination).

**Headers:** `X-Admin-Api-Key: <key>`

**Example request:**

```
GET /imported-scans?property_id=prop-123 HTTP/1.1
X-Admin-Api-Key: <key>
```

**Example response:** `200 OK`

```json
{ "imports": [ { "import_id": "…", "property_id": "…", "…": "…" } ] }
```

---

### `GET /imported-scans/{import_id}`

Admin-only. Returns one imported scan record, including its full stored
bundle payload.

**Headers:** `X-Admin-Api-Key: <key>`

**Example request:**

```
GET /imported-scans/9a1b… HTTP/1.1
X-Admin-Api-Key: <key>
```

**Example response:** `200 OK` with the full import record, or `404
import_not_found`.

## The `.vuuroscan` bundle format

Top-level fields:

- `format` — always `"vuuroscan/1"`. This is the version field; a future
  incompatible bundle shape would ship as `"vuuroscan/2"`, and consumers
  should reject any `format` they don't recognize rather than guess.
- `exported_at` — ISO 8601 UTC timestamp of when the bundle was generated.
- `scan_service_base_url` — the base URL of the Scan Service instance that
  produced the bundle, so a consumer can trace it back.
- `session` — `id`, `property_id`, `unit_id`, `organisation_id`, `purpose`,
  `created_at`, `occupied`, `consent_obtained`.
- `floor_plan` — the full floor plan object (same shape as
  `GET /scan-sessions/{id}`'s response).
- `exports` — `png_base64` and `pdf_base64`, each either a base64-encoded
  rendering or `null` if that particular render failed server-side (a
  render failure does not fail the whole export).
- `signature` — `{ "algorithm": "hmac-sha256", "value": "…" }` if
  `SCAN_SERVICE_EXPORT_SECRET` was configured when the bundle was made, or
  `null` with a `signature_note` explaining why if it wasn't.

The signature, when present, is an HMAC-SHA256 over the canonical JSON
encoding of every field except `signature` itself, keyed with
`SCAN_SERVICE_EXPORT_SECRET`. `POST /imported-scans` recomputes and
verifies this signature against the server's own configured secret; a
mismatch is rejected with `422 signature_invalid`.

## Rate limits

Every endpoint is rate-limited per session id (or per client IP for
session-less/admin endpoints), in a rolling window. The defaults (some
configurable via env vars, see `README.md`):

- Request body reads (any POST, per client IP): 500 per 300s window (`SCAN_SERVICE_RATE_LIMIT_POST_BODY_READ_MAX` / `_WINDOW_SECONDS`)
- Session creation: 60 per 600s window (`SCAN_SERVICE_RATE_LIMIT_CREATE_SESSION_MAX` / `_WINDOW_SECONDS`)
- List sessions (admin): 60 per 300s
- Read session / access log: 120 per 300s
- Rotate token: 10 per 300s
- Capture: 60 per 300s
- Replace rooms: 20 per 300s
- Attach photo / note: 60 per 300s (photo), 600 per 300s (note)
- PNG / PDF / SVG / vuuroscan export: 30 per 300s each (independent buckets)
- Delete session: 10 per 300s
- Publish to platform: 10 per 300s
- Admin import (`POST /imported-scans`): 30 per 300s
- Admin imports list/read: 60 / 120 per 300s
- Denied-auth attempts (wrong/missing token or admin key): 20-30 per 300s,
  tracked separately so repeated bad auth doesn't consume a legitimate
  caller's budget

A rate-limited request gets `429 rate_limited` with a `Retry-After` header
and the configured `limit`/`window_seconds` in the body.

## Known limits

- **Plaintext DB tokens.** Session access tokens are stored as plaintext in
  the SQLite database, not hashed. Anyone with read access to the database
  file has every active session's token.
- **No TLS in the current deployment.** The native-PHP run mode
  (`README.md`'s "Run it (native PHP, no Docker)") serves plain HTTP. The
  Docker Compose setup terminates TLS at Caddy, but only when
  `SCAN_SERVICE_DOMAIN` is a real, publicly resolvable domain — there is no
  TLS for local/LAN testing.
- **No user accounts.** There's no login, no per-user permissions, no
  audit trail of *who* used the admin key — only *that* it was used
  (logged as `granted_admin` in each session's access log).
- **Per-session tokens only.** Access to a scan is entirely controlled by
  possessing that session's token (or the admin key). There's no
  revocation short of rotating the token or deleting the session; anyone
  who has ever had a token retains access until then.
