import AppKit
import Foundation

@MainActor
func discoverHost() throws -> HostInstallation {
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").compactMap(\.bundleURL)
    let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
    let candidates = running + [installed, URL(fileURLWithPath: "/Applications/ChatGPT.app"), URL(fileURLWithPath: "/Applications/Codex.app")].compactMap { $0 }
    guard let host = candidates.lazy.compactMap(HostInstallation.at).first else {
        throw SwitcherError.message("Cannot find an OpenAI-signed Codex desktop app and bundled executable. Install the official desktop app before switching providers.")
    }
    return host
}
