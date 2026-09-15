# Proposal: inspection purpose tags on photos and notes

## Status

Data-format half implemented 2026-09-15, using this proposal's own defaults below
(8-value enum, array/multi-select, optional everywhere, applied via the existing
photo/note endpoints) — not a literal sign-off from Mark on the four open questions.
Still no UI anywhere in the app, on purpose — per the punch-list framing this was scoped
under, #21 is scoping first, UI later once Mark says which tags are actually useful in
practice. Treat the vocabulary/shape below as a starting point to react to, not a decided
taxonomy, until Mark actually confirms it.

## What #21 is asking for, and what already exists today

The session already carries one purpose value, set once at capture time:
`FloorPlan.purpose` — `listing | check_in | check_out | renovation | other`
(`contracts/floorplan.schema.json`). That answers "why was this whole unit scanned."

#21 is a different, finer-grained question: why was *this specific photo* or *this
specific note* taken, within a scan whose overall purpose might already be `check_out`.
A single check-out walkthrough plausibly contains photos of pre-existing wear, new
damage, and items simply confirmed present — today those three cases are
indistinguishable in the data; they're all just entries in `photos[]`/`notes[]` with a
free-text caption or text field and nothing structured to filter or group by later.

## Proposed shape

Add one optional, additive field to each `photos[]` and `notes[]` item:

```json
"tags": {
  "type": "array",
  "items": { "type": "string", "enum": [
    "damage", "wear_and_tear", "missing_item", "safety_issue",
    "pre_existing_condition", "maintenance_needed", "confirmed_present", "other"
  ] },
  "default": []
}
```

Not required, defaults to an empty array — every photo/note already in the database
before this ships is valid with no migration. `POST /scan-sessions/{id}/photos` and
`/notes` would accept an optional `tags` array in the request body the same way `caption`/
`text` are accepted today; `POST /scan-sessions/{id}/notes/{note_id}` (the edit endpoint)
would accept it the same way it accepts `text`.

Why a fixed enum instead of free-text tags: the whole point of tagging is to filter/group
later ("show me everything tagged `damage` across this session"), which only works
reliably against a closed vocabulary. Free-text notes already exist for anything an enum
can't capture — `other` plus the existing `text`/`caption` field covers that overflow
case without inventing a second free-text field that duplicates the first.

Why per-item and not per-room: a single room can contain both a confirmed-present item
and a genuine damage note (e.g. a bedroom with an intact window but a damaged door) — a
room-level tag would force one label onto two different findings. Item-level keeps it as
granular as photos/notes already are.

## Explicitly not in this proposal

- No UI. No tag picker, no filter view, no display of tags anywhere in the iOS app or
  exports. Building that before Mark confirms these are the right categories would be
  guessing at a taxonomy nobody has used yet.
- No new endpoint. `tags` rides on the existing photo/note create and note-edit endpoints
  as one more optional field, not a separate tagging endpoint.
- No retroactive tagging of existing photos/notes. They stay `tags: []`, same as any
  future item nobody bothers to tag.
- No PDF/PNG export changes. Whether tags should ever appear in an export is a UI/exports
  decision, downstream of Mark deciding the vocabulary is right at all.

## Open questions only Mark can answer

1. **Vocabulary**: are the eight values above the right set? This list is a guess based
   on what a landlord/property-manager inspection commonly distinguishes (damage vs.
   normal wear vs. missing vs. safety vs. pre-existing vs. maintenance vs. simply
   confirmed present) — not sourced from any real inspection workflow at
   athomevastgoed/staffhousing/vuuro.
2. **Multi-select or single**: proposed as an array (a photo could plausibly be both
   `damage` and `safety_issue`) — confirm that's wanted rather than one tag per item.
3. **Required at some point**: should tagging ever become mandatory for a `check_out`
   purpose session specifically, or does it stay optional everywhere indefinitely?
4. **Who applies it**: on-device at capture time (the person scanning taps a tag), or
   later during a review pass by someone else entirely? This affects where UI would
   eventually go — the live capture screen vs. the History/gallery review flow.

## Done when

Data-format half: implemented and tested (schema, `POST /photos`, `POST /notes`,
`POST /notes/{note_id}` all accept/validate/return `tags`; see
`scan-service/tests/repository_test.php` and `scan-service/net/verify_crud.php`'s
"#21 inspection purpose tags" section). Still open: the four questions above are
unanswered by Mark as of this writing — the vocabulary/multi-select/required-when/
who-applies choices baked into the implementation are this proposal's own defaults, not
his confirmed answers. UI: not started, blocked on that confirmation same as before.
