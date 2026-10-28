// The setup assistant: the part of OpenMW's installation wizard (apps/wizard) iOS needs, shown before the engine
// starts (apps/openmw/ios/firstlaunch.cpp). It checks the game data the user copied into the app's documents, asks for
// the language and runs the engine's ini import.

import Combine
import SwiftUI
import UIKit

/// The engine's import with an encoding: nil once openmw.cfg is written, else what went wrong.
typealias SetupImport = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>) -> UnsafePointer<CChar>?

/// Shows the setup pages over the app's scene and runs the main run loop until the user plays or keeps the current
/// setup, as SDL shows its alerts before it has a window. Returns false without a window scene to show them on.
/// Called on the main thread (SDL_main).
@MainActor @_cdecl("OMWRunSetupAssistant")
func runSetupAssistant(
    _ documents: UnsafePointer<CChar>, _ encoding: UnsafePointer<CChar>, _ configured: Bool, _ importer: SetupImport,
    _ context: UnsafeMutableRawPointer?
) -> Bool {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
        return false
    }
    let setup = Setup(
        documents: URL(filePath: String(cString: documents), directoryHint: .isDirectory),
        language: Language(encoding: String(cString: encoding)), configured: configured
    ) { encoding in importer(context, encoding).map { String(cString: $0) } }
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UIHostingController(rootView: SetupAssistant(setup: setup))
    window.makeKeyAndVisible()
    while !setup.finished {
        RunLoop.current.run(mode: .default, before: .distantFuture)
    }
    window.isHidden = true
    return true
}

/// The wizard's languages; they only choose the encoding of the game data.
enum Language: String, CaseIterable, Identifiable {
    case english = "English", french = "French", german = "German", italian = "Italian", polish = "Polish",
        russian = "Russian", spanish = "Spanish"

    var id: Self { self }

    var encoding: String {
        switch self {
        case .polish: "win1250"
        case .russian: "win1251"
        default: "win1252"
        }
    }

    init(encoding: String) {
        self = encoding == "win1250" ? .polish : encoding == "win1251" ? .russian : .english
    }
}

/// The wizard's components: <name>.esm and <name>.bsa in Data.
enum Component: String, CaseIterable, Identifiable {
    case morrowind = "Morrowind", tribunal = "Tribunal", bloodmoon = "Bloodmoon"

    var id: Self { self }
}

@MainActor @Observable
final class Setup {
    let documents: URL
    let configured: Bool
    var language: Language
    var finished = false
    private let importer: (String) -> String?

    init(documents: URL, language: Language, configured: Bool, importer: @escaping (String) -> String?) {
        self.documents = documents
        self.language = language
        self.configured = configured
        self.importer = importer
    }

    /// What the user copied, for display only: the import decides (the ini is in Config, or in Data next to the game
    /// files; the engine looks the game files up case-insensitively).
    var hasIni: Bool {
        ["Config", "Data"].contains {
            FileManager.default.fileExists(atPath: documents.appending(path: "\($0)/Morrowind.ini").path)
        }
    }

    func installed() -> Set<Component> {
        let files = Set(
            ((try? FileManager.default.contentsOfDirectory(atPath: documents.appending(path: "Data").path)) ?? [])
                .map { $0.lowercased() })
        return Set(Component.allCases.filter {
            files.contains("\($0.rawValue.lowercased()).esm") && files.contains("\($0.rawValue.lowercased()).bsa")
        })
    }

    /// nil once openmw.cfg is written, else what went wrong
    func importGameData() -> String? { importer(language.encoding) }

    /// the game files the last import missed (missing.log: "./Data/Tribunal.esm")
    func missingFiles() -> [String] {
        let log = try? String(contentsOf: documents.appending(path: "missing.log"), encoding: .utf8)
        return log?.split(separator: "\n").map(String.init) ?? []
    }

    var appName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "OpenMW" }

    var deviceFolder: String { UIDevice.current.userInterfaceIdiom == .pad ? "On My iPad" : "On My iPhone" }
}

enum Page: Hashable {
    case gameData, ready
}

struct SetupAssistant: View {
    let setup: Setup
    @State private var path: [Page] = []

    var body: some View {
        NavigationStack(path: $path) {
            WelcomePage(setup: setup) { path.append(.gameData) }
                .navigationDestination(for: Page.self) { page in
                    switch page {
                    case .gameData: GameDataPage(setup: setup) { path.append(.ready) }
                    case .ready: ReadyPage(setup: setup)
                    }
                }
        }
    }
}

struct WelcomePage: View {
    let setup: Setup
    let next: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("Welcome").font(.largeTitle.bold())
            Text(
                "OpenMW plays Morrowind with the game files of its PC version (GOG, Steam or CD): the contents of the "
                    + "Data Files folder and Morrowind.ini."
            )
            .multilineTextAlignment(.center)
            .frame(maxWidth: 480)
            Button("Continue", action: next)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            if setup.configured {
                Button("Keep Current Setup") { setup.finished = true }
            }
        }
        .padding()
    }
}

struct GameDataPage: View {
    let setup: Setup
    let next: () -> Void
    @State private var hasIni = false
    @State private var installed: Set<Component> = []
    @State private var error: String?
    @State private var missing: [String] = []

    var body: some View {
        @Bindable var setup = setup
        Form {
            Section {
                row("Morrowind.ini", found: hasIni, optional: false)
                ForEach(Component.allCases) {
                    row($0.rawValue, found: installed.contains($0), optional: $0 != .morrowind)
                }
                // a copy from the Finder does not leave the app
                Button("Check Again", action: check)
            } header: {
                Text("Game Files")
            } footer: {
                Text(
                    "Copy the contents of Morrowind's Data Files folder into the Data folder and Morrowind.ini into "
                        + "Config or Data: Files app > \(setup.deviceFolder) > \(setup.appName), or the Finder on a Mac."
                )
            }
            Section {
                Picker("Language", selection: $setup.language) {
                    ForEach(Language.allCases) { Text($0.rawValue) }
                }
            } footer: {
                Text("The language of your copy of Morrowind.")
            }
            if let error {
                Section("Import Failed") {
                    Text(error)
                    ForEach(missing, id: \.self) { Text($0).monospaced() }
                }
            }
        }
        .navigationTitle("Game Data")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Import", action: importGameData)
                    .disabled(!hasIni || !installed.contains(.morrowind))
            }
        }
        .onAppear(perform: check)
        // back from the Files app
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in check() }
    }

    private func row(_ name: String, found: Bool, optional: Bool) -> some View {
        HStack {
            Text(name)
            Spacer()
            if found {
                Label("Found", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if optional {
                Label("Not found (optional)", systemImage: "minus.circle").foregroundStyle(.secondary)
            } else {
                Label("Missing", systemImage: "xmark.circle.fill").foregroundStyle(.red)
            }
        }
    }

    private func check() {
        hasIni = setup.hasIni
        installed = setup.installed()
    }

    private func importGameData() {
        error = setup.importGameData()
        missing = setup.missingFiles()
        check()
        if error == nil {
            next()
        }
    }
}

struct ReadyPage: View {
    let setup: Setup

    var body: some View {
        let skipped = setup.missingFiles()
        VStack(spacing: 24) {
            Text("Ready").font(.largeTitle.bold())
            if skipped.isEmpty {
                Text("The game data is set up.")
            } else {
                Text("The game data is set up. These game files of Morrowind.ini were not found and are left out:")
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                ForEach(skipped, id: \.self) { Text($0).monospaced() }
            }
            Button("Play") { setup.finished = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding()
        .navigationBarBackButtonHidden()
    }
}
