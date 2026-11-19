import Foundation
import CryptoKit
import Darwin

struct SwitcherPaths {
    let codexHome: URL
    let applicationSupport: URL
    let usesCustomHome: Bool
    var configURL: URL { codexHome.appendingPathComponent("config.toml") }
    var modelSettingsURL: URL { codexHome.appendingPathComponent("provider-switcher.json") }
    var scope: String { SHA256.hash(data: Data(codexHome.resolvingSymlinksInPath().path.utf8)).map { String(format: "%02x", $0) }.joined() }
    var backupDirectory: URL {
        applicationSupport.appendingPathComponent("Codex SubRouter/Backups", isDirectory: true)
            .appendingPathComponent(String(scope.prefix(20)), isDirectory: true)
    }
    func preferenceKey(_ name: String) -> String { "home.\(scope).\(name)" }

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                        applicationSupport: URL? = nil) -> SwitcherPaths {
        let raw = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let root: URL
        if raw.isEmpty { root = homeDirectory.appendingPathComponent(".codex", isDirectory: true) }
        else if raw == "~" { root = homeDirectory }
        else if raw.hasPrefix("~/") { root = homeDirectory.appendingPathComponent(String(raw.dropFirst(2)), isDirectory: true) }
        else {
            let base = URL(fileURLWithPath: workingDirectory.path, isDirectory: true)
            root = URL(fileURLWithPath: raw, relativeTo: base).standardizedFileURL
        }
        let resolved = root.standardizedFileURL
        let defaultHome = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        return SwitcherPaths(codexHome: resolved,
                             applicationSupport: applicationSupport ?? homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true),
                             usesCustomHome: resolved.resolvingSymlinksInPath().path != defaultHome.resolvingSymlinksInPath().path)
    }
}

struct ModelSettings: Codable, Equatable {
    var models: [String: String] = [:]
}

struct ModelSettingsStore {
    let url: URL

    func load() throws -> ModelSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return ModelSettings() }
        let data = try Data(contentsOf: url)
        guard data.count <= 64 * 1024 else { throw SwitcherError.message("Model settings are too large.") }
        guard let value = try? JSONDecoder().decode(ModelSettings.self, from: data) else {
            throw SwitcherError.message("Model settings must be JSON with a models object. Open Model Settings to correct it.")
        }
        for (key, model) in value.models {
            guard Provider(rawValue: key) != nil else { throw SwitcherError.message("Model settings contain an unsupported provider ID.") }
            try ConfigDocument.validateModel(model)
        }
        return value
    }

    func model(for provider: Provider) throws -> String? { try load().models[provider.rawValue] }

    func remember(_ model: String, for provider: Provider) throws {
        try ConfigDocument.validateModel(model)
        var settings = try load()
        guard settings.models[provider.rawValue] != model else { return }
        settings.models[provider.rawValue] = model
        try save(settings)
    }

    func ensureExists() throws {
        if !FileManager.default.fileExists(atPath: url.path) { try save(ModelSettings()) }
    }

    // Import only model choices from an explicitly supplied old preferences file.
    // Existing choices win. Account data, credentials, and other preference keys are ignored.
    func importPreferences(_ data: Data) throws -> Int {
        guard data.count <= 1024 * 1024,
              let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw SwitcherError.message("The import must be a preferences plist smaller than 1 MiB.")
        }
        var settings = try load()
        var imported = 0
        for provider in [Provider.subscription, .openRouter] {
            guard settings.models[provider.rawValue] == nil,
                  let model = values["model.\(provider.rawValue)"] as? String else { continue }
            try ConfigDocument.validateModel(model)
            settings.models[provider.rawValue] = model
            imported += 1
        }
        if imported > 0 { try save(settings) }
        return imported
    }

    private func save(_ value: ModelSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try writeAtomically(encoder.encode(value) + Data([10]), to: url, permissions: 0o600)
    }
}

func writeAtomically(_ data: Data, to destination: URL, permissions: mode_t) throws {
    let temporary = try stageFile(data, nextTo: destination, permissions: permissions)
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard rename(temporary.path, destination.path) == 0 else {
        throw SwitcherError.message("Cannot replace the settings file. Check its folder permissions.")
    }
}

func stageFile(_ data: Data, nextTo destination: URL, permissions: mode_t,
               configure: (Int32) throws -> Void = { _ in }) throws -> URL {
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(".provider-switcher-\(UUID().uuidString).tmp")
    let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw SwitcherError.message("Cannot create a private temporary settings file.") }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    do {
        // A parent directory can grant access through inherited ACLs despite a 0600 mode.
        guard let privateACL = acl_init(0) else {
            throw SwitcherError.message("Cannot create a private settings file ACL.")
        }
        defer { acl_free(UnsafeMutableRawPointer(privateACL)) }
        guard acl_set_fd_np(fd, privateACL, ACL_TYPE_EXTENDED) == 0 else {
            throw SwitcherError.message("Cannot remove inherited access from the temporary settings file.")
        }
        try handle.write(contentsOf: data)
        guard fchmod(fd, permissions & 0o777) == 0 else {
            throw SwitcherError.message("Cannot preserve the settings file permissions.")
        }
        try configure(fd)
        try handle.synchronize()
        try handle.close()
        return temporary
    } catch {
        try? handle.close()
        try? FileManager.default.removeItem(at: temporary)
        throw error
    }
}

func validationEnvironment(_ original: [String: String], codexHome: URL) -> [String: String] {
    var environment = original.filter { ["HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"].contains($0.key) }
    environment["PATH"] = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    environment["CODEX_HOME"] = codexHome.path
    return environment
}
