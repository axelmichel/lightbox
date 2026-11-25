import LightboxCore
import SwiftUI

/// The app's scenes: one main window, plus Settings on the Mac.
public struct LightboxScenes: Scene {
    let app: AppModel

    public init(app: AppModel) {
        self.app = app
    }

    public var body: some Scene {
        #if os(macOS)
            Window("Lightbox", id: "main") {
                RootView().environment(app)
            }
            .defaultSize(width: 1400, height: 900)
            Settings {
                SettingsView().environment(app).frame(width: 520).padding()
            }
        #else
            WindowGroup {
                RootView().environment(app)
            }
        #endif
    }
}

/// Folders and compositions on the left, the gallery with the prompt under
/// it (or the composition being edited) in the middle, Generate on the right.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(PanelKeys.generate) private var showGenerate = true
    #if os(iOS)
        @State private var showSettings = false
    #endif

    var body: some View {
        @Bindable var app = app
        @Bindable var gallery = app.gallery
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            Group {
                if let editor = app.workflows.editor {
                    NodeEditorView(editor: editor).id(editor.entry.id)
                } else if let doc = app.compositions.document {
                    ComposeView(doc: doc).id(doc.composition.id)
                } else {
                    ResizableSplit(key: "promptPanelHeight") {
                        GalleryGridView()
                    } bottom: {
                        PromptPanel()
                    }
                }
            }
            // The Generate panel isn't used by the node editor.
            .inspector(isPresented: app.workflows.editor == nil ? $showGenerate : .constant(false)) {
                GenerateView { showGenerate = false }
                    .inspectorColumnWidth(min: 320, ideal: 380, max: 560)
            }
            #if os(iOS)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Settings", systemImage: "gear") { showSettings = true }
                    }
                }
            #endif
        }
        .onChange(of: app.generation.focusRequests) { showGenerate = true }
        // One editor at a time: opening a composition closes the workflow, and the other way round.
        .onChange(of: app.compositions.document?.composition.id) { _, id in
            if id != nil { app.workflows.close() }
        }
        .onChange(of: app.workflows.editor?.entry.id) { _, id in
            if id != nil { app.compositions.close() }
        }
        .sheet(isPresented: $app.showingPresets) {
            PresetsView()
        }
        #if os(macOS)
            .sheet(item: $gallery.viewer) { request in
                ImageViewer(current: request.itemID)
            }
        #else
            .fullScreenCover(item: $gallery.viewer) { request in
                ImageViewer(current: request.itemID)
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } }
                    }
                }
            }
        #endif
        .alert(
            "Gallery",
            isPresented: Binding(get: { gallery.problem != nil }, set: { if !$0 { gallery.problem = nil } })
        ) {
            Button("OK") { gallery.problem = nil }
        } message: {
            Text(gallery.problem ?? "")
        }
    }
}
