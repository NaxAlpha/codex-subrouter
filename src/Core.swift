import Foundation
import Darwin
import Security

enum SwitcherError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum Provider: String {
    case subscription = "openai"
    case openRouter = "openrouter"
    var title: String { self == .subscription ? "Subscription" : "OpenRouter" }
    var shortTitle: String { self == .subscription ? "Sub" : "OR" }
    var other: Provider { self == .subscription ? .openRouter : .subscription }
}

// Only root-level string values are replaced. All other TOML bytes are preserved.
struct ConfigDocument {
    let data: Data
    private(set) var values: [String: String] = [:]
    private var ranges: [String: Range<Int>] = [:]
    private var rootEnd: Int = 0
    private(set) var hasOpenRouter = false
    var providerID: String { values["model_provider"] ?? "openai" }
    var provider: Provider? { Provider(rawValue: providerID) }
    var model: String? { values["model"] }

    init(data: Data) throws {
        guard String(data: data, encoding: .utf8) != nil else {
            throw SwitcherError.message("The Codex configuration is not valid UTF-8.")
        }
        self.data = data
        let bytes = [UInt8](data)
        rootEnd = bytes.count
        var scanner = TOMLScanner()
        var start = 0
        var inRoot = true
        var inProviderTable = false
        while start < bytes.count {
            var end = start
            while end < bytes.count && bytes[end] != 10 { end += 1 }
            let next = end < bytes.count ? end + 1 : end
            if scanner.atStatementBoundary {
                let first = Self.skipSpaces(bytes, from: start, to: end)
                if first < end && bytes[first] == 91 {
                    if inRoot { rootEnd = start }
                    inRoot = false
                    inProviderTable = false
                    if let (keys, closing) = try Self.readKeyPath(bytes, from: first + 1, to: end),
                       closing < end, bytes[closing] == 93 {
                        inProviderTable = keys == ["model_providers"]
                        if keys.starts(with: ["model_providers", "openrouter"]) { hasOpenRouter = true }
                    }
                } else if inRoot || inProviderTable,
                          let (keys, equals) = try Self.readKeyPath(bytes, from: first, to: end),
                          equals < end, bytes[equals] == 61 {
                    let valueStart = Self.skipSpaces(bytes, from: equals + 1, to: end)
                    let inlineTable = valueStart < end && bytes[valueStart] == 123
                    if inRoot, keys.first == "model_providers" {
                        if keys.count == 1 && inlineTable {
                            hasOpenRouter = try Self.inlineTableContainsRouter(Array(bytes[valueStart..<end]))
                        } else if Self.definesRouter(keys.dropFirst(), hasInlineValue: inlineTable) {
                            hasOpenRouter = true
                        }
                    }
                    if inProviderTable && Self.definesRouter(keys[...], hasInlineValue: inlineTable) { hasOpenRouter = true }
                    if inRoot, keys.count == 1, let key = keys.first, key == "model" || key == "model_provider" {
                        guard ranges[key] == nil else { throw SwitcherError.message("Duplicate root-level \(key) settings were found.") }
                        let (value, valueEnd) = try Self.readString(bytes, at: valueStart, to: end)
                        let suffix = Self.skipSpaces(bytes, from: valueEnd, to: end)
                        guard suffix == end || bytes[suffix] == 35 || (suffix + 1 == end && bytes[suffix] == 13) else {
                            throw SwitcherError.message("Unexpected content after \(key).")
                        }
                        values[key] = value
                        ranges[key] = valueStart..<valueEnd
                    }
                }
            }
            scanner.consume(Array(bytes[start..<next]))
            start = next
        }
    }

    private static func definesRouter(_ keys: ArraySlice<String>, hasInlineValue: Bool) -> Bool {
        keys.first == "openrouter" && (keys.count > 1 || hasInlineValue)
    }

