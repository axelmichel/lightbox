import LightboxCore
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Picker over a list from the server. Keeps a stored value that the server
/// no longer has (marked as missing), and falls back to a text field while
/// not connected.
struct CatalogPicker: View {
    let title: String
    @Binding var selection: String
    let options: [String]
    /// Label of the empty choice; `nil` = a value is required.
    var noneLabel: String?

    var body: some View {
        if options.isEmpty {
            TextField(title, text: $selection, prompt: Text(noneLabel ?? "connect to list the server's files"))
                .autocorrectionDisabled()
        } else {
            Picker(title, selection: $selection) {
                if let noneLabel {
                    Text(noneLabel).tag("")
                } else if selection.isEmpty {
                    Text("Choose…").tag("")
                }
                if !selection.isEmpty, !options.contains(selection) {
                    Text("\(selection) (not on server)").tag(selection)
                }
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
        }
    }
}

extension Binding where Value == String? {
    /// `nil` ↔ "".
    var orEmpty: Binding<String> {
        Binding<String>(get: { wrappedValue ?? "" }, set: { wrappedValue = $0.isEmpty ? nil : $0 })
    }
}

/// A CGImage, scaled to fit.
struct FittedImage: View {
    let image: CGImage

    var body: some View {
        Image(decorative: image, scale: 1).resizable().scaledToFit()
    }
}

/// PNG data for `fileExporter`.
struct PNGFile: FileDocument {
    static let readableContentTypes: [UTType] = [.png]
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// A multi-line text box for prompts: a fixed, roomy height with a visible
/// scroll bar once the text is longer, and the title above it.
struct PromptField: View {
    let title: String
    @Binding var text: String
    var placeholder = ""
    var height = 96.0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.visible)
                .padding(4)
                .frame(height: height)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder).foregroundStyle(.tertiary).padding(.horizontal, 9).padding(.vertical, 4)
                            .allowsHitTesting(false)
                    }
                }
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.separator) }
                .accessibilityLabel(title)
        }
    }
}

/// A format menu (3:2, 16:9, …) and width and height fields, rounded to
/// multiples of 8 as the models need. `size` gives the pixels for a format.
struct SizeFields: View {
    @Binding var width: Int
    @Binding var height: Int
    var size: (AspectRatio) -> (width: Int, height: Int) = { $0.size(for: .sdxl) }

    var body: some View {
        HStack {
            Menu(AspectRatio.matching(width: width, height: height)?.label ?? "Custom") {
                ForEach([false, true], id: \.self) { portrait in
                    Section(portrait ? "Portrait" : "Landscape") {
                        ForEach(AspectRatio.allCases.filter { $0.isPortrait == portrait }, id: \.self) { format in
                            let s = size(format)
                            Button("\(format.label)  \(s.width) × \(s.height)") { (width, height) = s }
                        }
                    }
                }
            }
            .fixedSize()
            .help("Picture format")
            TextField("Width", value: rounded($width), format: .number).frame(minWidth: 60)
            Text("×").foregroundStyle(.secondary)
            TextField("Height", value: rounded($height), format: .number).frame(minWidth: 60)
            Button("Swap", systemImage: "arrow.left.arrow.right") { (width, height) = (height, width) }
                .labelStyle(.iconOnly)
                .help("Swap width and height")
        }
        #if os(iOS)
            .keyboardType(.numberPad)
        #endif
    }

    private func rounded(_ value: Binding<Int>) -> Binding<Int> {
        Binding(get: { value.wrappedValue }, set: { value.wrappedValue = min(max(64, ($0 + 4) / 8 * 8), 4096) })
    }
}

/// A small rounded label, e.g. a preset's style.
struct Badge: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        #else
            UIPasteboard.general.string = text
        #endif
    }

    static func copy(png: Data) {
        #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(png, forType: .png)
        #else
            UIPasteboard.general.setData(png, forPasteboardType: UTType.png.identifier)
        #endif
    }
}

/// The contents of a file from a file picker, which may be outside the sandbox.
func readPickedFile(_ url: URL) throws -> Data {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    return try Data(contentsOf: url)
}

/// The height of every panel's header row (gallery, layers, Generate), so
/// their buttons line up.
enum PanelHeader {
    static let height = 38.0
}

/// Shows or hides a side panel. It sits in the panel's own header while the
/// panel is open, and in the header now at that edge while it is closed, at
/// the same height.
struct PanelButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(title, systemImage: systemImage) { withAnimation { action() } }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(title)
    }
}

/// The panels' state, kept per device; read wherever their buttons are.
enum PanelKeys {
    static let generate = "showGeneratePanel"
    static let layers = "composeLayersShown"
}

/// The LoRA Info page's symbol (not the layers one, which is compositions').
enum LoraInfoIcon {
    static let name = "puzzlepiece.extension"
}

/// Opens the LoRA Info page: the symbol only.
struct LoraInfoButton: View {
    let action: () -> Void

    var body: some View {
        Button("LoRA Info", systemImage: LoraInfoIcon.name, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("LoRA Info: trigger words, best settings and notes for the server's LoRAs")
    }
}
