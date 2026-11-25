import ComfyKit
import LightboxCore
import SwiftUI

/// "Add guide": every kind with what it does and whether the server can do
/// it for the current preset's model family.
struct GuidePicker: View {
    let onPick: (ControlKind) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let family = app.generation.preset(in: app.library)?.family ?? .sdxl
        NavigationStack {
            List {
                Section {
                    ForEach(ControlKind.structure) { row($0) }
                } header: {
                    Text("Shape the image")
                } footer: {
                    Text("Give a sketch, photo or earlier result. The image follows its lines, depth or pose.")
                }
                Section {
                    ForEach(ControlKind.imagePrompts) { row($0) }
                } header: {
                    Text("Borrow from a picture")
                } footer: {
                    Text("The picture works like part of the prompt: its look, style or layout carries over.")
                }
            }
            .navigationTitle("Add a guide")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                Text("Models for \(family.label), as set in the preset.")
                    .font(.caption).foregroundStyle(.secondary).padding(8)
            }
        }
        #if os(macOS)
            .frame(minWidth: 520, minHeight: 620)
        #endif
    }

    private func row(_ kind: ControlKind) -> some View {
        let setup = app.generation.setup(for: kind, app)
        let available = (try? setup.get()) != nil
        return Button {
            dismiss()
            onPick(kind)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: kind.icon).font(.title2).frame(width: 32)
                    .foregroundStyle(available ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.title).font(.headline)
                    Text(kind.summary).font(.callout).foregroundStyle(.secondary)
                    if case .failure(let missing) = setup {
                        Text(missing.message).font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .disabled(!available)
    }
}

/// One guide in the Generate form.
struct GuideRow: View {
    @Binding var guide: Guide
    let onReplace: () -> Void
    @Environment(AppModel.self) private var app
    @State private var showTiming = false

    var body: some View {
        let setup = app.generation.setup(for: guide.kind, app)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                FittedImage(image: guide.image)
                    .frame(width: 64, height: 64)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Label(guide.kind.title, systemImage: guide.kind.icon).font(.headline)
                    Text(guide.kind.summary).font(.caption).foregroundStyle(.secondary)
                    switch setup {
                    case .success(let s): Text(modelName(s)).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    case .failure(let missing): Text(missing.message).font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
                Menu {
                    Menu("Use as") {
                        ForEach(ControlKind.allCases) { kind in
                            Button(kind.title, systemImage: kind.icon) {
                                guide.kind = kind
                                guide.strength = kind.defaultStrength
                            }
                        }
                    }
                    Button("Replace picture…", action: onReplace)
                    Button("Remove", role: .destructive) { app.generation.removeGuide(guide.id) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            LabeledContent("\(guide.kind.strengthLabel): \(Int(guide.strength * 100))%") {
                Slider(value: $guide.strength, in: 0...1.5, step: 0.05)
            }
            if let label = guide.kind.extractLabel, extractorAvailable(setup) {
                Toggle(label, isOn: $guide.extract)
                Text(guide.kind.extractHint).font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Timing", isExpanded: $showTiming) {
                LabeledContent("From \(Int(guide.startPercent * 100))%") {
                    Slider(value: $guide.startPercent, in: 0...1, step: 0.05)
                }
                LabeledContent("Until \(Int(guide.endPercent * 100))%") {
                    Slider(value: $guide.endPercent, in: 0...1, step: 0.05)
                }
                Text(
                    "Which part of the drawing steps the guide is active for. Ending early gives the model freedom for details."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func modelName(_ setup: ControlSetup) -> String {
        switch setup {
        case .controlNet(let model, let union, _): union.map { "\(model) (\($0))" } ?? model
        case .ipAdapter(let model, _, _): model
        }
    }

    private func extractorAvailable(_ setup: Result<ControlSetup, MissingModel>) -> Bool {
        if case .success(.controlNet(_, _, .some)) = setup { return true }
        return false
    }
}

/// Face and hand fix settings.
struct FinishSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        let catalog = app.catalog
        Section {
            Toggle("Fix faces", isOn: $app.library.finish.fixFaces)
                .disabled(!catalog.hasDetailer || catalog.faceDetector == nil)
            if app.library.finish.fixFaces {
                LabeledContent("Redraw: \(Int(app.library.finish.faceStrength * 100))%") {
                    Slider(value: $app.library.finish.faceStrength, in: 0.2...0.7, step: 0.05)
                }
            }
            Toggle("Fix hands", isOn: $app.library.finish.fixHands)
                .disabled(!catalog.hasDetailer || catalog.handDetector == nil)
            if app.library.finish.fixHands {
                LabeledContent("Redraw: \(Int(app.library.finish.handStrength * 100))%") {
                    Slider(value: $app.library.finish.handStrength, in: 0.2...0.7, step: 0.05)
                }
            }
        } header: {
            Text("Finish")
        } footer: {
            if !catalog.hasDetailer {
                Text(
                    "Needs ComfyUI-Impact-Pack and ComfyUI-Impact-Subpack with a face detector (face_yolov8m.pt) on the server."
                )
            } else {
                Text(
                    "Finds faces (and hands) after drawing and redraws them at higher resolution. Helps most in wide shots, where faces are small. Low values keep the face, high values redraw it more freely."
                )
            }
        }
    }
}

/// A menu of guide kinds, for using pictures as guides.
struct UseAsGuideMenu: View {
    var title = "Use as Guide"
    let onPick: (ControlKind) -> Void

    var body: some View {
        Menu(title, systemImage: "scribble") {
            Section("Shape the image") {
                ForEach(ControlKind.structure) { kind in
                    Button(kind.title, systemImage: kind.icon) { onPick(kind) }
                }
            }
            Section("Borrow from a picture") {
                ForEach(ControlKind.imagePrompts) { kind in
                    Button(kind.title, systemImage: kind.icon) { onPick(kind) }
                }
            }
        }
    }
}
