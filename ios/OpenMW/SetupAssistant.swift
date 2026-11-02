// The setup assistant: the part of OpenMW's installation wizard (apps/wizard) iOS needs, shown before the engine
// starts (apps/openmw/ios/firstlaunch.cpp). It copies the game data from a picked folder or checks what the user copied
// into the app's documents, asks for the language and runs the engine's ini import.

import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
    /// the copy from a picked folder while it runs
    var progress: CopyProgress?
    private let importer: (String) -> String?
    @ObservationIgnored private var copyTask: Task<Void, any Error>?
    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid

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

    /// Copies the game data of a picked folder, or a picked Morrowind.ini, into Data and Config: nil once copied, else
    /// what went wrong.
    func copy(from url: URL, ini: Bool) async -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        let application = UIApplication.shared
        let idleTimerDisabled = application.isIdleTimerDisabled
        // D11: the screen stays on; iOS suspends the app ~30 s after the user leaves it, the next copy resumes
        application.isIdleTimerDisabled = true
        backgroundTask = application.beginBackgroundTask(withName: "Copy game data") { self.endBackgroundTask() }
        progress = CopyProgress()
        defer {
            progress = nil
            copyTask = nil
            endBackgroundTask()
            application.isIdleTimerDisabled = idleTimerDisabled
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let copy = GameDataCopy(documents: documents) { progress in await MainActor.run { self.progress = progress } }
        let task = Task.detached(priority: .userInitiated) { try await ini ? copy.copyIni(url) : copy.copyFolder(url) }
        copyTask = task
        do {
            try await task.value
            return nil
        } catch is CancellationError {
            return "Cancelled. Copy from Files… again continues where it stopped."
        } catch {
            return error.localizedDescription
        }
    }

    func cancelCopy() { copyTask?.cancel() }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    /// the game files the last import missed (missing.log: "./Data/Tribunal.esm")
    func missingFiles() -> [String] {
        let log = try? String(contentsOf: documents.appending(path: "missing.log"), encoding: .utf8)
        return log?.split(separator: "\n").map(String.init) ?? []
    }

    var appName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "OpenMW" }

    var deviceFolder: String { UIDevice.current.userInterfaceIdiom == .pad ? "On My iPad" : "On My iPhone" }
}

struct CopyProgress {
    var file = ""
    var done: Int64 = 0
    var total: Int64 = 0
}

struct SetupError: LocalizedError {
    let errorDescription: String?
}

/// Copies game data from a picked folder or file into the app's documents, off the main thread.
struct GameDataCopy {
    let documents: URL
    let progress: @Sendable (CopyProgress) async -> Void

    /// The Morrowind folder of a PC installation (Data Files and Morrowind.ini, as the wizard finds an existing
    /// installation) or its Data Files folder; an ini there goes into Config as well.
    func copyFolder(_ folder: URL) async throws {
        let entries = Self.entries(of: folder)
        let candidates = entries.filter { $0.key.lowercased() == "data files" }.map(\.value) + [folder]
        guard let data = candidates.first(where: { Self.entries(of: $0).keys.contains { $0.lowercased() == "morrowind.esm" } })
        else {
            throw SetupError(
                errorDescription: "“\(folder.lastPathComponent)” has neither a Data Files folder nor Morrowind.esm. "
                    + "Choose the Morrowind folder of your PC installation or its Data Files folder.")
        }
        var files = Self.files(in: data, to: documents.appending(path: "Data"))
        let ini = [folder, data].lazy.compactMap { Self.entries(of: $0).first { $0.key.lowercased() == "morrowind.ini" } }
        if let ini = ini.first {
            files.append((ini.value, documents.appending(path: "Config/Morrowind.ini")))
        }
        try await copy(files, from: folder)
    }

    func copyIni(_ ini: URL) async throws {
        try await copy([(ini, documents.appending(path: "Config/Morrowind.ini"))], from: ini)
    }

