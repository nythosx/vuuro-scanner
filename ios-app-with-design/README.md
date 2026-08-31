# Vuuro Scan — iOS App, branded restyle (`ios-app-with-design/`)

An optional, separate copy of `ios-app/` restyled to vuuro.com's actual brand
(`Sources/Design/VuuroDesign.swift` — color/type/button tokens pulled from
vuuro.com's own computed CSS). Not part of the direction brief. Kept fully
independent from `ios-app/` on purpose, so nothing here can ever affect that app's own
state or verification status.

## What's different from `ios-app/`

Only presentation — colors, type, button styling via `VuuroDesign.swift`. No intended
business-logic changes; if a diff ever shows logic drift between the two copies, that's
a bug in this copy, not an intentional divergence.

## Verification status

- **Not covered by CI.** `.github/workflows/ios-build.yml` builds `ios-app/` only.
- **Not appetize.io-tested.** Unlike `ios-app/`, this copy hasn't been run end to end on
  a cloud simulator.
- Its own `Sources/Debug/FakeLidarMode.swift` and `DebugScanServiceURL.swift` fallbacks
  are already reset to inert defaults (`false` / `nil`) — there's no in-flight
  appetize.io testing session against this copy to reset later.

## Promotion decision (open)

Per root `ARCHITECTURE.md`'s roadmap: if this is ever promoted, diff it against
`ios-app/` for business-logic drift first, then either point CI at it or fold it back
into `ios-app/` and retire this copy. Until that decision is made, treat this directory
as a design reference, not a build target.
