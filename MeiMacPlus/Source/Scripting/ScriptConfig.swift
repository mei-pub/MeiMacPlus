import Foundation

/// Locations and bootstrap content for user scripts (Hammerspoon-style).
enum ScriptConfig {

    /// Hammerspoon's own default config directory. When it exists we reuse
    /// it verbatim — existing `init.lua`, `Spoons/`, and the hs.settings
    /// preferences domain all keep working exactly as under Hammerspoon,
    /// so migrating is "quit Hammerspoon, enable scripting here".
    static var hammerspoonDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hammerspoon", isDirectory: true)
    }

    /// MeiMacPlus's own fallback: `~/Library/Application Support/MeiMacPlus/Scripts`.
    static var appSupportScriptsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeiMacPlus/Scripts", isDirectory: true)
    }

    /// The directory actually fed to setup.lua as configdir.
    static var configDir: URL {
        prepareConfigDir(customPath: AppSettings.shared.scriptCustomPath)
    }

    static var initLuaURL: URL {
        configDir.appendingPathComponent("init.lua")
    }

    /// Pure decision logic (unit-testable). Priority:
    /// 1. A user-chosen custom path that exists on disk.
    /// 2. An existing `~/.hammerspoon` — reused verbatim, never written to.
    /// 3. The MeiMacPlus fallback (created and seeded with a starter script).
    static func pickConfigDir(customPath: String, hammerspoonExists: Bool) -> URL {
        let trimmed = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, FileManager.default.fileExists(atPath: trimmed) {
            return URL(fileURLWithPath: trimmed, isDirectory: true)
        }
        return hammerspoonExists ? hammerspoonDirectory : appSupportScriptsDirectory
    }

    /// Resolve (and on the fallback path, create + seed) the config dir.
    static func prepareConfigDir(customPath: String) -> URL {
        let fm = FileManager.default
        let dir = pickConfigDir(customPath: customPath,
                                hammerspoonExists: fm.fileExists(atPath: hammerspoonDirectory.path))
        guard dir == appSupportScriptsDirectory else { return dir }
        _ = ensureDirectory()
        installSampleInitLuaIfAbsent()
        return dir
    }

    @discardableResult
    static func ensureDirectory() -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: appSupportScriptsDirectory, withIntermediateDirectories: true)
            return true
        } catch {
            NSLog("MeiMacPlus: failed to create scripts directory: \(error)")
            return false
        }
    }

    /// First enable: drop a commented, self-documenting starter script so the
    /// feature is immediately graspable. Never overwrites user edits, and is
    /// never used when an existing Hammerspoon config is being reused.
    static func installSampleInitLuaIfAbsent() {
        guard !FileManager.default.fileExists(atPath: appSupportScriptsDirectory.appendingPathComponent("init.lua").path) else { return }
        guard ensureDirectory() else { return }
        try? sampleInitLua.write(to: appSupportScriptsDirectory.appendingPathComponent("init.lua"),
                                 atomically: true, encoding: .utf8)
    }

    private static let sampleInitLua = """
    -- MeiMacPlus scripting — Hammerspoon-compatible Lua.
    -- This file runs whenever scripting is enabled or reloaded.
    -- Full API reference: https://www.hammerspoon.org/docs/
    --
    -- Tip: you can point MeiMacPlus at any scripts folder in Settings →
    -- Scripting, and an existing ~/.hammerspoon directory is always picked
    -- up automatically.

    -- Example: ⌥⌘Y pops a notification
    -- hs.hotkey.bind({ "alt", "cmd" }, "y", function()
    --     hs.notify.show("MeiMacPlus", "Hello", "from init.lua")
    -- end)

    -- Example: tile the front window to the left half of its screen
    -- hs.hotkey.bind({ "ctrl", "alt" }, "left", function()
    --     local win = hs.window.focusedWindow()
    --     if win then win:moveToUnit("[0,0,0.5,1]") end
    -- end)

    print("MeiMacPlus scripts loaded")
    """
}
