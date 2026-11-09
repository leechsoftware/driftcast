import AppKit
import Foundation

/// The picture shown for a few seconds when a video starts on this Mac or an AirPlay TV: the
/// poster on the left and the title with what is known about the film on the right, on black.
/// Drawn here rather than by ffmpeg, which has no text filter in every build.
enum TitleCard {
    static let seconds = 5.0

    /// A JPEG of `size` (made even, at least 320 x 180) for the encoder.
    static func render(poster: Data?, title: String, details: MovieDetails?, size: CGSize) -> Data? {
        let width = max(320, Int(size.width) / 2 * 2), height = max(180, Int(size.height) / 2 * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }

        let w = CGFloat(width), h = CGFloat(height)
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()

        var textLeft = w * 0.08
        if let poster, let image = NSImage(data: poster), image.size.width > 0, image.size.height > 0 {
            let scale = min(h * 0.72 / image.size.height, w * 0.34 / image.size.width)
            let drawn = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let rect = NSRect(x: w * 0.08, y: (h - drawn.height) / 2, width: drawn.width, height: drawn.height)
            // A soft shadow behind the poster, then the poster itself with rounded corners.
            NSGraphicsContext.current?.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowBlurRadius = h * 0.025
            shadow.shadowOffset = NSSize(width: 0, height: -h * 0.01)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
            shadow.set()
            NSColor(white: 0.1, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: h * 0.01, yRadius: h * 0.01).fill()
            NSGraphicsContext.current?.restoreGraphicsState()
            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: h * 0.01, yRadius: h * 0.01).addClip()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.current?.restoreGraphicsState()
            textLeft = rect.maxX + w * 0.05
        }

        // The words, top to bottom, with their size and colour.
        struct Line {
            var text: String
            var size: CGFloat
            var color: NSColor
            var weight: NSFont.Weight
            var maxLines: Int
        }
        let white = NSColor.white, grey = NSColor(white: 0.72, alpha: 1)
        let gold = NSColor(red: 1, green: 0.84, blue: 0.4, alpha: 1)
        var lines: [Line] = []
        if let d = details, d.isEpisode {
            lines.append(Line(text: d.showTitle ?? d.title, size: h * 0.07, color: white, weight: .bold, maxLines: 2))
            if let label = d.episodeLabel { lines.append(Line(text: label, size: h * 0.036, color: grey, weight: .medium, maxLines: 1)) }
            if let name = d.episodeTitle { lines.append(Line(text: name, size: h * 0.05, color: white, weight: .semibold, maxLines: 2)) }
            let facts: [String] = [d.airDate, d.network, d.runtimeText].compactMap { $0 }
            if !facts.isEmpty { lines.append(Line(text: facts.joined(separator: "  ·  "), size: h * 0.03, color: grey, weight: .regular, maxLines: 1)) }
        } else {
            lines.append(Line(text: details?.title ?? title, size: h * 0.075, color: white, weight: .bold, maxLines: 2))
            let year: String? = details?.year.map { String($0) }
            let facts: [String] = [year, details?.runtimeText, details?.certificate].compactMap { $0 }
            if !facts.isEmpty { lines.append(Line(text: facts.joined(separator: "  ·  "), size: h * 0.034, color: grey, weight: .regular, maxLines: 1)) }
            if let genres = details?.genres, !genres.isEmpty {
                lines.append(Line(text: genres.joined(separator: ", "), size: h * 0.03, color: grey, weight: .regular, maxLines: 1))
            }
            if let directors = details?.directors, !directors.isEmpty {
                lines.append(Line(text: "Directed by " + directors.joined(separator: ", "), size: h * 0.032, color: white, weight: .regular, maxLines: 1))
            }
            if let cast = details?.cast, !cast.isEmpty {
                lines.append(Line(text: "Starring " + cast.prefix(5).joined(separator: ", "), size: h * 0.032, color: white, weight: .regular, maxLines: 2))
            }
        }
        if let ratings = details?.ratings, !ratings.isEmpty {
            let shown: [String] = ratings.prefix(3).map { rating in
                let value = rating.value.split(separator: "/").first.map(String.init) ?? rating.value
                return "\(rating.source) \(value)"
            }
            lines.append(Line(text: shown.joined(separator: "   "), size: h * 0.032, color: gold, weight: .semibold, maxLines: 1))
        }

        let textWidth = max(w * 0.3, w * 0.92 - textLeft)
        var measured: [(NSAttributedString, CGFloat)] = []
        var total: CGFloat = 0
        for (index, line) in lines.enumerated() {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: line.size, weight: line.weight),
                .foregroundColor: line.color,
                .paragraphStyle: paragraph,
            ]
            let string = NSAttributedString(string: line.text, attributes: attributes)
            let bounds = string.boundingRect(with: NSSize(width: textWidth, height: line.size * 1.3 * CGFloat(line.maxLines)),
                                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            let lineHeight = ceil(bounds.height) + (index == 0 ? h * 0.02 : h * 0.012)
            measured.append((string, lineHeight))
            total += lineHeight
        }
        var y = (h + total) / 2   // the top of the block, in a bottom-left coordinate system
        for (string, lineHeight) in measured {
            let rect = NSRect(x: textLeft, y: y - lineHeight, width: textWidth, height: lineHeight)
            string.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            y -= lineHeight
        }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
    }

    /// ffmpeg arguments turning the card into a short fMP4 HLS clip (`intro-init.mp4`,
    /// `intro-0.m4s`, `intro.m3u8`) with silent stereo AAC, fading in and out.
    static func ffmpegArguments(card: URL, size: CGSize, hardware: Bool, outputDirectory dir: URL) -> [String] {
        let width = max(320, Int(size.width) / 2 * 2), height = max(180, Int(size.height) / 2 * 2)
        var args = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y",
                    "-loop", "1", "-framerate", "24", "-i", card.path,
                    "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000",
                    "-t", String(format: "%.2f", seconds),
                    "-vf", String(format: "scale=%d:%d,format=yuv420p,fade=t=in:st=0:d=0.4,fade=t=out:st=%.2f:d=0.5", width, height, seconds - 0.5),
                    "-map", "0:v", "-map", "1:a"]
        if hardware {
            args += ["-c:v", "h264_videotoolbox", "-b:v", "6000k", "-g", "120", "-profile:v", "high", "-allow_sw", "1", "-realtime", "0"]
        } else {
            args += ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-profile:v", "high"]
        }
        args += ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
                 "-c:a", "aac", "-b:a", "96k", "-ac", "2", "-ar", "48000", "-shortest",
                 "-f", "hls", "-hls_time", "10", "-hls_list_size", "0", "-hls_segment_type", "fmp4",
                 "-hls_fmp4_init_filename", "intro-init.mp4", "-hls_flags", "independent_segments+temp_file",
                 "-hls_segment_filename", dir.appendingPathComponent("intro-%d.m4s").path,
                 dir.appendingPathComponent("intro.m3u8").path]
        return args
    }
}
