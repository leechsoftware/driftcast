import Foundation

/// Just enough ISO BMFF parsing to serve ffmpeg's fMP4 HLS output from several ffmpeg runs as
/// one continuous stream.
///
/// Every ffmpeg run writes `tfdt` (decode time) relative to its own first packet and records
/// the real start in the init segment's edit list. The player only ever sees one init, so each
/// segment's `tfdt` is shifted to the absolute timeline before it goes out, and `sidx` boxes,
/// which would contradict it, are blanked.
enum MP4Boxes {
    struct Track {
        var id: UInt32
        var timescale: UInt32
        /// Presentation offset the init's edit list applies, in seconds
        /// (empty edit minus the first media_time).
        var presentationOffset: Double
    }

    private static func u32(_ d: Data, _ o: Int) -> UInt32 {
        guard o + 4 <= d.count else { return 0 }
        return d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self).bigEndian }
    }

    private static func u64(_ d: Data, _ o: Int) -> UInt64 {
        guard o + 8 <= d.count else { return 0 }
        return d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt64.self).bigEndian }
    }

    /// Calls `visit` for each box in `range`, with (type, headerSize, boxStart, boxEnd).
    private static func boxes(_ d: Data, _ start: Int, _ end: Int, _ visit: (String, Int, Int, Int) -> Void) {
        var o = start
        while o + 8 <= end {
            var size = Int(u32(d, o))
            var header = 8
            let type = String(decoding: d[(o + 4)..<(o + 8)], as: UTF8.self)
            if size == 1 { size = Int(u64(d, o + 8)); header = 16 }
            if size == 0 { size = end - o }
            guard size >= header, o + size <= end else { return }
            visit(type, header, o, o + size)
            o += size
        }
    }

    /// Tracks described by an init segment.
    static func tracks(inInit d: Data) -> [Track] {
        var movieTimescale: UInt32 = 1000
        var result: [Track] = []
        boxes(d, 0, d.count) { type, h, s, e in
            guard type == "moov" else { return }
            boxes(d, s + h, e) { type, h, s, e in
                if type == "mvhd" {
                    let v = d[s + h]
                    movieTimescale = u32(d, s + h + (v == 1 ? 20 : 12))
                } else if type == "trak" {
                    var id: UInt32 = 0, ts: UInt32 = 0, empty = 0.0, mediaTime = 0.0
                    boxes(d, s + h, e) { type, h, s, e in
                        if type == "tkhd" {
                            let v = d[s + h]
                            id = u32(d, s + h + (v == 1 ? 20 : 12))
                        } else if type == "mdia" {
                            boxes(d, s + h, e) { type, h, s, _ in
                                if type == "mdhd" {
                                    let v = d[s + h]
                                    ts = u32(d, s + h + (v == 1 ? 20 : 12))
                                }
                            }
                        } else if type == "edts" {
                            boxes(d, s + h, e) { type, h, s, _ in
                                guard type == "elst" else { return }
                                let v = d[s + h]
                                let n = Int(u32(d, s + h + 4))
                                var p = s + h + 8
                                var firstMediaTimeSeen = false
                                for _ in 0..<n {
                                    let dur: Double, mt: Int64
                                    if v == 1 {
                                        dur = Double(u64(d, p)); mt = Int64(bitPattern: u64(d, p + 8)); p += 20
                                    } else {
                                        dur = Double(u32(d, p)); mt = Int64(Int32(bitPattern: u32(d, p + 4))); p += 12
                                    }
                                    if mt == -1 {
                                        empty += dur / Double(max(1, movieTimescale))
                                    } else if !firstMediaTimeSeen {
                                        firstMediaTimeSeen = true
                                        mediaTime = Double(mt)
                                    }
                                }
                            }
                        }
                    }
                    if ts > 0 { result.append(Track(id: id, timescale: ts, presentationOffset: empty - mediaTime / Double(ts))) }
                }
            }
        }
        return result
    }

    // MARK: Codec strings

    /// RFC 6381 codec strings ("avc1.640028", "hvc1.2.4.L120.B0", "mp4a.40.2", "ec-3") for the
    /// tracks an init segment describes, in track order. HLS players on Chromecast need them in
    /// the master playlist: without a CODECS attribute the Cast player assumes H.264 Main 3.0 with
    /// AAC-LC and rejects anything else. Entries that can't be read are left out.
    static func codecs(inInit d: Data) -> [String] {
        var result: [String] = []
        boxes(d, 0, d.count) { type, h, s, e in
            guard type == "moov" else { return }
            boxes(d, s + h, e) { type, h, s, e in
                guard type == "trak" else { return }
                boxes(d, s + h, e) { type, h, s, e in
                    guard type == "mdia" else { return }
                    boxes(d, s + h, e) { type, h, s, e in
                        guard type == "minf" else { return }
                        boxes(d, s + h, e) { type, h, s, e in
                            guard type == "stbl" else { return }
                            boxes(d, s + h, e) { type, h, s, e in
                                guard type == "stsd" else { return }
                                // FullBox header (4) + entry_count (4), then the sample entries.
                                boxes(d, s + h + 8, e) { entryType, eh, es, ee in
                                    if let codec = codecString(d, entryType, es + eh, ee) { result.append(codec) }
                                }
                            }
                        }
                    }
                }
            }
        }
        return result
    }

    /// The codec string for one sample entry whose fields start at `start`.
    private static func codecString(_ d: Data, _ type: String, _ start: Int, _ end: Int) -> String? {
        // VisualSampleEntry carries 78 bytes of fixed fields, AudioSampleEntry 28 (version 0) or
        // 44 (version 1), before the child boxes that hold the codec details.
        func child(_ wanted: String, after fixed: Int) -> (Int, Int)? {
            var found: (Int, Int)?
            boxes(d, start + fixed, end) { t, h, s, e in if t == wanted, found == nil { found = (s + h, e) } }
            return found
        }
        func byte(_ o: Int) -> UInt8 { o < d.count ? d[o] : 0 }

        switch type {
        case "avc1", "avc3":
            guard let (c, _) = child("avcC", after: 78) else { return "avc1.640028" }
            return String(format: "%@.%02X%02X%02X", type, byte(c + 1), byte(c + 2), byte(c + 3))
        case "hvc1", "hev1":
            guard let (c, _) = child("hvcC", after: 78) else { return "\(type).1.6.L120.B0" }
            let b1 = byte(c + 1)
            let profileSpace = Int(b1 >> 6), tier = (b1 >> 5) & 1, profile = Int(b1 & 0x1F)
            let compat = UInt32(byte(c + 2)) << 24 | UInt32(byte(c + 3)) << 16 | UInt32(byte(c + 4)) << 8 | UInt32(byte(c + 5))
            var reversed: UInt32 = 0
            for i in 0..<32 where compat & (1 << UInt32(i)) != 0 { reversed |= 1 << UInt32(31 - i) }
            var constraints = (0..<6).map { byte(c + 6 + $0) }
            while constraints.count > 1, constraints.last == 0 { constraints.removeLast() }
            let level = byte(c + 12)
            let space = ["", "A", "B", "C"][profileSpace]
            let flags = constraints.map { String(format: "%02X", $0) }.joined(separator: ".")
            return "\(type).\(space)\(profile).\(String(reversed, radix: 16, uppercase: true)).\(tier == 1 ? "H" : "L")\(level).\(flags)"
        case "dvh1", "dvhe":
            // Dolby Vision: dvcC / dvvC hold profile (7 bits) then level (6 bits) after two
            // version bytes. A Cast player that isn't told this assumes plain HEVC at best.
            let config = child("dvcC", after: 78) ?? child("dvvC", after: 78)
            guard let (c, _) = config else { return "\(type).05.06" }
            let profile = byte(c + 2) >> 1
            let level = (byte(c + 2) & 1) << 5 | byte(c + 3) >> 3
            return String(format: "%@.%02d.%02d", type, profile, level)
        case "mp4a":
            let version = Int(UInt16(byte(start + 8)) << 8 | UInt16(byte(start + 9)))
            guard let (c, e) = child("esds", after: version == 1 ? 44 : 28) else { return "mp4a.40.2" }
            return esdsCodec(d, c + 4, e) ?? "mp4a.40.2"
        case "ac-3": return "ac-3"
        case "ec-3": return "ec-3"
        case "Opus": return "opus"
        case "fLaC": return "flac"
        case "alac": return "alac"
        case ".mp3": return "mp4a.6B"
        case "vp09":
            guard let (c, _) = child("vpcC", after: 78) else { return "vp09.00.10.08" }
            // FullBox header (4), then profile, level, bitDepth(4 bits) | chroma(3) | fullRange(1).
            return String(format: "vp09.%02d.%02d.%02d", byte(c + 4), byte(c + 5), byte(c + 6) >> 4)
        case "av01":
            guard let (c, _) = child("av1C", after: 78) else { return "av01.0.08M.08" }
            let b1 = byte(c + 1), b2 = byte(c + 2)
            let profile = b1 >> 5, levelIdx = b1 & 0x1F
            let tier = (b2 >> 7) & 1, highBitDepth = (b2 >> 6) & 1, twelveBit = (b2 >> 5) & 1
            let depth = twelveBit == 1 ? 12 : (highBitDepth == 1 ? 10 : 8)
            return String(format: "av01.%d.%02d%@.%02d", profile, levelIdx, tier == 1 ? "H" : "M", depth)
        default:
            return nil
        }
    }

    /// Reads the object type and, for MPEG-4 audio, the audio object type out of an `esds` box.
    private static func esdsCodec(_ d: Data, _ start: Int, _ end: Int) -> String? {
        var o = start
        func byte(_ at: Int) -> UInt8 { at < d.count ? d[at] : 0 }
        // Descriptor: tag, then a length in 1-4 bytes with the top bit as a continuation flag.
        func header() -> (tag: UInt8, length: Int)? {
            guard o < end else { return nil }
            let tag = byte(o); o += 1
            var length = 0
            for _ in 0..<4 {
                let b = byte(o); o += 1
                length = length << 7 | Int(b & 0x7F)
                if b & 0x80 == 0 { break }
            }
            return (tag, length)
        }
        guard let es = header(), es.tag == 0x03 else { return nil }
        let flags = byte(o + 2)
        o += 3
        if flags & 0x80 != 0 { o += 2 }                    // dependsOn_ES_ID
        if flags & 0x40 != 0 { o += 1 + Int(byte(o)) }     // URL
        if flags & 0x20 != 0 { o += 2 }                    // OCR_ES_Id
        guard let config = header(), config.tag == 0x04 else { return nil }
        let objectType = byte(o)
        o += 13                                            // objectTypeIndication .. avgBitrate
        if objectType == 0x40 {
            // AudioSpecificConfig: 5 bits of audioObjectType, 31 meaning "6 more bits + 32".
            guard let info = header(), info.tag == 0x05, info.length > 0 else { return "mp4a.40.2" }
            var aot = Int(byte(o) >> 3)
            if aot == 31 { aot = 32 + Int((UInt16(byte(o)) << 8 | UInt16(byte(o + 1))) >> 5 & 0x3F) }
            return "mp4a.40.\(aot)"
        }
        return String(format: "mp4a.%02X", objectType)
    }

    /// Returns the segment with each track's `tfdt` moved by `offsets[trackID]` seconds and
    /// `sidx` boxes neutralised.
    static func rebase(segment: Data, offsets: [UInt32: Double], timescales: [UInt32: UInt32]) -> Data {
        var d = segment
        boxes(d, 0, d.count) { type, h, s, e in
            if type == "sidx" {
                d.replaceSubrange((s + 4)..<(s + 8), with: Data("free".utf8))
            } else if type == "moof" {
                boxes(d, s + h, e) { type, h, s, e in
                    guard type == "traf" else { return }
                    var trackID: UInt32 = 0
                    boxes(d, s + h, e) { type, h, s, _ in
                        if type == "tfhd" {
                            trackID = u32(d, s + h + 4)
                        } else if type == "tfdt", let off = offsets[trackID], let ts = timescales[trackID] {
                            let v = d[s + h]
                            let delta = Int64((off * Double(ts)).rounded())
                            if v == 1 {
                                let cur = Int64(bitPattern: u64(d, s + h + 4))
                                var val = UInt64(max(0, cur + delta)).bigEndian
                                withUnsafeBytes(of: &val) { d.replaceSubrange((s + h + 4)..<(s + h + 12), with: $0) }
                            } else {
                                let cur = Int64(u32(d, s + h + 4))
                                var val = UInt32(clamping: max(0, cur + delta)).bigEndian
                                withUnsafeBytes(of: &val) { d.replaceSubrange((s + h + 4)..<(s + h + 8), with: $0) }
                            }
                        }
                    }
                }
            }
        }
        return d
    }
}
