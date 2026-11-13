import SwiftUI

@main
struct DICOMImporterApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("DICOM-Importer", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Ordner oder ZIP öffnen …") { model.presentOpenPanel() }
                    .keyboardShortcut("o")
            }
        }

        WindowGroup("Bildportal", id: "portal", for: URL.self) { $url in
            if let url {
                PortalBrowserView(startURL: url)
                    .environment(model)
            }
        }
        .defaultSize(width: 1100, height: 800)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
