import SwiftUI

struct SettingsView: View {
    let onBack: () -> Void
    let onOpenTerms: () -> Void
    let onOpenDiagnostics: () -> Void

    @AppStorage("darkModeEnabled") private var darkMode: Bool = false
    @AppStorage("autoUploadWhenOnline") private var autoUpload: Bool = true
    @AppStorage("scanExportMeasurementUnit") private var exportUnitRaw: String = MeasurementUnit.metric.rawValue
    @State private var roomTypeGuess = RoomTypeGuessSettings.isEnabled
    @State private var cacheSizeLabel: String = "—"
    @State private var darkModeLocal: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            VuuroNavBar(
                title: "Settings",
                leading: {
                    VuuroNavButton("Home", icon: "chevron.left", action: onBack)
                },
                trailing: { VuuroNavSpacer() }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    identity

                    VuuroSectionLabel(text: "Appearance")
                    VuuroInputGroup {
                        VuuroInputRow(leadingIcon: "moon", label: "Dark mode", showsDivider: false) {
                            Toggle("", isOn: $darkModeLocal)
                                .labelsHidden()
                                .tint(VuuroColor.lime)
                                .onChange(of: darkModeLocal) { _, newValue in
                                    darkMode = newValue
                                }
                        }
                    }
                    .padding(.horizontal, 20)

                    VuuroSectionLabel(text: "Scanning")
                    VuuroInputGroup {
                        VuuroInputRow(
                            leadingIcon: "wand.and.stars",
                            label: "Room-type guessing",
                            showsDivider: true
                        ) {
                            Toggle("", isOn: $roomTypeGuess)
                                .labelsHidden()
                                .tint(VuuroColor.lime)
                                .onChange(of: roomTypeGuess) { _, newValue in
                                    RoomTypeGuessSettings.isEnabled = newValue
                                }
                        }
                        VuuroInputRow(
                            leadingIcon: "icloud.and.arrow.up",
                            label: "Auto-upload when online",
                            showsDivider: false
                        ) {
                            Toggle("", isOn: $autoUpload)
                                .labelsHidden()
                                .tint(VuuroColor.lime)
                        }
                    }
                    .padding(.horizontal, 20)

                    VuuroSectionLabel(text: "Export")
                    VuuroInputGroup {
                        VuuroInputRow(leadingIcon: "ruler", showsDivider: false) {
                            Picker("Measurement unit", selection: $exportUnitRaw) {
                                ForEach(MeasurementUnit.allCases) { unit in
                                    Text(unit.displayName).tag(unit.rawValue)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .tint(VuuroColor.textPrimary)
                        }
                    }
                    .padding(.horizontal, 20)

                    VuuroSectionLabel(text: "Data")
                    VuuroInputGroup {
                        Button(action: onOpenDiagnostics) {
                            VuuroInputRow(
                                leadingIcon: "list.bullet.rectangle",
                                label: "Activity log",
                                showsDivider: true
                            ) {
                                Text("View")
                                    .font(.system(size: 13))
                                    .foregroundStyle(VuuroColor.textSecondary)
                            }
                        }
                        .buttonStyle(.plain)

                        Button(action: clearCache) {
                            VuuroInputRow(
                                leadingIcon: "trash",
                                label: "Clear local cache",
                                showsDivider: false
                            ) {
                                Text(cacheSizeLabel)
                                    .font(.system(size: 13))
                                    .foregroundStyle(VuuroColor.textSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)

                    VStack(spacing: 10) {
                        Button("Terms & Privacy Policy", action: onOpenTerms)
                            .buttonStyle(.vuuroGhostSmall)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)

                    Spacer().frame(height: 32)
                }
            }
            .scrollIndicators(.hidden)
        }
        .background(VuuroColor.bgApp)
        .onAppear {
            darkModeLocal = darkMode
            computeCacheSize()
        }
        .onChange(of: darkMode) { _, newValue in
            if darkModeLocal != newValue {
                darkModeLocal = newValue
            }
        }
    }

    private var identity: some View {
        VStack(spacing: 8) {
            Text("V")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(
                    LinearGradient(
                        colors: [VuuroColor.accent, VuuroColor.lime],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: Circle()
                )
            Text("Vuuro Scan")
                .font(.system(size: 17, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(VuuroColor.textPrimary)
            Text("v1.0 · \(shortCommitSHA)")
                .font(.system(size: 13))
                .foregroundStyle(VuuroColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

    private var shortCommitSHA: String {
        let sha = BuildInfo.commitSHA
        if sha.isEmpty || sha == "unknown" { return "dev" }
        return String(sha.prefix(7))
    }

    private func computeCacheSize() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let contents = try? fm.contentsOfDirectory(
            at: tmp,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else {
            cacheSizeLabel = "0 MB"
            return
        }

        var total: Int64 = 0
        for file in contents {
            guard file.lastPathComponent.hasPrefix("floorplan-") else { continue }
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        cacheSizeLabel = Self.formatBytes(total)
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576.0
        if mb < 0.1 { return "0 MB" }
        if mb < 10 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f MB", mb)
    }

    private func clearCache() {
        FloorPlanImageCache.shared.clearAll()
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        if let contents = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
            for file in contents where file.lastPathComponent.hasPrefix("floorplan-") {
                try? fm.removeItem(at: file)
            }
        }
        computeCacheSize()
        VuuroToast.shared.show("Cache cleared")
    }
}