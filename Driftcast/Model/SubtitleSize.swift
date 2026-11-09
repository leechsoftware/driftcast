import Foundation

/// How big subtitles are drawn, as a multiple of the normal size: 1.0 is normal, 2.0 twice as
/// big. One number for every output: this Mac draws its subtitles with it, a Chromecast is told
/// it, and it is kept in the preferences so it survives restarts.
enum SubtitleSize {
    static let range = 0.6...2.0
    static let step = 0.1
    /// The sizes offered as a list where a slider can't be shown.
    static let presets = [0.8, 1.0, 1.2, 1.5, 2.0]

    static var current: Double {
        get { normalized(Prefs.double(Prefs.subtitleScale)) }
        set { Prefs.defaults.set(normalized(newValue), forKey: Prefs.subtitleScale) }
    }

    /// Snapped to the step and kept inside the range, so 1.1000000000000001 never appears.
    static func normalized(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1.0 }
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        // Rounded to two decimals as well, because 6 * 0.1 is 0.6000000000000001 in binary.
        return ((clamped / step).rounded() * step * 100).rounded() / 100
    }

    static func label(_ value: Double) -> String { "\(Int((normalized(value) * 100).rounded()))%" }

    static func increase() { current = current + step }
    static func decrease() { current = current - step }
    static var canIncrease: Bool { current < range.upperBound - step / 2 }
    static var canDecrease: Bool { current > range.lowerBound + step / 2 }
}
