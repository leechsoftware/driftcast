import AppKit
import SwiftUI

/// Where a ScrollView is scrolled and how much there is: offset from the top, content height,
/// visible height.
struct ScrollPosition: Equatable {
    var offset: CGFloat = 0
    var height: CGFloat = 0
    var viewport: CGFloat = 0

    /// More content than fits, by a margin that ignores a stray few points.
    var overflows: Bool { height > viewport + 24 }
    var atEnd: Bool { offset + viewport >= height - 8 }
}

/// Reports a SwiftUI ScrollView's position by listening to the NSScrollView underneath it.
/// Put it in the scroll view's content, as a background. (A preference emitted inside a
/// ScrollView's content never reaches the ScrollView's own modifiers on macOS 14, so the
/// usual GeometryReader trick reports nothing there.)
///
/// It also keeps a real scrollbar on the scroll view. macOS hides scrollbars until the scroll
/// wheel moves, which leaves someone without a wheel or trackpad nothing to grab.
struct ScrollObserver: NSViewRepresentable {
    var onChange: (ScrollPosition) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) { nsView.onChange = onChange }

    final class ObserverView: NSView {
        var onChange: ((ScrollPosition) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            guard let scroll = enclosingScrollView else { return }
            scroll.contentView.postsBoundsChangedNotifications = true
            scroll.contentView.postsFrameChangedNotifications = true
            scroll.documentView?.postsFrameChangedNotifications = true
            showScrollbar(on: scroll)
            let center = NotificationCenter.default
            // macOS switches every scroll view back when the system's scrollbar style changes
            // (plugging in a mouse, for one).
            observers.append(center.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main) { [weak self, weak scroll] _ in
                if let self, let scroll { self.showScrollbar(on: scroll) }
            })
            for object in [scroll.contentView, scroll.documentView].compactMap({ $0 }) {
                observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: object, queue: .main) { [weak self] _ in self?.report() })
                observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: object, queue: .main) { [weak self] _ in self?.report() })
            }
            report()
        }

        /// The classic always-there bar, shown only while there is something to scroll.
        private func showScrollbar(on scroll: NSScrollView) {
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            if scroll.scrollerStyle != .legacy { scroll.scrollerStyle = .legacy }
        }

        private func report() {
            guard let scroll = enclosingScrollView, let document = scroll.documentView else { return }
            if scroll.scrollerStyle != .legacy { showScrollbar(on: scroll) }
            let visible = scroll.contentView.bounds
            let position = ScrollPosition(offset: visible.origin.y, height: document.frame.height, viewport: visible.height)
            // The notifications arrive during layout; SwiftUI state must change after it.
            DispatchQueue.main.async { [weak self] in self?.onChange?(position) }
        }

        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    }
}
