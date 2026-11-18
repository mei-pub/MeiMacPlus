//
//  HSMJStubs.m — host-side implementations of Hammerspoon app-layer symbols
//  that a few vendored hs.* dylibs resolve against the host binary via
//  flat-namespace dlopen (upstream defines these in the Hammerspoon.app
//  target, which we do not embed).
//
//  Derivative work: interface shapes transcribed from Hammerspoon 1.1.1
//  (MIT © Hammerspoon contributors); see THIRD_PARTY_LICENSES.md.
//
//  Affected dylibs (see scripts/fetch_hs_runtime.sh scan):
//    libnotify.dylib        -> MJUserNotificationManager (class)
//    libconsole.dylib       -> MJConsoleWindowController (class),
//                              ConsoleDarkModeEnabled/SetEnabled (functions)
//    libwebviewtoolbar.dylib-> MJConsoleWindowController (class)
//    libdockicon.dylib      -> MJDockIconVisible/SetVisible (functions)
//    liburlevent.dylib      -> MJDockIconVisible/SetVisible (functions)
//
//  Behavior mapping:
//    hs.notify posts through NSUserNotificationCenter as before; only the
//    shared-delegate hook is stubbed. hs.console color/font setters are
//    accepted and stored but do not drive MeiMacPlus's SwiftUI console.
//    MeiMacPlus is LSUIElement, so dock-icon toggles are no-ops.
//

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <LuaSkin/LuaSkin.h>

#pragma mark - MJUserNotificationManager (libnotify)

// libnotify only calls +sharedManager, to make sure the core app installed a
// delegate on the shared NSUserNotificationCenter before swapping in its own.
// A plain singleton object is sufficient: the delegate methods are optional
// and simply won't be implemented.
@interface MJUserNotificationManager : NSObject
@end

@implementation MJUserNotificationManager

+ (instancetype)sharedManager {
    static MJUserNotificationManager *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

@end

#pragma mark - MJConsoleWindowController (libconsole, libwebviewtoolbar)

// hs.console reads/writes these color/font properties and calls
// +singleton/reflectDefaults; libwebviewtoolbar only needs the class and its
// NSWindowController window plumbing (nil window is fine for our purposes).
@interface MJConsoleWindowController : NSWindowController
@property (copy, nullable) NSColor *MJColorForStdout;
@property (copy, nullable) NSColor *MJColorForCommand;
@property (copy, nullable) NSColor *MJColorForResult;
@property (copy, nullable) NSFont *consoleFont;
@property (copy, nullable) NSNumber *maxConsoleOutputHistory;
@end

@implementation MJConsoleWindowController
@end

@implementation MJConsoleWindowController (MeiMacPlusStubs)

+ (instancetype)singleton {
    static MJConsoleWindowController *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (void)reflectDefaults {
    // Upstream re-applies console colors/font from preferences; MeiMacPlus's
    // console appearance is not driven by these values.
}

@end

#pragma mark - Console dark mode (libconsole)

static BOOL sConsoleDarkMode = NO;

// These symbols are only referenced by vendored dylibs at runtime (flat
// namespace), so nothing in this binary statically links them — keep the
// linker's dead-code stripping from dropping them.
__attribute__((used)) BOOL ConsoleDarkModeEnabled(void) {
    return sConsoleDarkMode;
}

__attribute__((used)) void ConsoleDarkModeSetEnabled(BOOL enabled) {
    sConsoleDarkMode = enabled;
}

#pragma mark - Dock icon visibility (libdockicon, liburlevent)

// MeiMacPlus runs LSUIElement (accessory); hs.dockIcon(true) promotes it to a
// regular app (dock icon + Cmd-Tab), like upstream.
__attribute__((used)) BOOL MJDockIconVisible(void) {
    return NSApplication.sharedApplication.activationPolicy == NSApplicationActivationPolicyRegular;
}

__attribute__((used)) void MJDockIconSetVisible(BOOL visible) {
    NSApplicationActivationPolicy policy = visible
        ? NSApplicationActivationPolicyRegular
        : NSApplicationActivationPolicyAccessory;
    [NSApplication.sharedApplication setActivationPolicy:policy];
    if (visible) {
        [NSApplication.sharedApplication activateIgnoringOtherApps:YES];
    }
}

#pragma mark - AppleScript support (sdef "execute lua code", ported from HSAppleScript.m)

NSString * const HSAppleScriptEnabledKey = @"HSAppleScriptEnabledKey";

__attribute__((used)) BOOL HSAppleScriptEnabled(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:HSAppleScriptEnabledKey];
}

__attribute__((used)) void HSAppleScriptSetEnabled(BOOL enabled) {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:HSAppleScriptEnabledKey];
}

// Upstream's lua bridge: hs.__appleScriptRunString (defined by _coresetup)
// returns (ok, result-string).
static NSString *MeiRunLuaViaAppleScriptBridge(NSScriptCommand *command, NSString *lua) {
    LuaSkin *skin = [LuaSkin sharedWithState:NULL];
    lua_State *L = skin.L;
    if (!L) {
        [command setScriptErrorNumber:-50];
        [command setScriptErrorString:@"Lua runtime is not running"];
        return @"Error";
    }

    lua_getglobal(L, "hs");
    if (lua_getfield(L, -1, "__appleScriptRunString") != LUA_TFUNCTION) {
        [command setScriptErrorNumber:-50];
        [command setScriptErrorString:@"hs.__appleScriptRunString is not a function"];
        lua_pop(L, 2);
        return @"Error";
    }
    lua_pushstring(L, lua.UTF8String);
    if (![skin protectedCallAndTraceback:1 nresults:2]) {
        NSString *errMsg = [NSString stringWithFormat:@"callback error: %s", lua_tostring(L, -1)];
        [skin logError:errMsg];
        [command setScriptErrorNumber:-50];
        [command setScriptErrorString:errMsg];
        lua_pop(L, 2);
        return @"Error";
    }
    NSString *result = [skin toNSObjectAtIndex:-1];
    BOOL ok = lua_toboolean(L, -2);
    lua_pop(L, 3);
    if (ok) return result;
    [command setScriptErrorNumber:-50];
    [command setScriptErrorString:result];
    return @"Error";
}

@interface MeiExecuteLuaCommand : NSScriptCommand
@end

@implementation MeiExecuteLuaCommand

- (id)performDefaultImplementation {
    NSDictionary *args = self.evaluatedArguments;
    if (args.count == 0) {
        [self setScriptErrorNumber:-50];
        [self setScriptErrorString:@"A parameter is expected: tell MeiMacPlus to execute lua code \"…\""];
        return @"Error";
    }
    NSString *lua = [args valueForKey:@""] ?: @"";
    if (!HSAppleScriptEnabled()) {
        [self setScriptErrorNumber:-50];
        [self setScriptErrorString:@"AppleScript support is disabled. Enable it with hs.allowAppleScript(true) in your scripts."];
        return @"Error";
    }
    return MeiRunLuaViaAppleScriptBridge(self, lua);
}

@end

#pragma mark - Keep-alive

// Every stub symbol above is referenced only by vendored dylibs at runtime,
// so nothing in this binary links them statically. This anchor keeps the
// linker's dead-code stripping from dropping them (ObjC classes above are
// already rooted via __objc_classlist).
__attribute__((used)) static void meiHSMJStubsKeepAlive(void) {
    (void)ConsoleDarkModeEnabled;
    (void)ConsoleDarkModeSetEnabled;
    (void)MJDockIconVisible;
    (void)MJDockIconSetVisible;
    (void)HSAppleScriptEnabled;
    (void)HSAppleScriptSetEnabled;
}
