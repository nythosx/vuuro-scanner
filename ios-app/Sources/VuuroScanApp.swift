//
//  VuuroScanApp.swift
//  VuuroScan
//
//  WRITTEN, NOT COMPILED OR RUN — see Models/ScanIdentity.swift header.
//
//  Not a full app shell — there's no property/unit picker, auth, or
//  Vuuro-account wiring yet (all later, real decisions, not stubbed here).
//  This is the smallest entry point that exercises the Phase 1 path:
//  device capability check -> guided capture -> export -> upload -> show
//  the returned FloorPlan's basic dimensions. That end-to-end path is what
//  Phase 1 ("done means... basic dimensions readable end to end") needs
//  proven once a device/Xcode makes proving it possible.

import RoomPlan
import SwiftUI

@main
struct VuuroScanApp: App {
    var body: some Scene {
        WindowGroup {
            CaptureFlowView(identity: ScanIdentity(
                // Placeholder identity for a manual Phase 1 smoke test only.
                // Real identity comes from Vuuro account/property selection,
                // which does not exist in this app yet — out of scope until
                // Vuuro API coupling per CLAUDE.md.
                propertyId: "prop-manual-smoke-test",
                unitId: "unit-manual-smoke-test",
                organisationId: "org-manual-smoke-test",
                purpose: .listing,
                // Hardcoded false here ONLY because this is a placeholder
                // smoke-test identity with no real consent UI behind it yet.
                // A real property/unit picker MUST replace this with an
                // actual occupied/consent step before this ships anywhere
                // near a real occupied unit — see
                // docs/adr/0003-privacy-acl-session-tokens.md.
                occupied: false,
                consentObtained: false
            ))
        }
    }
}

struct CaptureFlowView: View {
    let identity: ScanIdentity

    @StateObject private var coordinator = CaptureCoordinator()
    @State private var floorPlan: FloorPlan?
    @State private var errorMessage: String?
    @State private var isUploading = false

    private let client = ScanServiceClient()

    var body: some View {
        Group {
            if !DeviceCapability.isRoomPlanSupported {
                UnsupportedDeviceScreen()
            } else if let floorPlan {
                ResultSummaryView(floorPlan: floorPlan)
            } else if let errorMessage {
                ErrorView(message: errorMessage) {
                    self.errorMessage = nil
                    coordinator.start()
                }
            } else {
                ZStack {
                    RoomCaptureScreen(coordinator: coordinator)
                        .ignoresSafeArea()

                    if isUploading {
                        ProgressView("Uploading capture…")
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .onAppear { coordinator.start() }
                .onChange(of: coordinator.state) { _, state in
                    handle(state)
                }
            }
        }
    }

    private func handle(_ state: CaptureCoordinator.State) {
        switch state {
        case .finished(roomAvailable: true):
            guard let room = coordinator.capturedRoom else { return }
            Task { await submit(room) }
        case .finished(roomAvailable: false):
            errorMessage = "Capture finished without a usable room."
        case .failed(let message):
            errorMessage = message
        case .scanning:
            break
        }
    }

    @MainActor
    private func submit(_ room: CapturedRoom) async {
        isUploading = true
        defer { isUploading = false }
        do {
            let session = try await client.createSession(identity: identity)
            let export = CapturedRoomExporter.export(room)
            let result = try await client.uploadCapture(sessionId: session.id, accessToken: session.accessToken, capture: export)
            floorPlan = result
        } catch {
            errorMessage = "Upload failed: \(error.localizedDescription)"
        }
    }
}

private struct ResultSummaryView: View {
    let floorPlan: FloorPlan

    var body: some View {
        List(floorPlan.rooms, id: \.roomId) { room in
            VStack(alignment: .leading, spacing: 4) {
                Text(room.label).font(.headline)
                Text(String(format: "%.2f m²", room.floorAreaM2))
                Text(String(format: "%.2f m perimeter", room.perimeterM))
                Text("Indicative — NEN2580-inspired, not certified")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // PHASES.md Phase 3: the point of this signal is showing it
                // here, before the user leaves the room — not buried in a
                // later report they'll never open.
                if !room.coverage.usable, let message = room.coverage.message {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                } else {
                    Text("Scan quality: \(room.coverage.score)/100")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Scan result")
    }
}

private struct ErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Something went wrong").font(.headline)
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Try again", action: onRetry).buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
