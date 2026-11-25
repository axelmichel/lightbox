import SwiftUI

#if os(macOS)
    import AppKit
#endif

/// Two views on top of each other with a handle between them. The bottom
/// view's height is kept (per device) under `key`; it stays between 120
/// points and 60 % of the space. `VSplitView` would be Mac-only and forgets
/// the size.
struct ResizableSplit<Top: View, Bottom: View>: View {
    @AppStorage private var height: Double
    @State private var dragStart: Double?
    private let top: Top
    private let bottom: Bottom

    init(key: String, defaultHeight: Double = 240, @ViewBuilder top: () -> Top, @ViewBuilder bottom: () -> Bottom) {
        _height = AppStorage(wrappedValue: defaultHeight, key)
        self.top = top()
        self.bottom = bottom()
    }

    var body: some View {
        GeometryReader { geo in
            let limit = max(Self.minimum, geo.size.height * 0.6)
            let shown = min(max(height, Self.minimum), limit)
            VStack(spacing: 0) {
                top.frame(maxWidth: .infinity, maxHeight: .infinity)
                handle
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let start = dragStart ?? shown
                                dragStart = start
                                height = min(max(start - drag.translation.height, Self.minimum), limit)
                            }
                            .onEnded { _ in dragStart = nil }
                    )
                bottom.frame(height: shown)
            }
        }
    }

    private static var minimum: Double { 120 }

    private var handle: some View {
        ZStack {
            Rectangle().fill(.bar)
            Divider().frame(maxHeight: .infinity, alignment: .top)
            Capsule().fill(.secondary.opacity(0.5)).frame(width: 36, height: 4)
        }
        .frame(height: 10)
        .contentShape(Rectangle())
        #if os(macOS)
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
        #endif
        .accessibilityLabel("Resize the prompt panel")
    }
}

/// The divider on a side panel's left edge; dragging it changes the
/// panel's width, kept within `range`.
struct PanelResizeHandle: View {
    @Binding var width: Double
    var range: ClosedRange<Double>
    @State private var dragStart: Double?

    var body: some View {
        Divider()
            .overlay {
                // Wider than the line, so it is easy to grab.
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let start = dragStart ?? width
                                dragStart = start
                                width = min(max(start - drag.translation.width, range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in dragStart = nil }
                    )
                    #if os(macOS)
                        .onHover { inside in
                            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                        }
                    #endif
                    .accessibilityLabel("Resize the panel")
            }
    }
}
