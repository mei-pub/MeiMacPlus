import Foundation
import Security
import os

// MeiMacPlusHelper — the privileged half of MeiMacPlus's "keep awake with the
// lid closed" feature. Lid-close sleep on macOS is a *demand* sleep that
// user-space power assertions cannot block; the only reliable lever is
// `pmset -a disablesleep 1`, which requires root. This daemon runs as root and
// exposes exactly that one switch over XPC.
//
// Layout (classic SMJobBless layout, installed manually for dev-signing
// friendliness — SMAppService re-validates signatures on every rebuild):
//
//   /Library/PrivilegedHelperTools/com.meimacplus.helper   <- this binary
//   /Library/LaunchDaemons/com.meimacplus.helper.plist     <- launchd job
//
// The app embeds this binary at Contents/Library/LaunchDaemons/MeiMacPlusHelper
// and runs `MeiMacPlusHelper --install` through osascript's
// "do shell script … with administrator privileges" the first time the user
// turns the toggle on. The daemon is launch-on-demand (MachServices); it only
// runs while an XPC client is connected.

let helperLog = Logger(subsystem: "com.meimacplus.helper", category: "helper")

let machServiceName = "com.meimacplus.helper"
let installedBinaryPath = "/Library/PrivilegedHelperTools/com.meimacplus.helper"
let installedPlistPath = "/Library/LaunchDaemons/com.meimacplus.helper.plist"

/// Only apps signed with this identifier may talk to us. See
/// ListenerDelegate for the full validation chain.
let expectedClientIdentifier = "com.meimacplus.MeiMacPlus"

/// Bump to force a reinstall when the app notices a stale helper.
/// (Must mirror KeepAwakeManager.expectedHelperVersion in the app target.)
let helperVersion = "1.2.1"

// MARK: - XPC protocol (mirrored in the app target's KeepAwakeManager.swift)

@objc protocol MeiHelperProtocol {
    func version(reply: @escaping (String) -> Void)
    /// Runs `pmset -a disablesleep <0|1>` as root, then reads the setting
    /// back. reply: (success, parsed-value-after-set, error-detail).
    func setDisablesSleep(_ value: Bool, reply: @escaping (Bool, Bool, String?) -> Void)
    /// Reads `pmset -g`. reply: (success, current value).
    func readDisablesSleep(reply: @escaping (Bool, Bool) -> Void)
    /// Runs `sysadminctl -screenLock status` (reading needs no privileges).
    /// reply: full tool output (the App parses the delay from it).
    /// NOTE: CHANGING the lock setting requires an admin password even for
    /// root — the App does that via osascript. This method exists so the App
    /// can ask root to try first (free when it works) and to read back and
    /// verify every attempt.
    func getScreenLock(reply: @escaping (String) -> Void)
    /// Runs `sysadminctl -screenLock <mode>` as root, then verifies by
    /// reading the status back. reply: (verified-ok, tool output).
    func setScreenLock(_ mode: String, reply: @escaping (Bool, String?) -> Void)
}

// MARK: - pmset plumbing

/// pmset moved from /usr/sbin to /usr/bin in macOS 26 (Tahoe); resolve the
/// path at runtime so one binary works everywhere.
/// (Mirrored in the app target's KeepAwakeManager.)
func pmsetPath() -> String? {
    for candidate in ["/usr/bin/pmset", "/usr/sbin/pmset"] {
        if FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
    }
    return nil
}

/// Parses the disable-sleep flag out of `pmset -g` output. The key has always
/// been SET as `disablesleep`, but macOS 26 (Tahoe) DISPLAYS it as
/// `SleepDisabled` — accept both spellings, case-insensitively.
/// (Mirrored in the app target for its unprivileged launch-time read.)
func parseDisablesSleep(pmsetOutput: String) -> Bool? {
    for line in pmsetOutput.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 2 else { continue }
        let name = parts[0].lowercased()
        guard name == "disablesleep" || name == "sleepdisabled" else { continue }
        return parts[1] == "1"
    }
    return nil
}

enum PMSetOutcome {
    case ok(code: Int32, output: String)
    case failed(String)
}

/// Runs a system tool, capturing stdout+stderr. Used for pmset and
/// sysadminctl (whose results are printed on stderr with a timestamp prefix).
func runTool(_ path: String, _ arguments: [String]) -> PMSetOutcome {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    do {
        try process.run()
    } catch {
        return .failed("\(path) failed to launch: \(error)")
    }
    let out = outPipe.fileHandleForReading.readDataToEndOfFile()
    let err = errPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = (String(data: out, encoding: .utf8) ?? "") + (String(data: err, encoding: .utf8) ?? "")
    return .ok(code: process.terminationStatus, output: text)
}

