import Foundation
import Darwin

func runSelfTests() throws {
    var count = 0
    func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw SwitcherError.message(message) }; count += 1
    }
    let router = "\n[model_providers.openrouter]\nname = \"OpenRouter\"\nbase_url = \"https://openrouter.ai/api/v1\"\n"
    let source = "# Keep this comment\nmodel = 'subscription-test-model' # Keep the suffix\nservice_tier = \"default\"\n" + router + "\n[plugins.sample]\nmodel = \"nested-do-not-touch\"\n"
    let original = try ConfigDocument(data: Data(source.utf8))
    let switched = try original.selecting(.openRouter, model: "vendor/test-model")
    let parsed = try ConfigDocument(data: switched)
    try expect(parsed.provider == .openRouter, "Provider selection failed")
    try expect(parsed.model == "vendor/test-model", "Model selection failed")
    let text = String(decoding: switched, as: UTF8.self)
    try expect(text.contains("# Keep the suffix"), "Inline comment changed")
    try expect(text.contains("model = \"nested-do-not-touch\""), "Nested model changed")
    try expect(text.contains("service_tier = \"default\""), "Other setting changed")
    let back = try parsed.selecting(.subscription, model: original.model!)
    try expect(try ConfigDocument(data: back).provider == .subscription, "Subscription restore failed")
    let restoredText = String(decoding: back, as: UTF8.self)
    try expect(restoredText.components(separatedBy: "[model_providers.openrouter]").count == 2, "Provider table duplicated")

    let tricky = #"""
    instructions = """
    [not_a_real_table]
    model = "fake-model"
    """
    notes = [
      "# a string, not a comment",
      "[also-not-a-table]"
    ]
    "model" = "subscription-test-model"
    'model_provider' = 'openai'
    [model_providers.openrouter]
    name = "OpenRouter"
    """#
    let trickyDocument = try ConfigDocument(data: Data(tricky.utf8))
    try expect(trickyDocument.model == "subscription-test-model", "Multiline strings or arrays confused the root scanner")
    let trickyResult = String(decoding: try trickyDocument.selecting(.openRouter, model: "vendor/alternate-test-model"), as: UTF8.self)
    try expect(trickyResult.contains("model = \"fake-model\""), "Multiline string content changed")
    try expect(trickyResult.contains("'model_provider' = \"openrouter\""), "Quoted root key was not handled")

    let endingQuotes = [
        "instructions = " + String(repeating: "\"", count: 3) + "text" + String(repeating: "\"", count: 4),
        "instructions = '''text'''''",
    ]
    for value in endingQuotes {
        let document = try ConfigDocument(data: Data((value + "\n" + router).utf8))
        let candidate = try document.selecting(.openRouter, model: "vendor/test-model")
        let result = try ConfigDocument(data: candidate)
        try expect(result.provider == .openRouter && result.model == "vendor/test-model", "Multiline closing quotes hid the first real table")
    }
    let definitions = [
        #"model_providers = { other = { note = "ignore, openrouter = {}" }, "openrouter" = { name = "Router" } }"#,
        #"model_providers = { openrouter.name = "Router" }"#,
        #"model_providers.'openrouter'.name = "Router""#,
        #"model_providers.openrouter = { name = "Router" }"#,
        #"["model_\U00000070roviders"."openroute\u0072"]"#,
        #""model_provider\u0073" = { "open_route" = {}, "openroute\U00000072" = { name = "Router" } }"#,
        "[\"model_providers\"]\n\"openroute\\u0072\".name = \"Router\"",
        "[model_providers.openrouter.auth]\ncommand = \"helper\"",
        "[model_providers]\nopenrouter = { name = \"Router\" }",
    ]
    for value in definitions {
        let document = try ConfigDocument(data: Data((value + "\n").utf8))
        let result = try ConfigDocument(data: document.selecting(.openRouter, model: "vendor/test-model"))
        try expect(result.hasOpenRouter && result.provider == .openRouter, "Valid OpenRouter table was rejected")
    }
    let escaped = try ConfigDocument(data: Data(#"""
    "mo\U00000064el" = "vendor/\U0001f680"
    "model_provide\u0072" = "open\u0061i"
    """#.utf8))
    try expect(escaped.model == "vendor/🚀" && escaped.provider == .subscription, "Unicode escape decoding failed")
    let escapedResult = try escaped.selecting(.subscription, model: "replacement")
    try expect(String(decoding: escapedResult, as: UTF8.self).contains(#""mo\U00000064el" = "replacement""#),
               "An escaped root key was replaced or duplicated")
    let invalidEscape = try? ConfigDocument(data: Data(#"model = "\U00110000""#.utf8))
    try expect(invalidEscape == nil, "An invalid Unicode scalar was accepted")

    let fakeDefinition = "instructions = '''\n[model_providers.openrouter]\n'''\n"
    let fake = try ConfigDocument(data: Data(fakeDefinition.utf8))
    try expect(!fake.hasOpenRouter, "A table inside a string was treated as a provider")
    let nested = try ConfigDocument(data: Data(#"model_providers = { other = { openrouter = { name = "Nested" } } }"#.utf8))
    try expect(!nested.hasOpenRouter, "A nested inline key was treated as a provider")

    let crlf = try ConfigDocument(data: Data(("model = \"subscription-test-model\"\n" + router).replacingOccurrences(of: "\n", with: "\r\n").utf8))
    let crlfResult = String(decoding: try crlf.selecting(.openRouter, model: "vendor/alternate-test-model"), as: UTF8.self)
    try expect(!crlfResult.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "CRLF line endings changed")

    let empty = try ConfigDocument(data: Data(router.utf8))
    let emptyResult = try ConfigDocument(data: empty.selecting(.openRouter, model: "vendor/alternate-test-model"))
    try expect(emptyResult.provider == .openRouter && emptyResult.model == "vendor/alternate-test-model", "Missing root fields were not inserted")
    do {
        _ = try ConfigDocument(data: Data("model = \"one\"\nmodel = \"two\"".utf8))
        throw SwitcherError.message("Duplicate model keys were accepted")
    } catch let error as SwitcherError {
        try expect(error.localizedDescription.contains("Duplicate"), "Unexpected duplicate-key error")
    }
    do {
        _ = try original.selecting(.openRouter, model: "bad\nmodel")
        throw SwitcherError.message("A multiline model ID was accepted")
    } catch let error as SwitcherError {
        try expect(error.localizedDescription.contains("without spaces"), "Unexpected model validation error")
    }
    do {
        _ = try ConfigDocument(data: Data("model = \"subscription-test-model\"".utf8)).selecting(.openRouter, model: "vendor/alternate-test-model")
        throw SwitcherError.message("Missing OpenRouter registration was accepted")
    } catch let error as SwitcherError {
        try expect(error.localizedDescription.contains("not registered"), "Unexpected missing-provider error")
    }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("provider-switcher-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.toml")
    try original.data.write(to: url)
    let store = ConfigurationStore(configURL: url, backupDirectory: directory.appendingPathComponent("Backups"))
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    try runChmod(["+a", "everyone deny write", url.path])
    let attribute = "dev.codexsubrouter.fixture"
    let metadata = Data("synthetic metadata".utf8)
    try expect(metadata.withUnsafeBytes { setxattr(url.path, attribute, $0.baseAddress, $0.count, 0, 0) } == 0,
               "Could not create a test extended attribute")
    let oldSnapshot = try store.snapshot()
    let backup = try store.apply(expected: oldSnapshot, candidate: switched)
    try expect(try Data(contentsOf: backup) == original.data, "Backup did not preserve original bytes")
    try expect(try Data(contentsOf: url) == switched, "Configuration transaction failed")
    let attributes = try FileManager.default.attributesOfItem(atPath: backup.path)
    try expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Backup is not private")
    let installed = try store.snapshot()
    try expect(installed.hasSamePermissionsAndAttributes(as: oldSnapshot), "Configuration metadata changed")

    do {
        _ = try store.apply(expected: oldSnapshot, candidate: back)
        throw SwitcherError.message("A concurrent configuration change was overwritten")
    } catch let error as SwitcherError {
        try expect(error.localizedDescription.contains("changed while"), "Unexpected concurrent-write error")
    }
    _ = try store.apply(expected: installed, candidate: original.data)
    try expect(try Data(contentsOf: url) == original.data, "Switching back failed")
    let externalEdit = original.data + Data("# saved by another editor\n".utf8)
    let snapshotBeforeEdit = try store.snapshot()
    var rejectedConcurrentEdit = false
    do {
        _ = try store.apply(expected: snapshotBeforeEdit, candidate: switched) {
            try externalEdit.write(to: url, options: .atomic)
        }
    } catch let error as SwitcherError {
        rejectedConcurrentEdit = error.localizedDescription.contains("concurrent configuration edit was restored")
    }
    try expect(rejectedConcurrentEdit, "A last-moment editor change did not fail the switch")
    try expect(try Data(contentsOf: url) == externalEdit, "An editor save between the final check and exchange was lost")

    let snapshotBeforeACLChange = try store.snapshot()
    var rejectedConcurrentACLChange = false
    do {
        _ = try store.apply(expected: snapshotBeforeACLChange, candidate: switched) {
            try runChmod(["+a", "everyone deny write", url.path])
        }
    } catch let error as SwitcherError {
        rejectedConcurrentACLChange = error.localizedDescription.contains("concurrent configuration edit was restored")
    }
    try expect(rejectedConcurrentACLChange, "A last-moment ACL change did not fail the switch")
    try expect(try !store.snapshot().hasSamePermissionsAndAttributes(as: snapshotBeforeACLChange),
               "A last-moment ACL change was lost")

    let other = directory.appendingPathComponent("other-config.toml")
    try externalEdit.write(to: other)
    let alias = directory.appendingPathComponent("alias-config.toml")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
    let linkedStore = ConfigurationStore(configURL: alias, backupDirectory: backup.deletingLastPathComponent())
    let linkedSnapshot = try linkedStore.snapshot()
    try FileManager.default.removeItem(at: alias)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: other)
    let retargeted = try? linkedStore.apply(expected: linkedSnapshot, candidate: switched)
    try expect(retargeted == nil, "An identical-byte symlink retarget was accepted")
    try expect(try Data(contentsOf: url) == externalEdit && Data(contentsOf: other) == externalEdit,
               "A symlink retarget changed one of its targets")
    _ = try linkedStore.apply(expected: linkedStore.snapshot(), candidate: switched)
    try expect(try Data(contentsOf: alias) == switched, "A stable symlink could not be used")
    try expect(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path) == other.path,
               "A config symlink was replaced")

    let lateLinkSnapshot = try linkedStore.snapshot()
    do {
        _ = try linkedStore.apply(expected: lateLinkSnapshot, candidate: original.data) {
            try FileManager.default.removeItem(at: alias)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
        }
        throw SwitcherError.message("A last-moment symlink retarget was accepted")
    } catch let error as SwitcherError {
        try expect(error.localizedDescription.contains("concurrent configuration edit was restored"),
                   "Unexpected last-moment symlink retarget error")
    }
    try expect(try Data(contentsOf: url) == externalEdit && Data(contentsOf: other) == switched,
               "A last-moment symlink retarget changed one of its targets")

    let inherited = directory.appendingPathComponent("Inherited", isDirectory: true)
    try FileManager.default.createDirectory(at: inherited, withIntermediateDirectories: false)
    try runChmod(["+a", "everyone allow read,file_inherit", inherited.path])
    let inheritedBackup = inherited.appendingPathComponent("snapshot.toml")
    try writeAtomically(original.data, to: inheritedBackup, permissions: 0o600)
    let privateBackup = try ConfigurationStore(configURL: inheritedBackup, backupDirectory: inherited).snapshot()
    let baseline = try ConfigurationStore(configURL: backup, backupDirectory: inherited).snapshot()
    try expect(privateBackup.hasSamePermissionsAndAttributes(as: baseline), "A private backup inherited an ACL")

    try expect(!HostInstallation.isTrustedExecutable(URL(fileURLWithPath: "/bin/sh")), "An executable from a different publisher was trusted")

    let reminder = RestartReminder(selection: ProviderSelection(parsed), selectedAt: Date(timeIntervalSince1970: 100))
    try expect(reminder.needsRestart(hostLaunchDates: [Date(timeIntervalSince1970: 90)]), "A running old host cleared the reminder")
    try expect(reminder.needsRestart(hostLaunchDates: []), "Closing without reopening cleared the reminder")
    try expect(reminder.needsRestart(hostLaunchDates: [nil]), "An unknown launch time cleared the reminder")
    try expect(!reminder.needsRestart(hostLaunchDates: [Date(timeIntervalSince1970: 110)]), "A manual restart did not clear the reminder")
    try expect(reminder.needsRestart(hostLaunchDates: [Date(timeIntervalSince1970: 90), Date(timeIntervalSince1970: 110)]), "An old host instance was ignored")
    try expect(try JSONDecoder().decode(RestartReminder.self, from: JSONEncoder().encode(reminder)) == reminder, "Reminder cannot survive a switcher relaunch")

    let fakeHome = directory.appendingPathComponent("user-home", isDirectory: true)
    let defaultPaths = SwitcherPaths.resolve(environment: [:], homeDirectory: fakeHome, workingDirectory: directory)
    try expect(defaultPaths.configURL == fakeHome.appendingPathComponent(".codex/config.toml"), "Default Codex home is incorrect")
    let alternate = directory.appendingPathComponent("alternate-home", isDirectory: true)
    let alternatePaths = SwitcherPaths.resolve(environment: ["CODEX_HOME": alternate.path], homeDirectory: fakeHome, workingDirectory: directory)
    try expect(alternatePaths.configURL == alternate.appendingPathComponent("config.toml"), "CODEX_HOME was ignored")
    try expect(!defaultPaths.usesCustomHome && alternatePaths.usesCustomHome, "Default and custom home policies are indistinguishable")
    try expect(defaultPaths.preferenceKey("restartReminder") != alternatePaths.preferenceKey("restartReminder"), "Reminder state leaks between Codex homes")
    try expect(defaultPaths.backupDirectory != alternatePaths.backupDirectory, "Backup scopes are not separated")
    let tildePaths = SwitcherPaths.resolve(environment: ["CODEX_HOME": "~/custom-codex"], homeDirectory: fakeHome, workingDirectory: directory)
    try expect(tildePaths.codexHome.path == fakeHome.appendingPathComponent("custom-codex").path, "Tilde path was not expanded")
    let relativePaths = SwitcherPaths.resolve(environment: ["CODEX_HOME": "relative-home"], homeDirectory: fakeHome, workingDirectory: directory)
    try expect(relativePaths.codexHome.path == directory.appendingPathComponent("relative-home").path, "Relative Codex home was not resolved")

    let models = ModelSettingsStore(url: alternatePaths.modelSettingsURL)
    try expect(try models.model(for: .openRouter) == nil, "Missing model was replaced with a built-in default")
    try models.remember("vendor/test-model", for: .openRouter)
    try expect(try models.model(for: .openRouter) == "vendor/test-model", "Model preference did not persist")
    try expect(try FileManager.default.attributesOfItem(atPath: models.url.path)[.posixPermissions] as? NSNumber == NSNumber(value: 0o600), "Model settings are not private")
    let imported = try PropertyListSerialization.data(fromPropertyList: ["model.openai": "subscription-import-model", "model.openrouter": "vendor/old-model", "unrelated": "ignored"], format: .xml, options: 0)
    try expect(try models.importPreferences(imported) == 1, "Model import overwrote an existing model or imported extra keys")
    try expect(try models.model(for: .openRouter) == "vendor/test-model", "Import replaced an existing choice")
    try expect(try models.model(for: .subscription) == "subscription-import-model", "Subscription model import failed")
    try expect(try !String(contentsOf: models.url).contains("unrelated"), "Import copied unrelated preferences")
    try expect(try models.importPreferences(imported) == 0, "Import is not idempotent")
    try expect(try ModelSettingsStore(url: defaultPaths.modelSettingsURL).model(for: .subscription) == nil, "Models leaked between homes")
    let validModels = try Data(contentsOf: models.url)
    do {
        try models.remember("invalid model", for: .subscription)
        throw SwitcherError.message("Invalid model was accepted")
    } catch let error as SwitcherError {
        try expect(error.localizedDescription.contains("without spaces"), "Unexpected invalid model error")
    }
    try expect(try Data(contentsOf: models.url) == validModels, "Invalid model changed model settings")
    try Data("{broken".utf8).write(to: models.url)
    do {
        try models.remember("vendor/new-model", for: .openRouter)
        throw SwitcherError.message("Malformed settings were overwritten")
    } catch let error as SwitcherError {
        try expect(error.localizedDescription.contains("must be JSON"), "Unexpected settings parse error")
    }
    let pinned = Data(#"{"appServerVersion":"fixture","configRequirements":{"requirements":{"modelProvider":"openai"}}}"#.utf8)
    try verifyStartupConfiguration(pinned, selectedProvider: "openai")
    do {
        try verifyStartupConfiguration(pinned, selectedProvider: "openrouter")
        throw SwitcherError.message("Mismatched provider pin was accepted")
    } catch let error as SwitcherError {
        try expect(error.localizedDescription.contains("administrator"), "Unexpected provider pin error")
    }
    let malformedResponse = Data(#"{"appServerVersion":"fixture","configRequirements":{"requirements":{"modelProvider":123}}}"#.utf8)
    try expect((try? verifyStartupConfiguration(malformedResponse, selectedProvider: "openai")) == nil,
               "A malformed provider pin was accepted")
    try expect(unsupportedStartupCheck(Data("error: unexpected argument '--print-startup-config' found".utf8)),
               "An older validator was not recognized")
    let environment = validationEnvironment(["PATH": "/usr/bin", "HOME": fakeHome.path, "LANG": "C", "CODEX_HOME": "old-home", "OPENAI_API_KEY": "not-a-real-key", "UNRELATED_SETTING": "ignored"], codexHome: alternate)
    try expect(environment["OPENAI_API_KEY"] == nil && environment["UNRELATED_SETTING"] == nil, "Validator inherited unrelated environment values")
    try expect(environment["CODEX_HOME"] == alternate.path && environment["HOME"] == fakeHome.path, "Validator environment paths are incorrect")
    print("Passed \(count) configuration, model, path, import, backup, and restart-reminder checks.")
}

private func runChmod(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/chmod")
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw SwitcherError.message("Could not set the test file ACL.") }
}
