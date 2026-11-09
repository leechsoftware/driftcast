import Foundation

/// UserDefaults keys and typed accessors. Views bind to these keys with @AppStorage.
enum Prefs {
    static let ffmpegDirectory = "ffmpegDirectory"
    static let hardwareEncoding = "hardwareEncoding"
    static let videoBitrate = "videoBitrateMbps"
    static let maxResolution = "maxResolution"
    static let forceTranscode = "forceTranscode"
    static let castHEVC = "castHEVC"
    static let castAudioCodec = "castAudioCodec"
    static let castPassthrough = "castSurroundPassthrough"
    static let appleSurround = "appleSurround"
    static let audioLanguage = "preferredAudioLanguage"
    static let subtitleLanguage = "preferredSubtitleLanguage"
    /// Until 2026-11-07 the "audio in another language" rule was this toggle; it is migrated into `subtitleAuto`.
    static let autoSubtitles = "autoEnableSubtitles"
    /// When subtitles come on by themselves: a `SubtitleAuto` raw value.
    static let subtitleAuto = "turnOnSubtitles"
    /// Ask OpenSubtitles for subtitles as a video starts when the rule wants them and the file has none.
    static let autoSearchSubtitles = "searchSubtitlesAutomatically"
    /// "I don't care about subtitles": hides the closed-caption notices (video window bar, details panel section).
    static let hideSubtitleNotices = "hideSubtitleNotices"
    static let subtitleScale = "subtitleScale"
    static let openSubtitlesKey = "openSubtitlesAPIKey"
    static let resumePlayback = "resumePlayback"
    static let autoPlayNext = "autoPlayNext"
    static let ocrSubtitles = "ocrPictureSubtitles"
    static let autoUpdateCheck = "checkForUpdatesAutomatically"
    /// Posters, plot, people and ratings from Apple, TVmaze and OMDb.
    static let onlineDetails = "lookUpDetailsOnline"
    static let omdbKey = "omdbAPIKey"
    /// A few seconds of poster and title before a video starts.
    static let titleCard = "showTitleCard"
    /// Whether the details panel beside the playlist is open.
    static let showDetails = "showDetails"
    /// Which Settings tab is showing, so menus can open Settings on a particular one.
    static let settingsTab = "settingsTab"

    static func register() {
        let systemLanguage = Locale.current.language.languageCode?.identifier ?? "en"
        // Before the registered defaults exist, object(forKey:) tells a stored value from none.
        if UserDefaults.standard.object(forKey: subtitleAuto) == nil, UserDefaults.standard.bool(forKey: autoSubtitles) {
            UserDefaults.standard.set(SubtitleAuto.foreign.rawValue, forKey: subtitleAuto)
        }
        UserDefaults.standard.register(defaults: [
            hardwareEncoding: true,
            videoBitrate: 12,
            maxResolution: 2160,
            forceTranscode: false,
            castHEVC: EncoderSettings.CastHEVC.auto.rawValue,
            castAudioCodec: EncoderSettings.CastAudio.aac.rawValue,
            castPassthrough: false,
            appleSurround: EncoderSettings.AppleSurround.eac3.rawValue,
            audioLanguage: systemLanguage,
            subtitleLanguage: systemLanguage,
            autoSubtitles: false,
            subtitleAuto: SubtitleAuto.never.rawValue,
            autoSearchSubtitles: false,
            hideSubtitleNotices: false,
            subtitleScale: 1.0,
            resumePlayback: true,
            autoPlayNext: true,
            ocrSubtitles: true,
            autoUpdateCheck: true,
            onlineDetails: true,
            titleCard: true,
        ])
    }

    static var defaults: UserDefaults { .standard }
    static func bool(_ key: String) -> Bool { defaults.bool(forKey: key) }
    static func int(_ key: String) -> Int { defaults.integer(forKey: key) }
    static func double(_ key: String) -> Double { defaults.double(forKey: key) }
    static func string(_ key: String) -> String { defaults.string(forKey: key) ?? "" }
}

/// When subtitles come on without being asked for (Settings > Subtitles > Turn on subtitles).
enum SubtitleAuto: String, CaseIterable {
    case never
    /// When the audio isn't in the preferred subtitle language.
    case foreign
    case always

    static var current: SubtitleAuto { SubtitleAuto(rawValue: Prefs.string(Prefs.subtitleAuto)) ?? .never }
}

/// Formats seconds as 1:02:03 or 2:03.
func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let total = Int(seconds.rounded(.down))
    let h = total / 3600, m = (total / 60) % 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