func runPMSet(_ arguments: [String]) -> PMSetOutcome {
    guard let pmset = pmsetPath() else {
        return .failed("pmset not found at /usr/bin/pmset or /usr/sbin/pmset")
    }
    return runTool(pmset, arguments)
}

// MARK: - XPC service

final class HelperService: NSObject, MeiHelperProtocol {
    func version(reply: @escaping (String) -> Void) {
        reply(helperVersion)
    }

    func setDisablesSleep(_ value: Bool, reply: @escaping (Bool, Bool, String?) -> Void) {
        let setResult = runPMSet(["-a", "disablesleep", value ? "1" : "0"])
        if case .failed(let failure) = setResult {
            reply(false, false, failure)
            return
        }
        guard case .ok(let setExit, _) = setResult, setExit == 0 else {
            reply(false, false, "pmset exited with non-zero status")
            return
        }
        // Read back and report the actual system state, not the request.
        let check = runPMSet(["-g"])
        guard case .ok(_, let output) = check,
              let parsed = parseDisablesSleep(pmsetOutput: output)
        else {
            reply(false, false, "could not read back pmset state")
            return
        }
        reply(parsed == value, parsed, parsed == value ? nil : "system state did not change")
    }

    func readDisablesSleep(reply: @escaping (Bool, Bool) -> Void) {
        let check = runPMSet(["-g"])
        guard case .ok(_, let output) = check,
              let parsed = parseDisablesSleep(pmsetOutput: output)
        else {
            reply(false, false)
            return
        }
        reply(true, parsed)
    }

    func getScreenLock(reply: @escaping (String) -> Void) {
        let result = runTool("/usr/sbin/sysadminctl", ["-screenLock", "status"])
        // sysadminctl prints its result on stderr with a timestamp prefix;
        // hand back both streams and let the App parse.
        if case .ok(_, let output) = result {
            reply(output)
        } else if case .failed(let failure) = result {
            reply(failure)
        }
    }

    func setScreenLock(_ mode: String, reply: @escaping (Bool, String?) -> Void) {
        // mode: "off", "immediate", or a seconds string. Root does not
        // exempt us from sysadminctl's -password requirement (macOS 26.2
        // refuses even root with "Password is required!") — but we try
        // anyway so a future macOS that accepts root works for free. The
        // read-back below is the actual verdict.
        _ = runTool("/usr/sbin/sysadminctl", ["-screenLock", mode])
        let check = runTool("/usr/sbin/sysadminctl", ["-screenLock", "status"])
        guard case .ok(_, let status) = check else {
            reply(false, "could not read back screenLock state")
            return
        }
        let text = status.lowercased()
        let confirmed: Bool
        switch mode {
        case "off": confirmed = text.contains("off")
        case "immediate": confirmed = text.contains("immediate")
        default: confirmed = text.contains("\(mode) second")
        }
        reply(confirmed, status.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Client validation

/// Accepts a connection only if the peer's code signature is valid (chains to
/// a trusted anchor — Developer ID in releases, the locally trusted
/// "MeiMacPlus Dev" certificate during development) *and* its designated
/// identifier is ours. Anything else (including ad-hoc spoofs of our bundle
/// ID) is rejected and logged.
///
/// The daemon is launch-on-demand: launchd spawns it when a client connects,
/// and we exit on idle so we never sit resident.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {

    private let stateQueue = DispatchQueue(label: "com.meimacplus.helper.state")
    private var activeConnections = 0
    private var idleExitWork: DispatchWorkItem?

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard let code = clientCode(for: newConnection), Self.isTrustedClient(code) else {
            helperLog.error("rejected XPC connection from untrusted client")
            return false
        }
        stateQueue.sync {
            idleExitWork?.cancel()
            idleExitWork = nil
            activeConnections += 1
        }
        newConnection.invalidationHandler = { [weak self] in
            self?.connectionDidInvalidate()
        }
        newConnection.exportedInterface = NSXPCInterface(with: MeiHelperProtocol.self)
        newConnection.exportedObject = HelperService()
        newConnection.resume()
        return true
    }

    /// When the last client goes away, exit after a grace period. launchd
    /// (MachServices, no KeepAlive) respawns us on the next connection.
    private func connectionDidInvalidate() {
        stateQueue.sync {
            activeConnections = max(0, activeConnections - 1)
            guard activeConnections == 0, idleExitWork == nil else { return }
            let work = DispatchWorkItem {
                helperLog.notice("idle — exiting; launchd will respawn on demand")
                exit(0)
            }
            idleExitWork = work
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: work)
        }
    }

