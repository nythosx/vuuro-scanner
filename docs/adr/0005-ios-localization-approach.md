# 0005. iOS localization: String Catalog + environment locale override, hand-authored

## Status

Accepted, partial coverage by design. Revisit once someone opens this project in real
Xcode (see `docs/adr/0001`) — Xcode's own "Extract to String Catalog" build action
should replace the hand-diffed coverage process described below.

## Context

The app needed multi-language support (English + Dutch, the market this build targets)
plus a user-facing way to switch language without relying on the device's system
language. Apple's current recommended mechanism for this is a SwiftUI String Catalog
(`Localizable.xcstrings`) — a single JSON file mapping each source string to its
translations per language, compiled into `.strings`/`.stringsdict` at build time.

Two constraints shaped how this was actually built, both from `ios-app/README.md`'s
verification-status section:

1. No Mac/Xcode access on the machine doing this work (same constraint as `0001`) — so
   Xcode's built-in "Extract to String Catalog" action, which would normally scan the
   whole target and generate catalog entries (including the format-specifier keys for
   interpolated strings) automatically, was not available. The catalog had to be
   hand-authored.
2. `project.yml` (XcodeGen) generates the Xcode project fresh on every CI run and for
   anyone opening this locally — the catalog just needed to be listed under the target's
   `resources:` to be picked up; no manual Xcode project surgery required.

## Decision

- `ios-app/Resources/Localizable.xcstrings`, source language `en`, one additional
  language `nl`. Registered in `project.yml`'s `resources:` list and declared via
  `CFBundleLocalizations: [en, nl]`.
- Every `Text("literal")`/`Button("literal")`/`Label(...)`/`Toggle("literal")`/
  `TextField("literal", ...)`/`.navigationTitle("literal")` call across `Sources/`
  already works as a SwiftUI `LocalizedStringKey` with no code change — SwiftUI looks
  the literal up in the catalog automatically once it exists in the bundle. Coverage was
  verified by mechanically extracting every such literal with `grep` and diffing it
  against the catalog's own keys (see `ios-app/README.md`'s Localization section), not
  by spot-checking a sample — closed to zero gaps as of 2026-09-16.
- **Interpolated strings are deliberately excluded** (e.g. `Text("Room \(index + 1)")`).
  SwiftUI's auto-generated catalog key for these depends on Swift's format-specifier
  inference per interpolated type (`%lld` for `Int`, `%@` for `String`, `%f` for
  `Double`, etc.) — reproducing that by hand risks a key that looks right but never
  matches at runtime, which fails silently (falls back to English) rather than loudly.
  Given no compiler/Xcode available to verify a hand-guessed key actually matches, these
  were left out rather than risk a plausible-looking but broken entry. They still render
  correctly, just always in English until Xcode's real extraction tool is run.
- In-app language switch: `Sources/Settings/AppLanguage.swift` (System default / English
  / Nederlands), stored in `@AppStorage`, applied at the app root in `VuuroScanApp` via
  `.environment(\.locale, ...)`. Exposed as a dropdown (`Picker` with `.pickerStyle(.menu)`)
  in the top-right toolbar of the first screen (New scan) — chosen over a separate
  settings screen per direct product feedback, so the control is visible without
  navigating away from the first thing a user sees.
- Corollary constraint this decision surfaced: `Date.formatted(...)` reads
  `Locale.autoupdatingCurrent`, not the environment `\.locale` this app now overrides —
  any date/time text must use `Text(date, format:)` instead, or it silently keeps
  following the device's system language regardless of the in-app choice. Fixed
  everywhere this app currently formats a date for display; flagged in the README so it
  doesn't regress the next time someone adds a new date label.

## Consequences

- Static UI text is fully translatable today and verified complete by tooling, not
  memory. Adding a third language is additive (extend the catalog, add the case to
  `AppLanguage`), no code-path changes needed.
- Interpolated/dynamic strings (room counts, captured-room tallies, etc.) stay
  English-only until this project is opened in real Xcode and someone runs "Extract to
  String Catalog," which will pick them up automatically and correctly. This is a known,
  bounded gap, not an oversight — re-running the grep-diff check in
  `ios-app/README.md`'s Localization section after that extraction will confirm nothing
  regressed.
- Nothing about this decision blocks adding more languages or completing interpolated-
  string coverage later; the catalog format and the environment-locale wiring don't need
  to change, only the catalog's contents grow.
