import AppIntents
import Foundation

/// Shortcuts integration: run a snippet of Lua in the embedded Hammerspoon
/// runtime (the App-Intents successor to upstream's ExecuteLua SiriKit
/// intent). Any intent linked into the app is discoverable in Shortcuts'
/// action library.
struct ExecuteLuaIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Lua in MeiMacPlus"
    static var description = IntentDescription("Executes Lua code in MeiMacPlus's embedded Hammerspoon runtime and returns the printed result.")
    static var openAppWhenRun = false

    @Parameter(title: "Lua Code")
    var luaCode: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let code = luaCode
        let output = await MainActor.run { () -> String in
            guard LuaRuntime.shared.isRunning else {
                return "MeiMacPlus scripting is not running (enable it in MeiMacPlus settings)"
            }
            return LuaRuntime.shared.run(code) ?? ""
        }
        return .result(value: output)
    }
}
