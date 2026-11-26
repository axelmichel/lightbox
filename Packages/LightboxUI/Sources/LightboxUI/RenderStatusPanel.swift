import SwiftUI

/// The picture being made, floating over the main area: the server's live
/// preview when it sends one (ComfyUI started with `--preview-method auto`),
/// else a small toast with the progress. It opens bottom right; drag it
/// anywhere, and it stays where it was put. Collapsed, it is the toast.
struct RenderStatusPanel: View {
    @Environment(AppModel.self) private var app
    /// Offset from the bottom right corner, kept per device.
    @AppStorage("renderPanelX") private var x = 0.0
    @AppStorage("renderPanelY") private var y = 0.0
    @AppStorage("renderPanelCollapsed") private var collapsed = false
    @State private var dragStart: CGPoint?
    @State private var panelSize = CGSize(width: 280, height: 60)

    static let margin = 16.0

    var body: some View {
        let gen = app.generation
        // Style previews show their own progress in the styles list.
        if gen.isRunning, gen.renderingPreview == nil {
            GeometryReader { geo in
                let offset = clamped(CGPoint(x: x, y: y), in: geo.size)
                panel
                    .onGeometryChange(for: CGSize.self, of: \.size) { panelSize = $0 }
                    .offset(x: offset.x, y: offset.y)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let start = dragStart ?? offset
                                dragStart = start
                                let moved = clamped(
                                    CGPoint(
                                        x: start.x + value.translation.width, y: start.y + value.translation.height),
                                    in: geo.size)
                                (x, y) = (moved.x, moved.y)
                            }
                            .onEnded { _ in dragStart = nil }
                    )
                    .padding(Self.margin)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            .transition(.opacity)
        }
    }

    /// Kept inside the area: from the bottom right corner up and to the left.
    private func clamped(_ p: CGPoint, in size: CGSize) -> CGPoint {
        let maxX = max(0, size.width - panelSize.width - 2 * Self.margin)
        let maxY = max(0, size.height - panelSize.height - 2 * Self.margin)
        return CGPoint(x: min(0, max(p.x, -maxX)), y: min(0, max(p.y, -maxY)))
    }

    @ViewBuilder private var panel: some View {
        let gen = app.generation
        let live = gen.preview != nil && !collapsed
        VStack(alignment: .leading, spacing: 8) {
            if live, let preview = gen.preview {
                FittedImage(image: preview)
                    .frame(width: 260, height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 8) {
                if gen.totalSteps > 0, gen.step > 0 {
                    ProgressView(value: Double(gen.step), total: Double(gen.totalSteps))
                        .frame(width: live ? nil : 120)
                } else {
                    ProgressView().controlSize(.small)
                }
                if case .running(let text) = gen.state, !live || gen.step == 0 {
                    Text(text).font(.caption).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
                if gen.preview != nil {
                    Button(
                        collapsed ? "Show the Preview" : "Hide the Preview",
                        systemImage: collapsed ? "chevron.up" : "chevron.down"
                    ) { withAnimation { collapsed.toggle() } }
                    .help(collapsed ? "Show the picture as it is drawn" : "Only the progress")
                }
                Button("Stop", systemImage: "stop.fill") { gen.cancel() }
                    .help("Stop this generation")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            if live, case .running(let text) = gen.state, gen.step > 0 {
                Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(10)
        .frame(width: live ? 280 : 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.separator) }
        .shadow(radius: 8, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Generating")
    }
}