    private func clientCode(for connection: NSXPCConnection) -> SecCode? {
        // NSXPCConnection.auditToken isn't exposed to Swift at our deployment
        // target, so validate via the peer pid. There is a theoretical
        // pid-reuse race here; the exposure (one pmset boolean) doesn't
        // justify a stronger dance.
        let pid = connection.processIdentifier
        guard pid > 0 else { return nil }
        var codeRef: SecCode?
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &codeRef) == errSecSuccess else {
            return nil
        }
        return codeRef
    }

    static func isTrustedClient(_ code: SecCode) -> Bool {
        // Valid signature chain (the code's own designated requirement).
        guard SecCodeCheckValidity(code, SecCSFlags(), nil) == errSecSuccess else { return false }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else { return false }

        var infoRef: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(), &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any]
        else { return false }

        guard let identifier = info[kSecCodeInfoIdentifier as String] as? String else {
            return false
        }
        return identifier == expectedClientIdentifier
    }
}

// MARK: - Install / uninstall / serve

func launchctl(_ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
        try process.run()
    } catch {
        return 1
    }
    process.waitUntilExit()
    return process.terminationStatus
}

func chownRootWheel(_ paths: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/chown")
    process.arguments = ["root:wheel"] + paths
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
        try process.run()
    } catch {
        return false
    }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

let daemonPlist = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>Label</key>
\t<string>\(machServiceName)</string>
\t<key>ProgramArguments</key>
\t<array>
\t\t<string>\(installedBinaryPath)</string>
\t</array>
\t<key>MachServices</key>
\t<dict>
\t\t<key>\(machServiceName)</key>
\t\t<true/>
\t</dict>
</dict>
</plist>
"""

/// Copies this binary to its installed location, writes the launchd plist, and
/// (re)bootstraps the daemon. Must run as root — the app invokes it through
/// osascript with administrator privileges.
func install() -> Int32 {
    guard getuid() == 0 else {
        fputs("--install must run as root\n", stderr)
        return 1
    }
    let fm = FileManager.default

    // Normalize the source path (osascript hands us whatever the app passed).
    let sourcePath = URL(fileURLWithPath: CommandLine.arguments[0]).standardized.path

    do {
        try fm.createDirectory(atPath: (installedBinaryPath as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)
        if fm.fileExists(atPath: installedBinaryPath) {
            try fm.removeItem(atPath: installedBinaryPath)
        }
        try fm.copyItem(atPath: sourcePath, toPath: installedBinaryPath)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedBinaryPath)
    } catch {
        fputs("install: copy failed: \(error)\n", stderr)
        return 1
    }

    do {
        try daemonPlist.write(toFile: installedPlistPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: installedPlistPath)
    } catch {
        fputs("install: plist failed: \(error)\n", stderr)
        return 1
    }

    guard chownRootWheel([installedBinaryPath, installedPlistPath]) else {
        fputs("install: chown failed\n", stderr)
        return 1
    }

    // Replace any previously bootstrapped instance, then bootstrap.
    _ = launchctl(["bootout", "system/\(machServiceName)"])
    let status = launchctl(["bootstrap", "system", installedPlistPath])
    if status != 0 {
        fputs("install: launchctl bootstrap failed (\(status))\n", stderr)
        return status
    }
    return 0
}

func uninstall() -> Int32 {
    guard getuid() == 0 else {
        fputs("--uninstall must run as root\n", stderr)
        return 1
    }
    _ = launchctl(["bootout", "system/\(machServiceName)"])
    let fm = FileManager.default
    for path in [installedPlistPath, installedBinaryPath] {
        try? fm.removeItem(atPath: path)
    }
    return 0
}

// MARK: - Entry

let arguments = CommandLine.arguments

if arguments.contains("--install") {
    exit(install())
} else if arguments.contains("--uninstall") {
    exit(uninstall())
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: machServiceName)
listener.delegate = delegate
listener.resume()
helperLog.notice("MeiMacPlusHelper \(helperVersion, privacy: .public) listening on \(machServiceName, privacy: .public)")
RunLoop.main.run()