    private static func inlineTableContainsRouter(_ bytes: [UInt8]) throws -> Bool {
        var scanner = TOMLScanner()
        scanner.advance(bytes, index: 0)
        var index = 1
        var expectingKey = true
        while index < bytes.count {
            let atTableLevel = scanner.mode == .normal && scanner.braces == 1 && scanner.arrays == 0
            if expectingKey && atTableLevel {
                if let (keys, equals) = try readKeyPath(bytes, from: index, to: bytes.count),
                   equals < bytes.count, bytes[equals] == 61 {
                    let value = skipSpaces(bytes, from: equals + 1, to: bytes.count)
                    if definesRouter(keys[...], hasInlineValue: value < bytes.count && bytes[value] == 123) { return true }
                }
                expectingKey = false
            }
            if atTableLevel && bytes[index] == 44 { expectingKey = true }
            index = scanner.advance(bytes, index: index)
            if scanner.braces == 0 { break }
        }
        return false
    }

    private static func skipSpaces(_ bytes: [UInt8], from start: Int, to end: Int) -> Int {
        var index = start
        while index < end && (bytes[index] == 32 || bytes[index] == 9) { index += 1 }
        return index
    }

    private static func readKeyPath(_ bytes: [UInt8], from start: Int, to end: Int) throws -> ([String], Int)? {
        var keys: [String] = []
        var index = skipSpaces(bytes, from: start, to: end)
        while index < end {
            if bytes[index] == 34 || bytes[index] == 39 {
                let (key, next) = try readString(bytes, at: index, to: end)
                keys.append(key)
                index = next
            } else {
                let bareStart = index
                while index < end && isBareKeyByte(bytes[index]) { index += 1 }
                guard index > bareStart else { return nil }
                keys.append(String(decoding: bytes[bareStart..<index], as: UTF8.self))
            }
            index = skipSpaces(bytes, from: index, to: end)
            guard index < end, bytes[index] == 46 else { return (keys, index) }
            index = skipSpaces(bytes, from: index + 1, to: end)
        }
        return nil
    }

