import SwiftUI

struct NowPlayingBar: View {
    @EnvironmentObject private var player: PlaybackController
    @State private var showOptions = false

    var body: some View {
        VStack(spacing: 6) {
            TimelineRow(clock: player.clock)
                .disabled(player.nowPlaying == nil)

            HStack(spacing: 14) {
                titleBlock
                    .frame(maxWidth: .infinity, alignment: .leading)
                transport
                trackControls
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .sheet(isPresented: Binding(get: { player.showSubtitleSearch }, set: { player.showSubtitleSearch = $0 })) {
            if let item = player.nowPlaying { SubtitleSearchView(item: item) }
        }
    }

    private var titleBlock: some View {
        HStack(spacing: 8) {
            Group {
                if case .preparing = player.phase {
                    ProgressView().controlSize(.small)
                } else if player.phase == .buffering {
                    ProgressView().controlSize(.small)
                } else if case .failed = player.phase {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    Image(systemName: player.outputSymbol).foregroundStyle(.secondary)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(player.nowPlaying?.title ?? "Nothing playing")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(player.statusText)
                    .font(.caption)
                    .foregroundStyle(isFailed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                    .help(player.statusText)
            }
        }
    }

    private var isFailed: Bool { if case .failed = player.phase { return true }; return false }

    private var transport: some View {
        HStack(spacing: 18) {
            Button { player.previous() } label: { Image(systemName: "backward.end.fill") }
                .help("Previous / restart")
            Button { player.skip(-10) } label: { Image(systemName: "gobackward.10") }
                .help("Back 10 seconds")
            Button { player.togglePause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 30))
            }
            .help(player.isPlaying ? "Pause" : "Play")
            Button { player.skip(10) } label: { Image(systemName: "goforward.10") }
                .help("Forward 10 seconds")
            Button { player.next() } label: { Image(systemName: "forward.end.fill") }
                .disabled(!player.hasNext)
                .help("Next video")
            Button { player.stop() } label: { Image(systemName: "stop.fill") }
                .disabled(player.nowPlaying == nil)
                .help("Stop")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 15))
    }

    private var trackControls: some View {
        HStack(spacing: 12) {
            audioMenu
            subtitleMenu
            Button { showOptions.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.borderless)
                .help("Audio adjustments and stream details")
                .popover(isPresented: $showOptions, arrowEdge: .top) { OptionsPopover() }
            HStack(spacing: 4) {
                Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Slider(value: Binding(get: { player.volume }, set: { player.setVolume($0) }), in: 0...1)
                    .controlSize(.small)
                    .frame(width: 90)
            }
            .help("Volume")
        }
        .disabled(player.nowPlaying == nil)
    }

    private var audioMenu: some View {
        Menu {
            if let tracks = player.info?.audio, !tracks.isEmpty {
                ForEach(tracks) { track in
                    Button { player.selectAudio(track.index) } label: {
                        if track.index == player.audioIndex { Label(track.label, systemImage: "checkmark") } else { Text(track.label) }
                    }
                }
            } else {
                Text("No audio tracks")
            }
        } label: {
            Image(systemName: "waveform")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Audio track")
    }

    private var subtitleMenu: some View {
        Menu {
            SubtitleMenuItems()   // shared with the video window's footer
        } label: {
            Image(systemName: player.subtitle == nil ? "captions.bubble" : "captions.bubble.fill")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Subtitles")
    }
}

/// The times either side of the timeline. Separate from the bar because it redraws on every
/// position update and nothing else needs to.
struct TimelineRow: View {
    @EnvironmentObject private var player: PlaybackController
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        HStack(spacing: 10) {
            Text(formatTime(clock.position))
                .monospacedDigit()
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
            Scrubber(clock: clock)
            Text(player.duration > 0 ? "-" + formatTime(max(0, player.duration - clock.position)) : "--:--")
                .monospacedDigit()
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
        }
    }
}

/// Timeline with hover / drag preview frames. The lighter band shows how far the converter
/// has got; seeking inside it is instant, outside it restarts conversion from that point.
struct Scrubber: View {
    @EnvironmentObject private var player: PlaybackController
    @ObservedObject var clock: PlaybackClock
    @State private var dragTime: Double?
    @State private var hoverX: CGFloat?
    @State private var hoverTime: Double = 0
    @State private var preview: NSImage?
    @State private var previewTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let duration = max(player.duration, 0.001)
            let shown = dragTime ?? clock.position
            let fraction = CGFloat(min(1, max(0, shown / duration)))
            let range = clock.seekableRange
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 5)
                if player.plan?.mode == .hls {
                    Capsule().fill(.tertiary)
                        .frame(width: width * CGFloat(max(0, (range.upperBound - range.lowerBound) / duration)), height: 5)
                        .offset(x: width * CGFloat(range.lowerBound / duration))
                }
                Capsule().fill(Color.accentColor).frame(width: width * fraction, height: 5)
                Circle()
                    .fill(.white)
                    .shadow(radius: 1)
                    .frame(width: 12, height: 12)
                    .offset(x: width * fraction - 6)
                    .opacity(player.nowPlaying == nil ? 0 : 1)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        player.isScrubbing = true
                        let t = time(at: g.location.x, width: width)
                        dragTime = t
                        hoverX = g.location.x
                        requestPreview(t)
                    }
                    .onEnded { g in
                        let t = time(at: g.location.x, width: width)
                        dragTime = nil
                        player.isScrubbing = false
                        player.seek(to: t)
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    hoverX = p.x
                    requestPreview(time(at: p.x, width: width))
                case .ended:
                    if dragTime == nil { hoverX = nil; previewTask?.cancel() }
                }
            }
            .overlay(alignment: .topLeading) {
                if let x = hoverX, player.nowPlaying != nil {
                    previewBubble
                        .offset(x: min(max(0, x - 90), width - 180), y: -118)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 20)
    }

    private var previewBubble: some View {
        VStack(spacing: 4) {
            ZStack {
                Rectangle().fill(.black)
                if let preview { Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit) }
            }
            .frame(width: 180, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(formatTime(hoverTime))
                .font(.caption.monospacedDigit().weight(.medium))
        }
        .padding(5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .shadow(radius: 4)
    }

    private func time(at x: CGFloat, width: CGFloat) -> Double {
        Double(min(1, max(0, x / width))) * player.duration
    }

    private func requestPreview(_ t: Double) {
        hoverTime = t
        guard let url = player.nowPlaying?.url else { return }
        previewTask?.cancel()
        previewTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            if let data = await Thumbnailer.shared.frame(url, at: t, width: 320), !Task.isCancelled {
                preview = NSImage(data: data)
            }
        }
    }
}

