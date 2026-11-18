//
//  LuaRuntime.h — Hammerspoon-style Lua runtime bootstrap for MeiMacPlus.
//
//  Derived from Hammerspoon's MJLua.m (MIT © Hammerspoon contributors);
//  see THIRD_PARTY_LICENSES.md. Adapted for MeiMacPlus: single instance,
//  no Sparkle/dock-icon/preferences dependencies, and console/notify/log
//  output is routed to host-provided blocks instead of MJ* controllers.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The app-wide Lua runtime. `hs.*` extensions are loaded lazily from the
/// vendored runtime bundled at `Contents/Frameworks/hs` (see
/// scripts/fetch_hs_runtime.sh); pure-Lua modules and `setup.lua` come from
/// `Contents/Resources/extensions`.
///
/// All API must be used from the main thread (hs extension callbacks are
/// marshalled there by design).
@interface LuaRuntime : NSObject

@property (class, readonly, strong) LuaRuntime *shared;

/// Every console log line (Lua `print`, module logs, errors). Main thread.
/// When nil, lines fall back to os_log.
@property (copy, nullable) void (^logHandler)(NSString *line);
/// `hs.openConsole()` / `hs.showError()`. Main thread. Optional.
@property (copy, nullable) void (^openConsoleHandler)(void);
/// `hs._notify()`. Main thread. When nil, falls back to logHandler.
@property (copy, nullable) void (^notifyHandler)(NSString *message);

/// Directory that contains the user's `init.lua` (and Spoons/).
@property (readonly, copy, nullable) NSString *configDir;
@property (readonly, getter=isRunning) BOOL running;

/// Create the Lua state, run `setup.lua`, then the user's `init.lua`
/// (when present). Errors in `init.lua` surface via logHandler, not here —
/// a failing user script still yields a running environment. A returned
/// failure means the vendored runtime itself could not boot.
- (BOOL)startWithConfigDir:(NSString *)configDir;

/// Run `hs.shutdownCallback` (if the config set one) and destroy the state.
- (void)stop;

/// `hs.reload()`: stop, then start again with the same configDir.
- (void)reload;

/// Evaluate a chunk the way the Hammerspoon console does
/// (`load("return "..s)` with a fallback to `load(s)`).
/// Returns the printed result or the error text; nil when not running.
- (nullable NSString *)runString:(NSString *)command;

/// Invoke `hs.accessibilityStateCallback` if the user's config defined one.
- (void)notifyAccessibilityStateChanged;

/// Deliver text sent via the "Send to MeiMacPlus" service to the user's
/// `hs.textDroppedToDockIconCallback`, if defined.
- (void)notifyTextDropped:(NSString *)text;

@end

NS_ASSUME_NONNULL_END