    private static func isBareKeyByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 45, 48...57, 65...90, 95, 97...122: return true
        default: return false
        }
    }

    func selecting(_ provider: Provider, model: String) throws -> Data {
        try Self.validateModel(model)
        if provider == .openRouter && !hasOpenRouter {
            throw SwitcherError.message("OpenRouter is not registered in config.toml. Add its provider definition first; this app only selects existing providers.")
        }
        let replacements = ["model": model, "model_provider": provider.rawValue]
        var bytes = [UInt8](data)
        let edits = try ranges.map { key, range in (range, Array(try Self.quote(replacements[key]!).utf8)) }
        for (range, replacement) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            bytes.replaceSubrange(range, with: replacement)
        }
        let missing = ["model", "model_provider"].filter { ranges[$0] == nil }
        if !missing.isEmpty {
            // Existing replacements may have changed the byte offset of the first table.
            let delta = edits.filter { $0.0.lowerBound < rootEnd }.reduce(0) { $0 + $1.1.count - $1.0.count }
            let insertAt = rootEnd + delta
            let newline = data.range(of: Data([13, 10])) != nil ? "\r\n" : "\n"
            var insertion = insertAt > 0 && bytes[insertAt - 1] != 10 ? newline : ""
            for key in missing { insertion += "\(key) = \(try Self.quote(replacements[key]!))\(newline)" }
            bytes.insert(contentsOf: insertion.utf8, at: insertAt)
        }
        let candidate = Data(bytes)
        let updated = try Self(data: candidate)
        guard updated.provider == provider, updated.model == model else {
            throw SwitcherError.message("Could not update the root model and provider safely.")
        }
        return candidate
    }

    static func validateModel(_ model: String) throws {
        guard !model.isEmpty, model.count <= 300,
              !model.contains(where: { $0.isWhitespace || $0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else {
            throw SwitcherError.message("Enter a model ID without spaces or line breaks.")
        }
    }

    static func quote(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    private static func readString(_ bytes: [UInt8], at start: Int, to end: Int) throws -> (String, Int) {
        guard start < end, bytes[start] == 34 || bytes[start] == 39 else {
            throw SwitcherError.message("The model and model_provider fields must use single-line TOML strings.")
        }
        let quote = bytes[start]
        if start + 2 < end && bytes[start + 1] == quote && bytes[start + 2] == quote {
            throw SwitcherError.message("Use a single-line string for the model and model_provider fields.")
        }
        var value: [UInt8] = []
        var index = start + 1
        while index < end {
            let byte = bytes[index]
            if byte == quote { return (String(decoding: value, as: UTF8.self), index + 1) }
            if byte == 13 { break }
            index += 1
            if quote != 34 || byte != 92 {
                value.append(byte)
                continue
            }
            guard index < end else { break }
            let escape = bytes[index]
            index += 1
            switch escape {
            case 34, 92: value.append(escape)
            case 98: value.append(8)   // b
            case 116: value.append(9)  // t
            case 110: value.append(10) // n
            case 102: value.append(12) // f
            case 114: value.append(13) // r
            case 117, 85:             // u, U
                let length = escape == 117 ? 4 : 8
                guard index + length <= end else { throw SwitcherError.message("Incomplete TOML Unicode escape.") }
                let digits = bytes[index..<(index + length)]
                guard digits.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                      let number = UInt32(String(decoding: digits, as: UTF8.self), radix: 16),
                      let scalar = UnicodeScalar(number) else {
                    throw SwitcherError.message("Invalid TOML Unicode escape.")
                }
                value.append(contentsOf: String(scalar).utf8)
                index += length
            default:
                throw SwitcherError.message("Invalid escape in a TOML string.")
            }
        }
        throw SwitcherError.message("A TOML string is incomplete.")
    }

}

private struct TOMLScanner {
    enum Mode { case normal, basic, literal, multilineBasic, multilineLiteral }
    var mode: Mode = .normal
    var arrays = 0
    var braces = 0
    var atStatementBoundary: Bool { mode == .normal && arrays == 0 && braces == 0 }

    mutating func consume(_ bytes: [UInt8]) {
        var index = 0
        while index < bytes.count { index = advance(bytes, index: index) }
    }

    @discardableResult
    mutating func advance(_ bytes: [UInt8], index: Int) -> Int {
        let byte = bytes[index]
        func quoteEnd() -> Int {
            var end = index + 1
            while end < bytes.count && bytes[end] == byte { end += 1 }
            return end
        }
        switch mode {
        case .normal:
            switch byte {
            case 35: return bytes.count
            case 34, 39:
                if quoteEnd() - index >= 3 {
                    mode = byte == 34 ? .multilineBasic : .multilineLiteral
                    return index + 3
                }
                mode = byte == 34 ? .basic : .literal
            case 91: arrays += 1
            case 93: arrays = max(0, arrays - 1)
            case 123: braces += 1
            case 125: braces = max(0, braces - 1)
            default: break
            }
        case .basic:
            if byte == 92 { return index + 2 }
            if byte == 34 { mode = .normal }
        case .literal:
            if byte == 39 { mode = .normal }
        case .multilineBasic, .multilineLiteral:
            if mode == .multilineBasic && byte == 92 { return index + 2 }
            if byte == (mode == .multilineBasic ? 34 : 39) {
                let end = quoteEnd()
                if end - index >= 3 { mode = .normal }
                return end
            }
        }
        return index + 1
    }
}

struct ConfigurationSnapshot {
    let destination: URL
    let data: Data
    private let info: stat
    private let acl: String
    private let attributes: [String: Data]

    fileprivate init(_ destination: URL, file: FileHandle) throws {
        let fd = file.fileDescriptor
        var first = stat()
        guard fstat(fd, &first) == 0, first.st_mode & S_IFMT == S_IFREG else {
            throw SwitcherError.message("The Codex configuration must be a regular file.")
        }
        self.destination = destination
        self.data = try file.readToEnd() ?? Data()
        self.acl = try fileACL(fd)
        self.attributes = try extendedAttributes(fd)
        var last = stat()
        guard fstat(fd, &last) == 0, sameTime(first.st_ctimespec, last.st_ctimespec) else {
            throw configurationChanged
        }
        self.info = last
    }

    fileprivate func matches(_ other: ConfigurationSnapshot, afterExchange: Bool = false) -> Bool {
        info.st_dev == other.info.st_dev && info.st_ino == other.info.st_ino &&
            info.st_nlink == other.info.st_nlink &&
            sameTime(info.st_mtimespec, other.info.st_mtimespec) &&
            (afterExchange || sameTime(info.st_ctimespec, other.info.st_ctimespec)) &&
            data == other.data && hasSamePermissionsAndAttributes(as: other)
    }

    func hasSamePermissionsAndAttributes(as other: ConfigurationSnapshot) -> Bool {
        info.st_uid == other.info.st_uid && info.st_gid == other.info.st_gid &&
            info.st_mode == other.info.st_mode && info.st_flags == other.info.st_flags &&
            acl == other.acl && attributes == other.attributes
    }

    fileprivate func copyPermissionsAndAttributes(from source: Int32, to destination: Int32) throws {
        guard info.st_nlink == 1, info.st_flags == 0 else {
            throw SwitcherError.message("SubRouter cannot safely replace a configuration with hard links or special file flags.")
        }
        var staged = stat()
        guard fstat(destination, &staged) == 0,
              fcopyfile(source, destination, nil, UInt32(COPYFILE_ACL | COPYFILE_XATTR)) == 0,
              (staged.st_uid == info.st_uid && staged.st_gid == info.st_gid ||
                fchown(destination, info.st_uid, info.st_gid) == 0),
              fchmod(destination, mode_t(info.st_mode) & 0o7777) == 0 else {
            throw SwitcherError.message("Cannot preserve the configuration file permissions and metadata.")
        }
    }
}

private var configurationChanged: SwitcherError {
    .message("The configuration changed while the switch was being prepared. Retry using the latest settings.")
}

private func sameTime(_ lhs: timespec, _ rhs: timespec) -> Bool {
    lhs.tv_sec == rhs.tv_sec && lhs.tv_nsec == rhs.tv_nsec
}

private var metadataError: SwitcherError {
    .message("Cannot read the configuration file permissions and metadata safely.")
}

private func fileACL(_ fd: Int32) throws -> String {
    guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
        if errno == ENOENT { return "" }
        throw metadataError
    }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    guard let text = acl_to_text(acl, nil) else { throw metadataError }
    defer { acl_free(text) }
    return String(cString: text)
}

private func extendedAttributes(_ fd: Int32) throws -> [String: Data] {
    let size = flistxattr(fd, nil, 0, 0)
    guard size >= 0 else { throw metadataError }
    guard size > 0 else { return [:] }
    var names = Data(count: size)
    let read = names.withUnsafeMutableBytes { flistxattr(fd, $0.baseAddress, size, 0) }
    guard read == size else { throw metadataError }
    var attributes: [String: Data] = [:]
    for nameBytes in names.split(separator: 0) {
        guard let name = String(data: Data(nameBytes), encoding: .utf8), attributes[name] == nil else {
            throw metadataError
        }
        let length = fgetxattr(fd, name, nil, 0, 0, 0)
        guard length >= 0 else { throw metadataError }
        var value = Data(count: length)
        let received = value.withUnsafeMutableBytes { fgetxattr(fd, name, $0.baseAddress, length, 0, 0) }
        guard received == length else { throw metadataError }
        attributes[name] = value
    }
    return attributes
}

struct ConfigurationStore {
    let configURL: URL
    let backupDirectory: URL

    private var destination: URL { configURL.resolvingSymlinksInPath() }

    func snapshot() throws -> ConfigurationSnapshot {
        let target = destination
        let snapshot = try read(target)
        guard destination == target else { throw configurationChanged }
        return snapshot
    }

    func apply(expected: ConfigurationSnapshot, candidate: Data, beforeCommit: () throws -> Void = {}) throws -> URL {
        guard try snapshot().matches(expected), destination == expected.destination else { throw configurationChanged }
        let fm = FileManager.default
        try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let backup = backupDirectory.appendingPathComponent("config-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(6)).toml")
        try writeAtomically(expected.data, to: backup, permissions: 0o600)
        try replace(expected, candidate: candidate, beforeCommit: beforeCommit)
        return backup
    }

    private func openRegular(_ url: URL) throws -> FileHandle {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw configurationChanged }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private func read(_ url: URL) throws -> ConfigurationSnapshot {
        try ConfigurationSnapshot(url, file: openRegular(url))
    }

    private func replace(_ expected: ConfigurationSnapshot, candidate: Data, beforeCommit: () throws -> Void) throws {
        let target = expected.destination
        let source = try openRegular(target)
        guard try ConfigurationSnapshot(target, file: source).matches(expected) else { throw configurationChanged }
        let staged = try stageFile(candidate, nextTo: target, permissions: 0o600) { fd in
            try expected.copyPermissionsAndAttributes(from: source.fileDescriptor, to: fd)
        }
        var preserveDisplaced = false
        defer { if !preserveDisplaced { try? FileManager.default.removeItem(at: staged) } }

        let proposed = try read(staged)
        guard proposed.data == candidate, proposed.hasSamePermissionsAndAttributes(as: expected) else {
            throw SwitcherError.message("Cannot verify the staged configuration and its file metadata.")
        }
        guard try snapshot().matches(expected), destination == target else { throw configurationChanged }
        try beforeCommit()
        // The exchange is atomic, but another editor may still win the race after the final read.
        guard renamex_np(staged.path, target.path, UInt32(RENAME_SWAP)) == 0 else {
            throw SwitcherError.message("Cannot exchange the configuration safely on this volume. The config was not replaced.")
        }
        // The exchange itself changes ctime. Check the displaced inode, contents, and metadata directly.
        if let displaced = try? read(staged), displaced.matches(expected, afterExchange: true), destination == target { return }

        preserveDisplaced = true
        if let current = try? read(target), current.matches(proposed, afterExchange: true),
           renamex_np(staged.path, target.path, UInt32(RENAME_SWAP)) == 0,
           let displaced = try? read(staged), displaced.matches(proposed, afterExchange: true) {
            preserveDisplaced = false
            throw SwitcherError.message("A concurrent configuration edit was restored. Retry the switch.")
        }
        throw SwitcherError.message("A concurrent edit interrupted the switch. The displaced file was kept at \(staged.path). Review both files before switching again.")
    }
}

struct HostInstallation {
    let appURL: URL
    let bundleID: String
    let executableURL: URL
    var displayName: String { appURL.deletingPathExtension().lastPathComponent }

    static func at(_ appURL: URL) -> HostInstallation? {
        let appRequirement = #"identifier "com.openai.codex" and anchor apple generic and certificate leaf[subject.OU] = "2DC432GLL2""#
        guard isSigned(appURL, requirement: appRequirement) else { return nil }
        let candidates = [
            appURL.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"),
            appURL.appendingPathComponent("Contents/Resources/codex")
        ]
        guard let cli = candidates.first(where: { isTrustedExecutable($0) }) else { return nil }
        return HostInstallation(appURL: appURL, bundleID: "com.openai.codex", executableURL: cli)
    }

    static func isTrustedExecutable(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path) &&
            isSigned(url, requirement: #"anchor apple generic and certificate leaf[subject.OU] = "2DC432GLL2""#)
    }

    private static func isSigned(_ url: URL, requirement expression: String) -> Bool {
        var requirement: SecRequirement?
        var staticCode: SecStaticCode?
        let flags = SecCSFlags(rawValue: 0)
        guard SecRequirementCreateWithString(expression as CFString, flags, &requirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(url as CFURL, flags, &staticCode) == errSecSuccess,
              let requirement, let staticCode else { return false }
        return SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
    }
}

func validateConfiguration(_ selection: ProviderSelection, in codexHome: URL, using host: HostInstallation) throws {
    guard HostInstallation.isTrustedExecutable(host.executableURL) else {
        throw SwitcherError.message("The bundled Codex executable failed the OpenAI signature check.")
    }
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent("codex-provider-validation-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: directory) }
    let out = directory.appendingPathComponent("validation.json")
    let err = directory.appendingPathComponent("validation-error.txt")
    fm.createFile(atPath: out.path, contents: nil, attributes: [.posixPermissions: 0o600])
    fm.createFile(atPath: err.path, contents: nil, attributes: [.posixPermissions: 0o600])
    let stdout = try FileHandle(forWritingTo: out), stderr = try FileHandle(forWritingTo: err)
    defer { try? stdout.close(); try? stderr.close() }
    let process = Process()
    process.executableURL = host.executableURL
    guard let model = selection.model else { throw SwitcherError.message("Choose a model before validating the configuration.") }
    process.arguments = [
        "-c", "model=\(try ConfigDocument.quote(model))",
        "-c", "model_provider=\(try ConfigDocument.quote(selection.providerID))",
        "app-server", "--strict-config", "--print-startup-config",
    ]
    // Let Codex resolve relative paths and load requirements from the selected home.
    process.currentDirectoryURL = codexHome
    process.environment = validationEnvironment(ProcessInfo.processInfo.environment, codexHome: codexHome)
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let deadline = Date().addingTimeInterval(20)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if process.isRunning {
        process.terminate()
        let stopDeadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < stopDeadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        throw SwitcherError.message("Codex configuration validation timed out. The configuration was not changed.")
    }
    guard process.terminationStatus == 0 else {
        if let handle = try? FileHandle(forReadingFrom: err),
           let diagnostic = try? handle.read(upToCount: 4096),
           unsupportedStartupCheck(diagnostic) {
            throw SwitcherError.message("This Codex version lacks the startup configuration check. Update the desktop app before switching.")
        }
        // Codex diagnostics can include private configuration values.
        throw SwitcherError.message("Codex could not validate the selection. Check config.toml and any administrator requirements.")
    }
    try verifyStartupConfiguration(Data(contentsOf: out), selectedProvider: selection.providerID)
}

func unsupportedStartupCheck(_ data: Data) -> Bool {
    let diagnostic = String(decoding: data, as: UTF8.self).lowercased()
    let unsupportedFlag = ["--print-startup-config", "--strict-config"].contains(where: diagnostic.contains)
    let argumentError = ["unexpected argument", "unknown option", "unrecognized option"].contains(where: diagnostic.contains)
    return unsupportedFlag && argumentError
}

func verifyStartupConfiguration(_ data: Data, selectedProvider: String) throws {
    struct StartupConfiguration: Decodable {
        struct ConfigurationRequirements: Decodable {
            struct Requirements: Decodable { let modelProvider: String? }
            let requirements: Requirements?
            let modelProvider: String?
        }
        let appServerVersion: String
        let configRequirements: ConfigurationRequirements
    }

    guard let configuration = try? JSONDecoder().decode(StartupConfiguration.self, from: data),
          !configuration.appServerVersion.isEmpty else {
        throw SwitcherError.message("Codex did not return a valid configuration check.")
    }
    let requirements = configuration.configRequirements
    if let pinned = requirements.requirements?.modelProvider ?? requirements.modelProvider, pinned != selectedProvider {
        throw SwitcherError.message("Your administrator requires a different model provider. The switch was canceled.")
    }
}

struct ProviderSelection: Codable, Equatable {
    let providerID: String
    let model: String?
    init(_ config: ConfigDocument) { providerID = config.providerID; model = config.model }
}

struct RestartReminder: Codable, Equatable {
    let selection: ProviderSelection
    let selectedAt: Date

    // A newly opened host clears the reminder; this is not runtime/provider verification.
    func needsRestart(hostLaunchDates: [Date?]) -> Bool {
        hostLaunchDates.isEmpty || hostLaunchDates.contains { launch in
            guard let launch else { return true }
            return launch <= selectedAt
        }
    }
}
