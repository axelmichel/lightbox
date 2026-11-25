#if os(macOS)
    import AppKit
    import SwiftUI

    /// Scroll-wheel and trackpad scrolling over a view, which SwiftUI doesn't
    /// report on the Mac. Put it in a view's background: it watches the
    /// window's scroll events and takes those over its own frame, so clicks
    /// and drags still reach the view.
    struct ScrollCatcher: NSViewRepresentable {
        struct Scroll {
            var delta: CGSize
            /// In the view, from its top left.
            var location: CGPoint
            /// A trackpad or Magic Mouse; a wheel scrolls in notches.
            var isPrecise: Bool
            var command: Bool
        }

        var onScroll: (Scroll) -> Void

        func makeNSView(context: Context) -> CatcherView {
            let view = CatcherView()
            view.onScroll = onScroll
            return view
        }

        func updateNSView(_ view: CatcherView, context: Context) {
            view.onScroll = onScroll
        }

        final class CatcherView: NSView {
            var onScroll: ((Scroll) -> Void)?
            private var monitor: Any?

            override var isFlipped: Bool { true }

            // Only watches; never takes clicks.
            override func hitTest(_ point: NSPoint) -> NSView? { nil }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
                guard window != nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    guard let self, let window = self.window, event.window === window else { return event }
                    let location = self.convert(event.locationInWindow, from: nil)
                    guard self.bounds.contains(location), self.isVisibleInWindow else { return event }
                    self.onScroll?(
                        Scroll(
                            delta: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY),
                            location: location, isPrecise: event.hasPreciseScrollingDeltas,
                            command: event.modifierFlags.contains(.command)))
                    return nil
                }
            }

            /// Not hidden by a sheet or another view on top.
            private var isVisibleInWindow: Bool {
                !isHiddenOrHasHiddenAncestor && window?.attachedSheet == nil
            }

            override func removeFromSuperview() {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
                super.removeFromSuperview()
            }
        }
    }
#endif
