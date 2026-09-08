enum MeasurementUnit: String, CaseIterable, Identifiable {
    case metric
    case imperial

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .metric: return "Metric (m2)"
        case .imperial: return "Imperial (sqft)"
        }
    }
}
