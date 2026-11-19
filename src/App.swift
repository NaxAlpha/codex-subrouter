import AppKit
import Foundation
import Darwin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var busy = false
    private var observedData: Data?
    private var observedModels: Data?
    private var lastError: String?
    private let defaults = UserDefaults.standard
    private let paths = SwitcherPaths.resolve()
    private var models: ModelSettingsStore { ModelSettingsStore(url: paths.modelSettingsURL) }
    private var restartReminder: RestartReminder? {
        get { defaults.data(forKey: paths.preferenceKey("restartReminder")).flatMap { try? JSONDecoder().decode(RestartReminder.self, from: $0) } }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: paths.preferenceKey("restartReminder")) }
            else { defaults.removeObject(forKey: paths.preferenceKey("restartReminder")) }
        }
    }
    private var configURL: URL { paths.configURL }
    private var backupURL: URL { paths.backupDirectory }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "Switch Codex provider")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.imagePosition = .imageLeading
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.busy else { return }
                if (try? Data(contentsOf: self.configURL)) != self.observedData ||
                   (try? Data(contentsOf: self.paths.modelSettingsURL)) != self.observedModels || self.restartReminder != nil { self.refresh() }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        refresh()
        return false
    }

    private func document() throws -> ConfigDocument {
        try ConfigDocument(data: Data(contentsOf: configURL))
    }

    private func host() throws -> HostInstallation {
        try discoverHost()
    }

    private func item(_ title: String, action: Selector? = nil, symbol: String? = nil) -> NSMenuItem {
        let result = NSMenuItem(title: title, action: action, keyEquivalent: "")
        result.target = self
        if let symbol { result.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return result
    }

    private func refresh() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        do {
            let config = try document()
            observedData = config.data
            let title = config.provider?.title ?? config.providerID
            try rememberSelection(config)
            observedModels = try? Data(contentsOf: paths.modelSettingsURL)
            updateRestartReminder(for: config)
            let pending = restartReminder != nil
            let reminder = pending ? ". Quit and reopen Codex to apply the saved selection." : ""
            statusItem.button?.title = " \(config.provider?.shortTitle ?? "?")\(pending ? " *" : "")\(lastError == nil ? "" : " !")"
            statusItem.button?.toolTip = "Codex SubRouter — selected in config: \(title)\(reminder)"
            statusItem.button?.setAccessibilityLabel("Codex SubRouter, \(title)\(reminder)")
            let heading = item(busy ? "Preparing switch…" : "Selected: \(title)")
            heading.isEnabled = false
            menu.addItem(heading)
            let model = item(config.model ?? "Model: default")
            model.isEnabled = false
            model.toolTip = "The selected model in the active Codex configuration"
            menu.addItem(model)
            let instructionText = paths.usesCustomHome && pending
                ? "Quit Codex, then reopen with this home"
                : pending ? "Quit and reopen Codex to apply" : "Restart Codex manually after switching"
            let instruction = item(instructionText)
            instruction.isEnabled = false
            menu.addItem(instruction)
            if paths.usesCustomHome && pending {
                let confirm = item("Dismiss Restart Reminder", action: #selector(dismissRestartReminder))
                confirm.isEnabled = !busy
                menu.addItem(confirm)
            }
            menu.addItem(.separator())
            let target = config.provider?.other ?? .subscription
            let primary = item("Switch to \(target.title)", action: #selector(switchProvider(_:)), symbol: "arrow.left.arrow.right")
            primary.representedObject = target.rawValue
            let targetConfigured = target == .subscription || config.hasOpenRouter
            let targetHasModel = try models.model(for: target) != nil
            primary.isEnabled = !busy && targetConfigured && targetHasModel
            menu.addItem(primary)
            if !targetConfigured || !targetHasModel {
                let setup = item(!targetConfigured ? "Configure OpenRouter in Codex first" : "Choose a \(target.title) model in Model Settings")
                setup.isEnabled = false
                menu.addItem(setup)
            }
            if config.provider == nil {
                let router = item("Switch to OpenRouter", action: #selector(switchProvider(_:)))
                router.representedObject = Provider.openRouter.rawValue
                router.isEnabled = !busy && config.hasOpenRouter && (try models.model(for: .openRouter)) != nil
                menu.addItem(router)
            }
        } catch {
            observedData = try? Data(contentsOf: configURL)
            lastError = error.localizedDescription
            statusItem.button?.title = " !"
            observedModels = try? Data(contentsOf: paths.modelSettingsURL)
            let errorItem = item("Configuration or model settings unavailable")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        }
        menu.addItem(.separator())
        if let lastError {
            let failure = item("Last action failed", symbol: "exclamationmark.triangle")
            failure.isEnabled = false
            failure.toolTip = lastError
            menu.addItem(failure)
            menu.addItem(item("Copy Error Details", action: #selector(copyError)))
            menu.addItem(item("Dismiss Error", action: #selector(dismissError)))
            menu.addItem(.separator())
        }
        let open = item("Open Codex", action: #selector(openHost), symbol: "app")
        open.isEnabled = !busy
        menu.addItem(open)
        menu.addItem(item("Open Configuration…", action: #selector(openConfiguration), symbol: "doc.text"))
        menu.addItem(item("Open Model Settings…", action: #selector(openModelSettings), symbol: "slider.horizontal.3"))
        let backups = item("Show Configuration Backups", action: #selector(showBackups), symbol: "clock.arrow.circlepath")
        backups.isEnabled = FileManager.default.fileExists(atPath: backupURL.path)
        menu.addItem(backups)
        menu.addItem(.separator())
        let version = item("Codex SubRouter \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")")
        version.isEnabled = false
        menu.addItem(version)
        let quit = item("Quit Switcher", action: #selector(quit))
        quit.isEnabled = !busy
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func rememberSelection(_ config: ConfigDocument) throws {
        guard let provider = config.provider, let model = config.model,
              (try? ConfigDocument.validateModel(model)) != nil else { return }
        try models.remember(model, for: provider)
    }

    private func updateRestartReminder(for config: ConfigDocument) {
        let selection = ProviderSelection(config)
        let previous = defaults.data(forKey: paths.preferenceKey("observedSelection")).flatMap { try? JSONDecoder().decode(ProviderSelection.self, from: $0) }
        if let previous, previous != selection {
            // Use the file timestamp so a restart that happened before this poll is recognized.
            let modified = (try? FileManager.default.attributesOfItem(atPath: configURL.path)[.modificationDate]) as? Date
            restartReminder = RestartReminder(selection: selection, selectedAt: min(modified ?? Date(), Date()))
        }
        if previous != selection, let data = try? JSONEncoder().encode(selection) {
            defaults.set(data, forKey: paths.preferenceKey("observedSelection"))
        }
        if !paths.usesCustomHome, let reminder = restartReminder {
            let launches = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").map(\.launchDate)
            if reminder.selection == selection && !reminder.needsRestart(hostLaunchDates: launches) { restartReminder = nil }
        }
    }

    @objc private func switchProvider(_ sender: NSMenuItem) {
        guard !busy, let value = sender.representedObject as? String, let target = Provider(rawValue: value) else { return }
        lastError = nil
        do {
            let store = ConfigurationStore(configURL: configURL, backupDirectory: backupURL)
            let snapshot = try store.snapshot()
            let original = try ConfigDocument(data: snapshot.data)
            let installation = try host()
            try rememberSelection(original)
            guard let model = try models.model(for: target) else {
                throw SwitcherError.message("Choose a model in Model Settings before switching to \(target.title).")
            }
            let candidate = try original.selecting(target, model: model)
            let selection = ProviderSelection(try ConfigDocument(data: candidate))
            let codexHome = paths.codexHome
            busy = true
            refresh()
            Task {
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try validateConfiguration(selection, in: codexHome, using: installation)
                    }.value
                    _ = try store.apply(expected: snapshot, candidate: candidate)
                    restartReminder = RestartReminder(selection: selection, selectedAt: Date())
                    defaults.set(try JSONEncoder().encode(selection), forKey: paths.preferenceKey("observedSelection"))
                    busy = false
                    refresh()
                } catch {
                    busy = false
                    refresh()
                    showError(error)
                }
            }
        } catch { showError(error) }
    }

    private func launch(_ installation: HostInstallation) async throws {
        let options = NSWorkspace.OpenConfiguration()
        options.activates = true
        if paths.usesCustomHome {
            guard NSRunningApplication.runningApplications(withBundleIdentifier: installation.bundleID).isEmpty else {
                throw SwitcherError.message("Quit the running Codex app before opening it with this Codex home.")
            }
            options.environment = ["CODEX_HOME": paths.codexHome.path]
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: installation.appURL, configuration: options) { app, error in
                if let error { continuation.resume(throwing: error) }
                else if app != nil { continuation.resume() }
                else { continuation.resume(throwing: SwitcherError.message("The desktop app did not reopen.")) }
            }
        }
    }

    @objc private func openHost() {
        do {
            let installation = try host()
            Task { do { try await launch(installation) } catch { showError(error) } }
        } catch { showError(error) }
    }

    @objc private func openConfiguration() { NSWorkspace.shared.open(configURL) }
    @objc private func dismissRestartReminder() {
        restartReminder = nil
        refresh()
    }
    @objc private func openModelSettings() {
        do { try models.ensureExists(); NSWorkspace.shared.open(paths.modelSettingsURL) }
        catch { showError(error) }
    }
    @objc private func showBackups() {
        if FileManager.default.fileExists(atPath: backupURL.path) { NSWorkspace.shared.open(backupURL) }
    }
    @objc private func copyError() {
        guard let lastError else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastError, forType: .string)
    }
    @objc private func dismissError() {
        lastError = nil
        refresh()
    }
    private func showError(_ error: Error) {
        lastError = error.localizedDescription
        refresh()
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

@main
struct Main {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--self-test") {
            do { try runSelfTests(); exit(0) }
            catch { fputs("SELF-TEST FAILED: \(error)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--validate-current") {
            do {
                let paths = SwitcherPaths.resolve()
                let config = try ConfigDocument(data: Data(contentsOf: paths.configURL))
                let models = ModelSettingsStore(url: paths.modelSettingsURL)
                let host = try discoverHost()
                var count = 0
                for provider in [Provider.subscription, .openRouter] {
                    guard let model = provider == config.provider ? config.model : try models.model(for: provider) else {
                        print("Skipped \(provider.title): choose its model in Model Settings first.")
                        continue
                    }
                    let candidate = try ConfigDocument(data: config.selecting(provider, model: model))
                    try validateConfiguration(ProviderSelection(candidate), in: paths.codexHome, using: host)
                    print("Validated \(provider.title) configuration without changing the live config.")
                    count += 1
                }
                guard count > 0 else { throw SwitcherError.message("No configured model is available to validate.") }
                exit(0)
            } catch { fputs("VALIDATION FAILED: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--set-model" || arguments.first == "--import-preferences" {
            do {
                let store = ModelSettingsStore(url: SwitcherPaths.resolve().modelSettingsURL)
                if arguments.first == "--set-model" {
                    guard arguments.count == 3, let provider = Provider(rawValue: arguments[1]) else {
                        throw SwitcherError.message("Usage: --set-model openai|openrouter MODEL_ID")
                    }
                    try store.remember(arguments[2], for: provider)
                    print("Saved \(provider.title) model preference. Codex configuration was not changed.")
                } else {
                    guard arguments.count == 2 else { throw SwitcherError.message("Usage: --import-preferences FILE.plist") }
                    let url = URL(fileURLWithPath: arguments[1])
                    let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? Int.max
                    guard size <= 1024 * 1024 else { throw SwitcherError.message("The preferences file is too large.") }
                    let count = try store.importPreferences(Data(contentsOf: url))
                    print("Imported \(count) model preferences. Other preferences were ignored.")
                }
                exit(0)
            } catch { fputs("SETUP FAILED: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if !arguments.isEmpty {
            print("Codex SubRouter: --self-test | --validate-current | --set-model openai|openrouter MODEL_ID | --import-preferences FILE.plist")
            exit(arguments == ["--help"] ? 0 : 1)
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