struct OptionsPopover: View {
    @EnvironmentObject private var player: PlaybackController
    @State private var sync: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Audio").font(.headline)
            Toggle("Volume booster", isOn: Binding(get: { player.options.volumeBoost }, set: { player.setVolumeBoost($0) }))
                .help("Evens out loud and quiet passages so dialogue is clear at low volume.")
            Toggle("Downmix to stereo", isOn: Binding(get: { player.options.downmix }, set: { player.setDownmix($0) }))
                .help("Mixes surround sound to two channels, for TV speakers and headphones.")
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Audio delay")
                    Spacer()
                    Text(String(format: "%+.2f s", sync)).monospacedDigit().foregroundStyle(.secondary)
                }
                HStack {
                    Button { adjust(-0.05) } label: { Image(systemName: "minus") }
                    Slider(value: $sync, in: -2...2, step: 0.05) { editing in
                        if !editing { player.setAVSync(sync) }
                    }
                    Button { adjust(0.05) } label: { Image(systemName: "plus") }
                    Button("Reset") { sync = 0; player.setAVSync(0) }
                }
                Text("Positive values delay the sound, for example to match Bluetooth speakers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let plan = player.plan {
                Divider()
                Text("Stream").font(.headline)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(plan.notes, id: \.self) { note in
                        Text(note).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { sync = player.options.avSyncOffset }
    }

    private func adjust(_ d: Double) {
        sync = min(2, max(-2, sync + d))
        player.setAVSync(sync)
    }
}
