# Web viewer

Local dev tool for looking at Scan Service output without curl/Postman or raw JSON. Not
a product surface — see `../WEB_VIEWER_PLAN.md` (gitignored, local planning note) for
the full rationale. This README is the tracked, kept-around version of "how to run it."

## What it is

A single static `index.html`, vanilla JS, no build step, no dependencies. Talks to the
Scan Service using nothing but its public HTTP API — the same way any real client would.
If this page can't get what it needs from the API alone, that's a real contract gap,
found early.

Deliberately outside `scan-service/`: it has no direct access to the PHP classes, the
SQLite file, or the adapter — HTTP only.

## Adapted from the original plan

The original plan sketched a "list all sessions" first slice. That was written before
the privacy/ACL work (`../docs/adr/0003-privacy-acl-session-tokens.md`) landed — there
is now deliberately no endpoint that lists every session without a token, because that
would be exactly the "anyone with the link" (or worse, "anyone at all") default hard
constraint #3 forbids. This viewer works off a specific `scan_session_id` +
`access_token` instead (with a convenience "create a test session" form so you don't
need curl to get one), which fits both the tool's actual purpose and the ACL model.

## Run it

Needs the Scan Service running first (`../scan-service/README.md`):

```
cd scan-service
php -S 127.0.0.1:8089 public/index.php
```

Then, in another shell, serve the viewer on **port 8090 specifically** — the Scan
Service's CORS header is scoped to exactly `http://127.0.0.1:8090`, not a wildcard
(`../scan-service/public/index.php`'s CORS block):

```
cd web-viewer
php -S 127.0.0.1:8090
```

Open `http://127.0.0.1:8090/` in a browser.

## Using it

1. **Create a test session** — fills in a real `property_id`/`unit_id`/`organisation_id`
   and posts to `POST /scan-sessions`. On success it auto-fills the session id and
   access token below.
2. Capture something into that session from outside the viewer — e.g. run one of
   `scan-service/net/verify_phase*.php` against a fresh session, or `curl` a fixture in
   directly (`scan-service/README.md`'s API section has the shape). The viewer doesn't
   drive capture itself — RoomPlan capture is the iOS app's job, not this tool's.
3. **Load session** — fetches the `FloorPlan` and renders rooms (area, perimeter,
   confidence, coverage score/usable), photos, and notes as plain tables.
4. **Load PNG floor plan sheet** / **Download PDF metrics** — fetches the export
   endpoints with the access token and renders/downloads the result, so you can
   eyeball that a fixture actually produced a sane-looking shape.
5. **View access log** — shows every granted/denied access attempt for that session,
   makes the audit trail (`docs/adr/0003`) glanceable instead of only a DB row.

## Known limits (deliberate)

- No session listing — see "Adapted from the original plan" above.
- No geometry rendering beyond the PNG export itself — the PNG *is* the floor plan
  drawing; this page doesn't independently draw `outline_m` a second time.
- Not the independent net. It's for looking, not for gating merges — that's still
  `scan-service/net/verify_phase*.php`.
