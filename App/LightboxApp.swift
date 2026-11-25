import LightboxUI
import SwiftUI

@main
struct LightboxApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        LightboxScenes(app: model)
    }
}
