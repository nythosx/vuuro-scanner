import Foundation
import simd
import UIKit

enum DollhouseTheme: String, CaseIterable, Identifiable {
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var backgroundColor: UIColor {
        switch self {
        case .light: return UIColor(red: 0.97, green: 0.96, blue: 0.94, alpha: 1.0)
        case .dark: return UIColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1.0)
        }
    }

    var exteriorWallColor: SIMD4<Float> {
        switch self {
        case .light: return SIMD4(0.82, 0.81, 0.79, 1.0)
        case .dark: return SIMD4(0.80, 0.78, 0.75, 1.0)
        }
    }

    var interiorWallColor: SIMD4<Float> {
        switch self {
        case .light: return SIMD4(0.90, 0.89, 0.87, 1.0)
        case .dark: return SIMD4(0.68, 0.66, 0.63, 1.0)
        }
    }

    var doorColor: SIMD4<Float> {
        SIMD4(1.0, 0.51, 0.07, 1.0)
    }

    var windowColor: SIMD4<Float> {
        SIMD4(0.18, 0.76, 1.0, 1.0)
    }

    var environmentIntensity: CGFloat {
        switch self {
        case .light: return 0.9
        case .dark: return 0.5
        }
    }

    var ambientIntensity: CGFloat {
        switch self {
        case .light: return 750
        case .dark: return 400
        }
    }

    var directionalIntensity: CGFloat {
        switch self {
        case .light: return 900
        case .dark: return 600
        }
    }
}
