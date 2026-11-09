import AppKit
import Foundation

/// XPC protocol of the privileged MeiMacPlusHelper daemon.
/// (Mirrored in MeiMacPlusHelper/Source/main.swift — keep the two in sync.)
@objc protocol MeiHelperProtocol {
    func version(reply: @escaping (String) -> Void)
    /// reply: (success, actual system value after the call, error detail)
    func setDisablesSleep(_ value: Bool, reply: @escaping (Bool, Bool, String?) -> Void)
    /// reply: (success, current value)
    func readDisablesSleep(reply: @escaping (Bool, Bool) -> Void)
}

/// Drives the "keep awake with the lid closed" toggle.
///
/// Lid-close sleep on macOS is a demand sleep that user-space power
/// assertions cannot block; the only reliable lever is
/// `pmset -a disablesleep 1`, which requires root. Writes go through the
/// privileged helper daemon (`com.meimacplus.helper`, installed on first
/// enable with one administrator prompt); reads are plain unprivileged
/// `pmset -g`, so the toggle can always mirror the real system state.
@MainActor
final class KeepAwakeManager {

    enum KeepAwakeError: Error {
        /// The user dismissed the administrator password prompt.
        case cancelled
        /// The helper binary is missing from the app bundle.
        case helperMissing
        case installFailed(String)
        case commandFailed(String)
    }

    static let shared = KeepAwakeManager()

    private let machServiceName = "com.meimacplus.helper"
    private let callTimeout: TimeInterval = 10

    /// Must mirror `helperVersion` in MeiMacPlusHelper/Source/main.swift.
    /// A mismatch triggers an in-place upgrade (one admin prompt) on the
    /// next toggle.
    nonisolated static let expectedHelperVersion = "1.1.2"

    // MARK: - Reading system state (unprivileged)

    /// pmset moved from /usr/sbin to /usr/bin in macOS 26 (Tahoe); resolve
    /// at runtime. (Mirrored in the helper target.)
    nonisolated static func pmsetPath() -> String? {
        for candidate in ["/usr/bin/pmset", "/usr/sbin/pmset"] {
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Parses the disable-sleep flag out of `pmset -g` output. The key has
    /// always been SET as `disablesleep`, but macOS 26 (Tahoe) DISPLAYS it
    /// as `SleepDisabled` — accept both spellings, case-insensitively.
    /// Pure function, unit-tested. (Mirrored in the helper target.)
    nonisolated static func parseDisablesSleep(pmsetOutput: String) -> Bool? {
        for line in pmsetOutput.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { continue }
            let name = parts[0].lowercased()
            guard name == "disablesleep" || name == "sleepdisabled" else { continue }
            return parts[1] == "1"
        }
        return nil
    }

    /// Current system state via `pmset -g` — readable without privileges.
    /// Blocking; call off the main thread.
    nonisolated static func readSystemDisablesSleep() -> Bool? {
        guard let pmset = pmsetPath() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pmset)
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return parseDisablesSleep(pmsetOutput: String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: - Applying the toggle

    /// Sets the system state to `enabled`. If the helper daemon isn't
    /// reachable, installs it first (one administrator prompt) and retries.
    /// The helper verifies the change by reading the setting back; a
    /// successful return means the system really is in the requested state.
    func apply(_ enabled: Bool) async throws {
        // Upgrade path: replace an older installed helper before using it
        // (installing over the running daemon re-bootstraps it).
        if let installed = await helperVersion(), installed != Self.expectedHelperVersion {
            try await installHelper()
        }
        if let (ok, _, detail) = await helperSet(enabled) {
            if ok { return }
            // Helper answered but the change didn't stick — surface it rather
            // than blindly reinstalling.
            throw KeepAwakeError.commandFailed(detail ?? "helper did not confirm the change")
        }
        // Helper unreachable (not installed or not answering): install, retry.
        try await installHelper()
        let retried = await helperSet(enabled)
        guard let retried, retried.0 else {
            throw KeepAwakeError.commandFailed(retried?.2 ?? "helper did not confirm the change")
        }
    }

    // MARK: - Helper installation

    /// Runs the bundled helper's `--install` through osascript with
    /// administrator privileges (self-copy to
    /// /Library/PrivilegedHelperTools + launchd bootstrap), then waits for
    /// the daemon to answer its mach service. Also serves as the upgrade
    /// path: installing over an older helper replaces it.
    private func installHelper() async throws {
        // The helper is embedded at Contents/Library/LaunchDaemons/ — outside
        // the Resources directory, so Bundle resource lookups can't see it.
        // Address it by path instead.
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchDaemons", isDirectory: true)
            .appendingPathComponent("MeiMacPlusHelper")
        guard FileManager.default.fileExists(atPath: bundled.path) else {
            throw KeepAwakeError.helperMissing
        }
        let escaped = bundled.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped) --install\" with administrator privileges"
        let (succeeded, stderrText) = await runOSAScript(script)
        if !succeeded {
            // osascript reports the dismissed prompt as "execution error:
            // User canceled. (-128)".
            if stderrText.lowercased().contains("cancel") {
                throw KeepAwakeError.cancelled
            }
            throw KeepAwakeError.installFailed(stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        for _ in 0..<20 {
            if await helperVersion() != nil { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        throw KeepAwakeError.installFailed("helper installed but not responding")
    }

    private func runOSAScript(_ source: String) async -> (succeeded: Bool, stderr: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", source]
                let errPipe = Pipe()
                process.standardOutput = Pipe()
                process.standardError = errPipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (false, "osascript failed to launch: \(error)"))
                    return
                }
                let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: (true, ""))
                } else {
                    let text = String(data: data, encoding: .utf8) ?? "exit \(process.terminationStatus)"
                    continuation.resume(returning: (false, text))
                }
            }
        }
    }

    // MARK: - XPC plumbing

    private func helperSet(_ value: Bool) async -> (Bool, Bool, String?)? {
        await callHelper { proxy, done in
            proxy.setDisablesSleep(value) { ok, actual, detail in
                done((ok, actual, detail))
            }
        }
    }

    private func helperVersion() async -> String? {
        await callHelper { proxy, done in
            proxy.version { done($0) }
        }
    }

    /// Runs one helper RPC with a timeout. Returns nil when the helper can't
    /// be reached (not installed, dead, or too slow) — callers treat that as
    /// "needs install".
    private func callHelper<T>(_ invoke: @escaping (MeiHelperProtocol, @escaping (T) -> Void) -> Void) async -> T? {
        await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: MeiHelperProtocol.self)
            connection.resume()

            let lock = NSLock()
            var finished = false
            let finish: (T?) -> Void = { result in
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                connection.invalidate()
                continuation.resume(returning: result)
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + callTimeout) { finish(nil) }

            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in finish(nil) }) as? MeiHelperProtocol else {
                finish(nil)
                return
            }
            invoke(proxy) { finish($0) }
        }
    }
}
