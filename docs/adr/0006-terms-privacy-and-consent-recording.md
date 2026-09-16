# 0006. Terms of Service / Privacy Policy: in-app draft, auto-agreement on scan start

## Status

Accepted for this build, **explicitly not legal-final**. The Terms of Service and
Privacy Policy text shipped under `ios-app/Sources/Legal/LegalContent.swift` is a draft
written to be accurate about what the app actually does, not a substitute for review by
an actual lawyer. Do not treat this ADR, or that file, as legal sign-off. Revisit before
any real commercial launch — see "What this ADR does NOT claim" below.

## Context

Commercializing this product needs the standard legal surface: Terms of Service and a
Privacy Policy, presented to whoever uses the app, with some record that they were shown
it. The request was specifically: put a notice at the bottom of the first screen stating
that using the app to scan means automatically agreeing to the terms, with a link to
read the full text elsewhere in the app — not a blocking checkbox/modal gate.

Two things this app already does shaped what the policy text could honestly say:

1. **Scan data is not stored on a Vuuro-operated cloud by default.** Per
   `ARCHITECTURE.md`'s system diagram, this app talks to a Scan Service instance the
   operating organisation runs or configures (`SCAN_SERVICE_BASE_URL`) — there is no
   central Vuuro backend in this build. The Privacy Policy says data is stored on "the
   Scan Service instance your organisation operates," not on a named Vuuro server,
   because saying otherwise would be false for this architecture.
2. **A known, real security limit already exists and is documented internally**:
   `ScanHistoryStore.swift` stores each session's access token in plaintext
   `UserDefaults`, not the Keychain (flagged in `ARCHITECTURE.md`'s Security Model
   section as "acceptable for this local-pilot window but worth fixing before any real
   deployment"). The Privacy Policy's Security section deliberately uses general
   "reasonable technical and organizational measures" language rather than claiming a
   specific standard (e.g. "military-grade encryption," "Keychain-secured") that the
   current code doesn't actually meet — an inaccurate security claim in a published
   policy is a liability, not a marketing win.

## Decision

- **No blocking consent modal.** A short disclosure line ("By scanning with this app,
  you agree to the Terms of Service and Privacy Policy.") sits in its own section at the
  very bottom of `IdentityIntakeScreen` — the first screen — under a "Read Terms of
  Service & Privacy Policy" link that opens `TermsAndPrivacyView` (a segmented
  Terms/Privacy reader, versioned and dated at the top). This matches the request:
  agreement is automatic on use, not gated behind an extra tap.
- **Agreement is still recorded, not just implied.** `LegalAgreementStore` writes the
  agreed version + timestamp to `UserDefaults` the moment `IdentityIntakeScreen`'s
  `startIfHealthy(_:)` actually starts a scan (after the health check succeeds, right
  before handing off to capture) — not when the app launches, not when the intake form
  merely renders. This is deliberately the same moment `ScanIdentity`'s existing
  `consentObtained` flag (occupant consent for an occupied unit, Section 3 of the Terms)
  is already read, so both consent-adjacent facts about a scan attach to the same event.
  This is a local, on-device record only, matching the pattern of every other user
  preference in this app (`RoomTypeGuessSettings`, `AppLanguageSettings`) — it does not
  presently sync to the Scan Service, so it does not go through the same door-locking
  guarantees session data does; see "What this ADR does NOT claim."
- **Versioned content.** `LegalDocument.currentVersion`/`effectiveDate` are separate
  constants shown in the reader. Bumping the version when the text changes, and having
  `LegalAgreementStore` compare `agreedVersion` against `LegalDocument.currentVersion`,
  is the natural next step if re-consent-on-change is ever required — not built yet,
  since no policy update has happened yet to need it.
- Distinguished explicitly, in both the code's naming and the Terms' own Section 3, from
  the pre-existing occupant-consent toggle (`ScanIdentity.consentObtained`) — that's
  consent from the scanned space's occupant, obtained by the field user outside the app;
  this ADR is about the field user's own agreement to the app's Terms as its operator.
  They are not the same consent and must not be conflated.

## What this ADR does NOT claim

- **Not legal advice, not lawyer-reviewed.** The Terms/Privacy text was written to be
  factually accurate about the app's real behavior (what data is captured, where it's
  stored, what a share code grants), not drafted or reviewed by a lawyer. Governing law,
  liability caps, and consumer-protection-specific language (e.g. GDPR data-subject
  request mechanics beyond a general "ask your organisation") are left generic on
  purpose rather than guessed at.
- **Not translated.** Per `docs/adr/0005`, the short surface strings (disclosure line,
  link text, screen title) are in the String Catalog with Dutch translations; the actual
  legal body text in `LegalContent.swift` is English-only. Translating binding legal
  text is a job for a professional/legal translator, not something to auto-translate the
  same way UI copy was handled in ADR 0005 — an imprecise translation of a legal
  document is a real risk, not a UX nice-to-have.
- **Local agreement record only, no server-side proof.** `LegalAgreementStore`'s record
  lives in the device's `UserDefaults` — reinstalling the app, or a support engineer
  inspecting server-side session data, won't find it there. If a commercial launch needs
  auditable, server-verifiable proof of agreement (e.g. for a dispute), that requires a
  new Scan Service field/endpoint recording agreement per session, which does not exist
  today and is out of scope for this change.

## Consequences

Whoever takes this to actual commercial launch (Mark, or whoever handles that) needs to:
route `LegalContent.swift`'s text through real legal review before relying on it, decide
whether local-only agreement recording is sufficient or whether it needs to move
server-side, and get the legal text professionally translated if launching in the Dutch
market specifically. None of that blocks using this build for further internal
development or a non-commercial pilot in the meantime.
