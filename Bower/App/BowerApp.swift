import AppKit
import SwiftUI

enum Theme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        model?.flush()
    }
}

@main
struct BowerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @AppStorage("theme") private var theme: Theme = .system

    var body: some Scene {
        Window("Bower", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 460)
                .onAppear {
                    delegate.model = model
                    NSApp.appearance = theme.appearance
                }
                .onChange(of: theme) { _, theme in NSApp.appearance = theme.appearance }
        }
        .defaultSize(width: 1280, height: 800)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
