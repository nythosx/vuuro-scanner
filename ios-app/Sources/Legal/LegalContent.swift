
import Foundation

struct LegalSection: Identifiable {
    let id = UUID()
    let heading: String
    let body: String
}

enum LegalDocument {
    static let currentVersion = "1.0"
    static let effectiveDate = "2026-09-16"

    static let termsOfService: [LegalSection] = [
        LegalSection(
            heading: "1. Acceptance of these Terms",
            body: "By starting a scan with Vuuro Scan, you agree to these Terms of Service and to the Privacy Policy below. If you do not agree, do not use the app to capture, upload, or export a scan. These Terms apply to whoever operates the app in the field — the \"user\" — separately from any tenant or occupant whose consent is captured for a specific unit, which is addressed in Section 3."
        ),
        LegalSection(
            heading: "2. What this app does",
            body: "Vuuro Scan uses Apple RoomPlan and your device's LiDAR sensor to capture the geometry of a room or unit, and turns that capture into a floor plan with area, perimeter, and related measurements, plus any photos and notes you attach. These measurements are indicative and NEN2580-inspired — they are not a certified survey, and must not be relied on as one for legal, tax, valuation, or regulatory purposes without independent verification."
        ),
        LegalSection(
            heading: "3. Occupant consent",
            body: "If a unit is occupied, you confirm — before scanning — that you have obtained the occupant's consent to be scanned, in whatever form is required by your organisation's policy and applicable local law. Vuuro Scan records that you toggled this confirmation on; it does not itself obtain, verify, or store proof of the occupant's consent beyond that flag. Getting real, valid consent is your responsibility, not the app's."
        ),
        LegalSection(
            heading: "4. Your account for this scan",
            body: "Each scan session is tied to a property ID, unit ID, and organisation ID you enter, and to an access token generated for that session. You're responsible for keeping that token, and any share code you generate for it, only with people you intend to give full access (view, export, and delete) to that scan."
        ),
        LegalSection(
            heading: "5. Acceptable use",
            body: "You agree to use the app only for legitimate property inspection, listing, maintenance, or management purposes your organisation authorizes, and not to scan a space you don't have the right to scan, or a person without their knowledge where that's required by law."
        ),
        LegalSection(
            heading: "6. No warranty",
            body: "The app, and every floor plan, measurement, photo, or export it produces, is provided \"as is,\" without warranty of any kind, express or implied, including accuracy, fitness for a particular purpose, or non-infringement. RoomPlan and LiDAR capture have known real-world limits (reflective or transparent surfaces, unusual room shapes, low light) that can affect accuracy."
        ),
        LegalSection(
            heading: "7. Limitation of liability",
            body: "To the maximum extent permitted by law, the app's provider is not liable for any indirect, incidental, or consequential damages arising from your use of the app or reliance on its output, including decisions made based on an indicative measurement."
        ),
        LegalSection(
            heading: "8. Changes to these Terms",
            body: "These Terms may be updated as the app changes. The version and effective date at the top of this screen tell you which version you're looking at. Continuing to use the app after an update means you accept the revised Terms."
        ),
        LegalSection(
            heading: "9. Contact",
            body: "Questions about these Terms should go to the organisation that issued you this app, or to Vuuro directly if you obtained it from Vuuro."
        ),
    ]

    static let privacyPolicy: [LegalSection] = [
        LegalSection(
            heading: "1. What we collect",
            body: "When you use Vuuro Scan, the app collects: the property, unit, and organisation identifiers you enter; room geometry captured by RoomPlan (walls, floors, openings, and object positions); any photos and notes you attach; the approximate device location at the time of a scan, if you allow it (this is optional — declining it only skips the location, the scan still works); and technical data needed to operate the session, such as your access token and diagnostic logs stored on your own device."
        ),
        LegalSection(
            heading: "2. How it's used",
            body: "This data is used to build the floor plan and exports (image and PDF) for the property/unit you scanned, to let authorized people view or export that scan later, and to maintain an access log of who viewed or exported it."
        ),
        LegalSection(
            heading: "3. Where it's stored",
            body: "Scan data is stored on the Scan Service instance your organisation operates or has configured this app to point at — not on a Vuuro-operated cloud, unless your organisation's Scan Service happens to be hosted by Vuuro. Ask your organisation where that is if you need to know. Your device also keeps a local, on-device record of scans you've made (History), independent of the server."
        ),
        LegalSection(
            heading: "4. Sharing",
            body: "A scan is only accessible with its access token. If you generate a share code to give someone else access, they receive full access to that scan (view, export, and delete) — only share it with someone you trust. We do not sell scan data or share it with third parties outside your organisation's own Scan Service."
        ),
        LegalSection(
            heading: "5. Retention and deletion",
            body: "You can remove a scan from your device's local History at any time (this doesn't delete it from the server), or delete it permanently from the server if you have access to that scan — this removes its rooms, photos, and notes and cannot be undone. Your organisation's own retention policy governs how long server-side data is kept beyond that."
        ),
        LegalSection(
            heading: "6. Security",
            body: "We take reasonable technical and organizational measures to protect data captured through the app, including per-session access tokens and a per-scan access log. No method of transmission or storage is completely secure, and no system can be guaranteed 100% secure."
        ),
        LegalSection(
            heading: "7. Children's privacy",
            body: "This app is intended for use by property professionals and is not directed at children. It is not knowingly used to collect data from children."
        ),
        LegalSection(
            heading: "8. Your rights",
            body: "Depending on where you or the property are located, you may have rights to access, correct, or request deletion of data associated with a scan. Requests should go through your organisation, since they control the Scan Service the data is stored on."
        ),
        LegalSection(
            heading: "9. Changes to this policy",
            body: "This policy may be updated as the app changes. The version and effective date at the top of this screen tell you which version you're looking at."
        ),
    ]
}
