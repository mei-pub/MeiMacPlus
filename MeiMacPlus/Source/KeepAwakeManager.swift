import AppKit
import Foundation
import IOKit.pwr_mgt

/// XPC protocol of the privileged MeiMacPlusHelper daemon.
/// (Mirrored in MeiMacPlusHelper/Source/main.swift — keep the two in sync.)
@objc protocol MeiHelperProtocol {
    func version(reply: @escaping (String) -> Void)
    /// reply: (success, actual system value after the call, error detail)
    func setDisablesSleep(_ value: Bool, reply: @escaping (Bool, Bool, String?) -> Void)
    /// reply: (success, current value)
    func readDisablesSleep(reply: @escaping (Bool, Bool) -> Void)
    /// reply: raw `sysadminctl -screenLock status` output
    func getScreenLock(reply: @escaping (String) -> Void)
    /// mode: "off" | "immediate" | "<seconds>". Root tries the write and
    /// verifies by reading back. reply: (verified, tool output)
    func setScreenLock(_ mode: String, reply: @escaping (Bool, String?) -> Void)
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
        /// The lock requirement could not be changed: macOS 26.2's
        /// screen-lock write path (MobileKeyBag) is broken for GUI,
        /// root, and admin-authenticated sysadminctl alike. pmset and the
        /// display assertion are unaffected — callers keep the toggle on
        /// and surface this once.
        case screenLockChannelBroken(String)
    }

    static let shared = KeepAwakeManager()

    private let machServiceName = "com.meimacplus.helper"
    private let callTimeout: TimeInterval = 10

    /// Must mirror `helperVersion` in MeiMacPlusHelper/Source/main.swift.
    /// A mismatch triggers an in-place upgrade (one admin prompt) on the
    /// next toggle.
    nonisolated static let expectedHelperVersion = "1.2.1"

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

    // MARK: - Display sleep assertion (open-lid "screen stays on")

    /// The pmset flag only blocks *system* sleep; with the lid open the
    /// display would still blank after the system's display-sleep timeout
    /// (and lock). While the toggle is on we therefore also hold a
    /// `PreventUserIdleDisplaySleep` assertion — the same mechanism Caffeine
    /// and Awayke use — so an open lid never blanks the screen. Needs no
    /// privileges.
    ///
    /// The assertion is process-scoped: it lives exactly as long as
    /// MeiMacPlus runs. Quitting the app returns the display to the system's
    /// own schedule, while the lid-close behavior (pmset, persistent)
    /// remains.
    private var displayAssertion: IOPMAssertionID?

    func setDisplaySleepAssertion(_ on: Bool) {
        if on {
            guard displayAssertion == nil else { return }
            var id: IOPMAssertionID = 0
            let status = IOPMAssertionCreateWithName(
                "PreventUserIdleDisplaySleep" as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "MeiMacPlus — keep awake" as CFString,
                &id
            )
            if status == kIOReturnSuccess {
                displayAssertion = id
                sessionLog.notice("display-sleep assertion created (id \(id))")
            } else {
                sessionLog.error("display-sleep assertion failed: \(status)")
            }
        } else if let id = displayAssertion {
            IOPMAssertionRelease(id)
            displayAssertion = nil
            sessionLog.notice("display-sleep assertion released")
        }
    }

    // MARK: - Lock screen override (open-lid "no password")

    /// With the lid closed and the system awake, reopening still asks for a
    /// password: that requirement is the screen-lock setting (macOS 13+
    /// stores it in the Keychain, controlled by
    /// `sysadminctl -screenLock <off|immediate|seconds>`), NOT the legacy
    /// com.apple.screensaver defaults keys. While keep-awake is on we set it
    /// to `off` and restore the previous value when the toggle goes off.
    ///
    /// These methods are deliberately `nonisolated`: applicationWillTerminate
    /// must be able to restore the lock setting synchronously (bounded wait)
    /// from a detached task without hopping to the main actor.
    enum ScreenLockState: Equatable {
        case off
        case immediate
        case delay(seconds: Int)
        case unknown

        /// The argument string sysadminctl accepts for this state.
        var modeArgument: String {
            switch self {
            case .off: return "off"
            case .immediate: return "immediate"
            case .delay(let s): return String(s)
            case .unknown: return "immediate" // safe default on restore
            }
        }
    }

    /// Parses `sysadminctl -screenLock status` output, e.g.
    /// "2026-11-10 08:07:09.543 sysadminctl[123]: screenLock delay is immediate".
    /// Pure function, unit-tested.
    nonisolated static func parseScreenLock(_ statusText: String) -> ScreenLockState {
        let text = statusText.lowercased()
        guard text.contains("screenlock") else { return .unknown }
        if text.contains("off") { return .off }
        if text.contains("immediate") { return .immediate }
        if let range = text.range(of: #"(\d+)\s*seconds"#, options: .regularExpression),
           let seconds = Int(text[range].split(separator: " ").first ?? "") {
            return .delay(seconds: seconds)
        }
        return .unknown
    }

    private static let savedScreenLockKey = "keepAwakePrevScreenLock"
    private static let screenLockBrokenKey = "keepAwakeScreenLockChannelBroken"

    /// True once we've proven this macOS refuses every screen-lock write
    /// path (root AND admin-authenticated sysadminctl both fail on 26.2 —
    /// even System Settings can't change it). Skips further attempts so the
    /// user isn't prompted for a password that can't work.
    nonisolated static var screenLockChannelBroken: Bool {
        get { UserDefaults.standard.bool(forKey: screenLockBrokenKey) }
        set { UserDefaults.standard.set(newValue, forKey: screenLockBrokenKey) }
    }

    /// Reads the saved pre-override screen-lock mode (survives crashes).
    nonisolated private static func savedScreenLockMode() -> String? {
        UserDefaults.standard.string(forKey: savedScreenLockKey)
    }

    /// While keep-awake is on, turns the lock requirement off; when it goes
    /// off, restores the value captured at enable time. The captured value
    /// persists in UserDefaults so an abnormal exit can be recovered at the
    /// next launch.
    ///
    /// Two write paths are tried, each verified by reading the status back
    /// (sysadminctl lies with exit code 0 on failure):
    /// 1. root helper — free when a future macOS accepts it;
    /// 2. osascript with administrator privileges — the password lives only
    ///    in the authorization dialog.
    /// On macOS 26.2 both paths fail (MKBDeviceSetGracePeriod error -14;
    /// even System Settings can't write the keybag), in which case
    /// screenLockChannelBroken is latched and the screenLockChannelBroken
    /// error is thrown.
    nonisolated func applyScreenLockOverride(_ on: Bool) async throws {
        if on {
            if Self.savedScreenLockMode() == nil {
                let status = await helperScreenLockStatus() ?? ""
                let state = Self.parseScreenLock(status)
                UserDefaults.standard.set(state.modeArgument, forKey: Self.savedScreenLockKey)
            }
            // Already off? Nothing to do.
            let before = await helperScreenLockStatus() ?? ""
            guard Self.parseScreenLock(before) != .off else { return }
            switch await Self.trySetScreenLock("off") {
            case .success: return
            case .userCancelled: throw KeepAwakeError.cancelled
            case .failed: throw KeepAwakeError.screenLockChannelBroken(before)
            }
        } else if let saved = Self.savedScreenLockMode() {
            // Already back at the saved value? Just drop the record.
            if Self.parseScreenLock(await helperScreenLockStatus() ?? "").modeArgument == saved {
                UserDefaults.standard.removeObject(forKey: Self.savedScreenLockKey)
                return
            }
            switch await Self.trySetScreenLock(saved) {
            case .success:
                UserDefaults.standard.removeObject(forKey: Self.savedScreenLockKey)
            case .userCancelled:
                throw KeepAwakeError.cancelled
            case .failed:
                throw KeepAwakeError.screenLockChannelBroken(saved)
            }
        }
    }

    private enum ScreenLockWriteOutcome {
        case success
        case userCancelled
        case failed
    }

    /// Tries both write paths with verification. Latches the broken flag
    /// when both fail so later toggles skip straight to the error.
    nonisolated private static func trySetScreenLock(_ mode: String) async -> ScreenLockWriteOutcome {
        if Self.screenLockChannelBroken { return .failed }
        // Path 1: root helper.
        if let (ok, _) = await shared.helperSetScreenLock(mode), ok { return .success }
        // Path 2: osascript admin. The password never leaves the dialog.
        let (succeeded, stderr) = await shared.runOSAScript(
            "do shell script \"/usr/sbin/sysadminctl -screenLock \(mode)\" with administrator privileges"
        )
        if succeeded {
            // osascript exit 0 is not proof (sysadminctl lies); verify.
            let after = await shared.helperScreenLockStatus() ?? ""
            if Self.parseScreenLock(after).modeArgument == mode {
                return .success
            }
        } else if stderr.lowercased().contains("cancel") {
            // User dismissed the password prompt — not a broken channel.
            return .userCancelled
        }
        Self.screenLockChannelBroken = true
        return .failed
    }

    private nonisolated func helperScreenLockStatus() async -> String? {
        await callHelper { proxy, done in
            proxy.getScreenLock { done($0) }
        }
    }

    private nonisolated func helperSetScreenLock(_ mode: String) async -> (Bool, String?)? {
        await callHelper { proxy, done in
            proxy.setScreenLock(mode) { ok, detail in
                done((ok, detail))
            }
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

    nonisolated private func runOSAScript(_ source: String) async -> (succeeded: Bool, stderr: String) {
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
    /// "needs install". nonisolated so lock-screen restore can run from a
    /// detached task during application termination.
    nonisolated private func callHelper<T>(_ invoke: @escaping (MeiHelperProtocol, @escaping (T) -> Void) -> Void) async -> T? {
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
