import AppKit
import SwiftUI

/// The Subtitle Size part of the popup subtitle menus (the playback bar and the video window's
/// footer). SwiftUI menus can't hold a slider, so these offer Larger, Smaller and the presets.
struct SubtitleSizeMenu: View {
    @AppStorage(Prefs.subtitleScale) private var scale = 1.0

    var body: some View {
        Menu("Subtitle Size: \(SubtitleSize.label(scale))") {
            Button("Larger") { SubtitleSize.increase() }.disabled(!SubtitleSize.canIncrease)
            Button("Smaller") { SubtitleSize.decrease() }.disabled(!SubtitleSize.canDecrease)
            Divider()
            Picker("Size", selection: Binding(get: { SubtitleSize.normalized(scale) }, set: { SubtitleSize.current = $0 })) {
                ForEach(SubtitleSize.presets, id: \.self) { preset in
                    Text(SubtitleSize.label(preset)).tag(preset)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}

/// A real slider in the menu bar's Subtitles menu. SwiftUI's Commands can only make ordinary
/// items, so this is an AppKit item with its own view, slipped into the menu SwiftUI built
/// whenever the menu bar is used. If SwiftUI rebuilds that menu and drops it, it is put back.
@MainActor
final class SubtitleSizeMenuItem {
    static let shared = SubtitleSizeMenuItem()

    private let header: NSMenuItem
    private let item: NSMenuItem
    private let slider: NSSlider
    private let valueLabel: NSTextField
    private var observers: [NSObjectProtocol] = []

    private init() {
        slider = NSSlider(value: SubtitleSize.current, minValue: SubtitleSize.range.lowerBound,
                          maxValue: SubtitleSize.range.upperBound, target: nil, action: nil)
        slider.isContinuous = true
        slider.controlSize = .small
        slider.numberOfTickMarks = Int(((SubtitleSize.range.upperBound - SubtitleSize.range.lowerBound) / SubtitleSize.step).rounded()) + 1
        slider.allowsTickMarkValuesOnly = true
        slider.setAccessibilityLabel("Subtitle size")

        let small = NSTextField(labelWithString: "A")
        small.font = .systemFont(ofSize: 10)
        small.textColor = .secondaryLabelColor
        let big = NSTextField(labelWithString: "A")
        big.font = .systemFont(ofSize: 17)
        big.textColor = .secondaryLabelColor
        valueLabel = NSTextField(labelWithString: SubtitleSize.label(SubtitleSize.current))
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true

        let stack = NSStackView(views: [small, slider, big, valueLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        // The same left inset as a menu item's title, so the slider lines up with the text.
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 21, bottom: 3, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 262, height: 28))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        header = NSMenuItem(title: "Subtitle Size", action: nil, keyEquivalent: "")
        header.isEnabled = false
        item = NSMenuItem(title: "Subtitle Size Slider", action: nil, keyEquivalent: "")
        item.view = container
        slider.target = self
        slider.action = #selector(sliderMoved)
    }

    private var reinsertScheduled = false

    /// Call once at launch.
    func install() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.insertIfNeeded() }
        })
        // SwiftUI fills the menu the first time it opens and again whenever its state changes,
        // replacing every item. After each such rebuild the slider goes back in, once the
        // rebuild has finished (hence the hop to the next run-loop turn).
        for name in [NSMenu.didAddItemNotification, NSMenu.didRemoveItemNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let menu = note.object as? NSMenu, menu.title == "Subtitles" || menu === self.item.menu,
                          !self.reinsertScheduled else { return }
                    self.reinsertScheduled = true
                    DispatchQueue.main.async {
                        self.reinsertScheduled = false
                        self.insertIfNeeded()
                    }
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        insertIfNeeded()
    }

    @objc private func sliderMoved() {
        SubtitleSize.current = slider.doubleValue
        refresh()
    }

    private func refresh() {
        let value = SubtitleSize.current
        if abs(slider.doubleValue - value) > 0.001 { slider.doubleValue = value }
        valueLabel.stringValue = SubtitleSize.label(value)
    }

    /// Puts the header and slider into the Subtitles menu, after the Smaller Subtitles item,
    /// unless they are already there.
    private func insertIfNeeded() {
        guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == "Subtitles" })?.submenu else { return }
        refresh()
        if menu.items.contains(where: { $0 === item }), menu.items.contains(where: { $0 === header }) { return }
        header.menu?.removeItem(header)
        item.menu?.removeItem(item)
        let anchor = menu.items.firstIndex { $0.title == "Smaller Subtitles" }.map { $0 + 1 }
            ?? menu.items.firstIndex { $0.title == "Subtitle Settings…" }
            ?? menu.items.count
        menu.insertItem(header, at: anchor)
        menu.insertItem(item, at: anchor + 1)
    }
}