    /// D10: a file of the same size and modification date is there already (a cancelled or interrupted copy resumes),
    /// others are replaced. Each file is copied under a temporary name first, so an interrupted copy leaves no
    /// truncated game file.
    private func copy(_ files: [(source: URL, destination: URL)], from source: URL) async throws {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        var copies: [(source: URL, destination: URL, size: Int64)] = []
        for file in files {
            let source = try? file.source.resourceValues(forKeys: keys)
            let destination = try? file.destination.resourceValues(forKeys: keys)
            if let size = source?.fileSize, size == destination?.fileSize,
                source?.contentModificationDate == destination?.contentModificationDate
            {
                continue
            }
            copies.append((file.source, file.destination, Int64(source?.fileSize ?? 0)))
        }
        let total = copies.reduce(0) { $0 + $1.size }
        // a copy on the same volume clones the files (APFS)
        let volume = try documents.resourceValues(forKeys: [
            .volumeIdentifierKey, .volumeAvailableCapacityForImportantUsageKey,
        ])
        if let free = volume.volumeAvailableCapacityForImportantUsage, free < total,
            (try? source.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier)?
                .isEqual(volume.volumeIdentifier) != true
        {
            throw SetupError(
                errorDescription: "The game files need \(total.formatted(.byteCount(style: .file))) of free space, "
                    + "\(free.formatted(.byteCount(style: .file))) are free.")
        }
        let coordinator = NSFileCoordinator()
        var done: Int64 = 0
        for copy in copies {
            // ponytail: cancels between files, one big archive from a network share is copied first
            try Task.checkCancellation()
            await progress(CopyProgress(file: copy.source.lastPathComponent, done: done, total: total))
            try fileManager.createDirectory(
                at: copy.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let part = copy.destination.appendingPathExtension("part")
            var coordinationError: NSError?
            var copyError: (any Error)?
            // downloads what iCloud Drive or another file provider has not downloaded yet
            coordinator.coordinate(readingItemAt: copy.source, error: &coordinationError) { source in
                do {
                    try? fileManager.removeItem(at: part)
                    try fileManager.copyItem(at: source, to: part)
                    if rename(part.path, copy.destination.path) != 0 {
                        throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: copy.destination])
                    }
                } catch {
                    copyError = error
                }
            }
            if let error = coordinationError ?? copyError {
                throw error
            }
            done += copy.size
        }
    }

    /// A folder's files and folders by name. iCloud Drive keeps a file it has not downloaded as ".<name>.icloud", a
    /// coordinated read of <name> downloads it. Other hidden files (.DS_Store) are left out.
    private static func entries(of folder: URL) -> [String: URL] {
        var entries: [String: URL] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
            let file = !name.hasPrefix(".") ? name : name.hasSuffix(".icloud") ? String(name.dropFirst().dropLast(7)) : ""
            if !file.isEmpty {
                entries[file] = folder.appending(path: file)
            }
        }
        return entries
    }

    /// The files below a folder by name, each with its destination below another one.
    private static func files(in folder: URL, to destination: URL) -> [(source: URL, destination: URL)] {
        entries(of: folder).sorted { $0.key < $1.key }.flatMap { name, url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                ? files(in: url, to: destination.appending(path: name))
                : [(url, destination.appending(path: name))]
        }
    }
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
    @State private var picking = false
    @State private var pickingIni = false
    @State private var copyMessage: String?
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
                Group {
                    Button("Copy from Files…") { pick(ini: false) }
                    if !hasIni {
                        Button("Choose Morrowind.ini…") { pick(ini: true) }
                    }
                    // a copy from the Finder does not leave the app
                    Button("Check Again", action: check)
                }
                .disabled(setup.progress != nil)
            } header: {
                Text("Game Files")
            } footer: {
                Text(
                    "Copy from Files… copies the game data from the Morrowind folder of your PC installation (Data "
                        + "Files and Morrowind.ini) or from its Data Files folder: \(setup.deviceFolder), iCloud Drive, a "
                        + "USB drive or a network share. Or copy the contents of Data Files into the Data folder and "
                        + "Morrowind.ini into Config yourself: Files app > \(setup.deviceFolder) > \(setup.appName), or "
                        + "the Finder on a Mac."
                )
            }
            if let progress = setup.progress {
                Section("Copying") {
                    if progress.total == 0 {
                        ProgressView("Looking for the game files…")
                    } else {
                        ProgressView(value: Double(progress.done), total: Double(progress.total)) {
                            Text(progress.file)
                        } currentValueLabel: {
                            Text(
                                "\(progress.done.formatted(.byteCount(style: .file))) of "
                                    + "\(progress.total.formatted(.byteCount(style: .file)))")
                        }
                    }
                    Button("Cancel", role: .cancel) { setup.cancelCopy() }
                }
            } else if let copyMessage {
                Section("Copy from Files") {
                    Text(copyMessage)
                }
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
        .navigationBarBackButtonHidden(setup.progress != nil)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Import", action: importGameData)
                    .disabled(!hasIni || !installed.contains(.morrowind) || setup.progress != nil)
            }
        }
        .fileImporter(
            isPresented: $picking, allowedContentTypes: pickingIni ? [UTType(filenameExtension: "ini") ?? .data] : [.folder]
        ) { result in
            switch result {
            case .success(let url): copy(from: url)
            case .failure(let error): copyMessage = error.localizedDescription
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

    private func pick(ini: Bool) {
        pickingIni = ini
        picking = true
    }

    private func copy(from url: URL) {
        copyMessage = nil
        Task {
            copyMessage = await setup.copy(from: url, ini: pickingIni)
            check()
        }
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
