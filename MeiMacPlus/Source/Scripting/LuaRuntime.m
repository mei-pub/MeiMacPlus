//
//  LuaRuntime.m — Hammerspoon-style Lua runtime bootstrap for MeiMacPlus.
//
//  Derived from Hammerspoon's MJLua.m (MIT © Hammerspoon contributors);
//  see THIRD_PARTY_LICENSES.md. Adapted for MeiMacPlus: single instance,
//  no Sparkle/dock-icon/preferences dependencies, and console/notify/log
//  output is routed to host-provided blocks instead of MJ* controllers.
//

#import "LuaRuntime.h"
#import <LuaSkin/LuaSkin.h>
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>
#import <sys/utsname.h>
#import <sys/sysctl.h>
#import <errno.h>


// ---------------------------------------------------------------------------
// Shared state (single runtime, like upstream's globals)
// ---------------------------------------------------------------------------

static LuaRuntime *sShared = nil;

static int evalfn = LUA_NOREF;
static int completionsForWordFn = LUA_NOREF; // kept alive for future REPL completion UI
static LSRefTable refTable;
static lua_CFunction oldPanicFunction = NULL;

static NSString *sConfigDir = nil;
static NSString *sConfigFile = @"init.lua";
static BOOL sRunning = NO;

static void (^sLogHandler)(NSString *) = nil;
static void (^sOpenConsoleHandler)(void) = nil;
static void (^sNotifyHandler)(NSString *) = nil;

static void LuaRuntimeDeliverLog(NSString *line) {
    if (sLogHandler) {
        sLogHandler(line);
    } else {
        NSLog(@"[script] %@", line);
    }
}

// ---------------------------------------------------------------------------
// LuaSkin log delegate
// ---------------------------------------------------------------------------

@interface MeiLuaSkinDelegate : NSObject <LuaSkinDelegate>
@end

@implementation MeiLuaSkinDelegate

- (void)handleCatastrophe:(NSString *)message {
    // LuaSkin could not perform a vital operation. Surface it; the host
    // decides whether that is fatal (upstream shows an alert and exits).
    LuaRuntimeDeliverLog([NSString stringWithFormat:@"LuaSkin catastrophe: %@", message]);
}

- (void)logForLuaSkinAtLevel:(int)level withMessage:(NSString *)theMessage {
    static NSArray<NSString *> *levels = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        levels = @[ @"ERROR", @"WARN", @"INFO", @"DEBUG", @"VERBOSE" ];
    });
    NSString *tag = (level >= 1 && (NSUInteger)level <= levels.count) ? levels[level - 1] : @"LOG";
    LuaRuntimeDeliverLog([NSString stringWithFormat:@"[%@] %@", tag, theMessage]);
}

- (void)logKnownBug:(NSString *)message, ... {
    va_list args;
    va_start(args, message);
    NSString *formatted = [[NSString alloc] initWithFormat:message arguments:args];
    va_end(args);
    LuaRuntimeDeliverLog([NSString stringWithFormat:@"[knownbug] %@", formatted]);
}

@end

// ---------------------------------------------------------------------------
// hs core library (functions upstream registers as `hs.*` in MJLua.m)
// ---------------------------------------------------------------------------

/// hs.openConsole([bringToFront])
static int core_openconsole(lua_State *L) {
    if (!(lua_isboolean(L, 1) && !lua_toboolean(L, 1))) {
        [NSApplication.sharedApplication activateIgnoringOtherApps:YES];
    }
    if (sOpenConsoleHandler) sOpenConsoleHandler();
    return 0;
}

/// hs.closeConsole()
static int core_closeconsole(lua_State * __unused L) {
    if (sOpenConsoleHandler) sOpenConsoleHandler();
    return 0;
}

/// hs.open(filePath) -> bool
static int core_open(lua_State *L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TSTRING, LS_TBREAK];

    NSURL *pathURL = [NSURL fileURLWithPath:[skin toNSObjectAtIndex:1]];
    BOOL result = [NSWorkspace.sharedWorkspace openURL:pathURL];

    lua_pushboolean(L, result);
    return 1;
}

/// hs.reload()
static int core_reload(lua_State * __unused L) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [LuaRuntime.shared reload];
    });
    return 0;
}

/// hs.focus()
static int core_focus(lua_State * __unused L) {
    [NSApplication.sharedApplication activateIgnoringOtherApps:YES];
    return 0;
}

/// hs.menuIcon([state]) -> bool — show/hide MeiMacPlus's menu bar icon.
static int core_menuicon(lua_State *L) {
    id delegate = NSApplication.sharedApplication.delegate;
    if (lua_isboolean(L, 1)) {
        SEL set = NSSelectorFromString(@"setMenuBarIconVisible:");
        if (delegate && [delegate respondsToSelector:set]) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:
                [delegate methodSignatureForSelector:set]];
            [inv setTarget:delegate];
            [inv setSelector:set];
            BOOL arg = lua_toboolean(L, 1);
            [inv setArgument:&arg atIndex:2];
            [inv invoke];
        }
    }
    SEL get = NSSelectorFromString(@"menuBarIconVisible");
    if (delegate && [delegate respondsToSelector:get]) {
        lua_pushboolean(L, (BOOL)[(id)delegate performSelector:get]);
    } else {
        lua_pushboolean(L, YES);
    }
    return 1;
}

/// hs.dockIcon([state]) -> bool — wrapper lives in hs.dockicon's Lua layer,
/// the core hook is MJDockIconVisible/SetVisible (HSMJStubs.m).

/// hs.consoleOnTop([state]) -> bool — keep the script console floating.
static int core_consoleontop(lua_State *L) {
    id delegate = NSApplication.sharedApplication.delegate;
    SEL sel = NSSelectorFromString(@"setConsoleFloating:");
    BOOL state = lua_toboolean(L, 1);
    BOOL hasArg = lua_isboolean(L, 1);
    if (hasArg && delegate && [delegate respondsToSelector:sel]) {
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:
            [delegate methodSignatureForSelector:sel]];
        [inv setTarget:delegate];
        [inv setSelector:sel];
        BOOL arg = state;
        [inv setArgument:&arg atIndex:2];
        [inv invoke];
    }
    SEL getter = NSSelectorFromString(@"consoleFloating");
    if (delegate && [delegate respondsToSelector:getter]) {
        lua_pushboolean(L, (BOOL)[(id)delegate performSelector:getter]);
    } else {
        lua_pushboolean(L, NO);
    }
    return 1;
}

/// hs.openPreferences() / hs.closePreferences()
static int core_openpreferences(lua_State * __unused L) {
    id delegate = NSApplication.sharedApplication.delegate;
    SEL sel = NSSelectorFromString(@"openPreferencesWindow");
    if (delegate && [delegate respondsToSelector:sel]) { [delegate performSelector:sel]; }
    return 0;
}

static int core_closepreferences(lua_State * __unused L) {
    id delegate = NSApplication.sharedApplication.delegate;
    SEL sel = NSSelectorFromString(@"closePreferencesWindow");
    if (delegate && [delegate respondsToSelector:sel]) { [delegate performSelector:sel]; }
    return 0;
}

/// hs.openAbout()
static int core_openabout(lua_State * __unused L) {
    [NSApplication.sharedApplication activateIgnoringOtherApps:YES];
    [NSApplication.sharedApplication orderFrontStandardAboutPanel:nil];
    return 0;
}

/// hs.autoLaunch([state]) -> bool — login item (SMAppService).
static int core_autolaunch(lua_State *L) {
    id delegate = NSApplication.sharedApplication.delegate;
    if (lua_isboolean(L, 1)) {
        SEL set = NSSelectorFromString(@"setLoginItemEnabled:");
        if (delegate && [delegate respondsToSelector:set]) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:
                [delegate methodSignatureForSelector:set]];
            [inv setTarget:delegate];
            [inv setSelector:set];
            BOOL arg = lua_toboolean(L, 1);
            [inv setArgument:&arg atIndex:2];
            [inv invoke];
        }
    }
    SEL get = NSSelectorFromString(@"isLoginItemEnabled");
    if (delegate && [delegate respondsToSelector:get]) {
        lua_pushboolean(L, (BOOL)[(id)delegate performSelector:get]);
    } else {
        lua_pushboolean(L, NO);
    }
    return 1;
}

/// hs.processInfo — read-only table describing this MeiMacPlus instance.
static int pushAppInfo(lua_State *L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];

    NSString *arch = @"Unknown";
    struct utsname uts;
    if (uname(&uts) == 0) {
        arch = [NSString stringWithCString:uts.machine encoding:NSUTF8StringEncoding];
    }

    int isTranslated = 0;
    size_t size = sizeof(isTranslated);
    if (sysctlbyname("sysctl.proc_translated", &isTranslated, &size, NULL, 0) == -1 && errno == ENOENT) {
        isTranslated = 0;
    }

    NSBundle *bundle = NSBundle.mainBundle;
    NSDictionary *appInfo = @{
        @"version": bundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"?",
        @"build": bundle.infoDictionary[@"CFBundleVersion"] ?: @"?",
        @"resourcePath": bundle.resourcePath ?: @"",
        @"bundlePath": bundle.bundlePath ?: @"",
        @"executablePath": bundle.executablePath ?: @"",
        @"frameworksPath": bundle.privateFrameworksPath ?: @"",
        @"processID": @(getpid()),
        @"bundleID": bundle.bundleIdentifier ?: @"",
        @"arch": arch,
        @"isRosetta": @(isTranslated),
        @"buildTime": @(__DATE__ ", " __TIME__),
#ifdef DEBUG
        @"debugBuild": @(YES),
#else
        @"debugBuild": @(NO),
#endif
    };

    [skin pushNSObject:appInfo];
    return 1;
}

/// hs.accessibilityState(shouldPrompt) -> bool
static int core_accessibilityState(lua_State *L) {
    BOOL shouldPrompt = lua_toboolean(L, 1);
    BOOL enabled = AXIsProcessTrusted();
    if (shouldPrompt && !enabled) {
        NSDictionary *options = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    }
    lua_pushboolean(L, enabled);
    return 1;
}

// Heuristic borrowed from upstream MJLua.m: if we can read on-screen window
// titles owned by other processes, Screen Recording permission is granted.
static BOOL isScreenRecordingEnabled(void) {
    BOOL canRecordScreen = NO;
    pid_t ourPID = NSRunningApplication.currentApplication.processIdentifier;

    CFArrayRef windowList = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    NSUInteger count = windowList ? CFArrayGetCount(windowList) : 0;
    for (NSUInteger i = 0; i < count; i++) {
        NSDictionary *info = (NSDictionary *)CFArrayGetValueAtIndex(windowList, i);
        pid_t pid = [info[(id)kCGWindowOwnerPID] intValue];
        if (pid == ourPID) continue;
        NSString *windowName = info[(id)kCGWindowName];
        NSString *ownerName = info[(id)kCGWindowOwnerName];
        if (windowName.length > 0 && ![ownerName isEqualToString:@"Dock"]) {
            canRecordScreen = YES;
            break;
        }
    }
    if (windowList) CFRelease(windowList);
    return canRecordScreen;
}

/// hs.screenRecordingState(shouldPrompt) -> bool
static int core_screenRecordingState(lua_State *L) {
    BOOL shouldPrompt = lua_toboolean(L, 1);
    BOOL enabled = isScreenRecordingEnabled();
    if (shouldPrompt) {
        // Triggering CGDisplayStream once makes macOS show the
        // Screen Recording permission prompt when not yet granted.
        CGDisplayStreamRef stream = CGDisplayStreamCreate(CGMainDisplayID(), 1, 1, kCVPixelFormatType_32BGRA, nil, ^(CGDisplayStreamFrameStatus s, uint64_t t, IOSurfaceRef f, CGDisplayStreamUpdateRef u) {});
        if (stream) CFRelease(stream);
    }
    lua_pushboolean(L, enabled);
    return 1;
}

/// hs.microphoneState(shouldPrompt) -> bool
static int core_microphoneState(lua_State *L) {
    BOOL shouldPrompt = lua_toboolean(L, 1);
    switch ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]) {
        case AVAuthorizationStatusAuthorized:
            lua_pushboolean(L, YES);
            break;
        case AVAuthorizationStatusNotDetermined:
            if (shouldPrompt) {
                [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(__unused BOOL granted) {}];
            }
            lua_pushboolean(L, NO);
            break;
        default:
            lua_pushboolean(L, NO);
            break;
    }
    return 1;
}

/// hs.cameraState(shouldPrompt) -> bool
static int core_cameraState(lua_State *L) {
    BOOL shouldPrompt = lua_toboolean(L, 1);
    switch ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo]) {
        case AVAuthorizationStatusAuthorized:
            lua_pushboolean(L, YES);
            break;
        case AVAuthorizationStatusNotDetermined:
            if (shouldPrompt) {
                [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(__unused BOOL granted) {}];
            }
            lua_pushboolean(L, NO);
            break;
        default:
            lua_pushboolean(L, NO);
            break;
    }
    return 1;
}

/// hs.allowAppleScript([state]) -> bool
/// Gate for `tell application "MeiMacPlus" to execute lua code "…"` (see
/// MeiMacPlus.sdef). Off by default, exactly like upstream.
static int core_allowAppleScript(lua_State *L) {
    // Same key MeiExecuteLuaCommand gates on (HSMJStubs.m, MeiHSRuntime.dylib).
    if (lua_isboolean(L, 1)) {
        [NSUserDefaults.standardUserDefaults setBool:lua_toboolean(L, 1)
                                              forKey:@"HSAppleScriptEnabledKey"];
    }
    lua_pushboolean(L, [NSUserDefaults.standardUserDefaults boolForKey:@"HSAppleScriptEnabledKey"]);
    return 1;
}

/// hs.uploadCrashData([state]) -> bool
/// MeiMacPlus does not upload crash data; kept as a constant stub.
static int core_uploadCrashData(lua_State * __unused L) {
    lua_pushboolean(L, NO);
    return 1;
}

/// hs.getObjectMetatable(name) -> table or nil
static int core_getObjectMetatable(lua_State *L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TSTRING, LS_TBREAK];
    luaL_getmetatable(L, lua_tostring(L, 1));
    return 1;
}

/// hs.cleanUTF8forConsole(inString) -> outString
static int core_cleanUTF8(lua_State *L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TANY, LS_TBREAK];
    [skin pushNSObject:[skin getValidUTF8AtIndex:1]];
    return 1;
}

static int core_exit(lua_State * __unused L) {
    [NSApplication.sharedApplication terminate:nil];
    return 0;
}

static int core_logmessage(lua_State *L) {
    size_t len;
    const char *s = lua_tolstring(L, 1, &len);
    NSString *str = [[NSString alloc] initWithData:[NSData dataWithBytes:s length:len] encoding:NSUTF8StringEncoding];
    if (str == nil) {
        core_cleanUTF8(L);
        s = lua_tolstring(L, -1, &len);
        str = [[NSString alloc] initWithData:[NSData dataWithBytes:s length:len] encoding:NSUTF8StringEncoding];
    }
    LuaRuntimeDeliverLog(str ?: @"");
    return 0;
}

static int core_notify(lua_State *L) {
    size_t len;
    const char *s = lua_tolstring(L, 1, &len);
    NSString *str = [[NSString alloc] initWithData:[NSData dataWithBytes:s length:len] encoding:NSUTF8StringEncoding] ?: @"";
    if (sNotifyHandler) {
        sNotifyHandler(str);
    } else {
        LuaRuntimeDeliverLog([NSString stringWithFormat:@"-- notify: %@", str]);
    }
    return 0;
}

static luaL_Reg corelib[] = {
    {"openConsole", core_openconsole},
    {"closeConsole", core_closeconsole},
    {"open", core_open},
    {"reload", core_reload},
    {"focus", core_focus},
    {"accessibilityState", core_accessibilityState},
    {"screenRecordingState", core_screenRecordingState},
    {"microphoneState", core_microphoneState},
    {"cameraState", core_cameraState},
    {"allowAppleScript", core_allowAppleScript},
    {"menuIcon", core_menuicon},
    {"consoleOnTop", core_consoleontop},
    {"openPreferences", core_openpreferences},
    {"closePreferences", core_closepreferences},
    {"openAbout", core_openabout},
    {"autoLaunch", core_autolaunch},
    {"uploadCrashData", core_uploadCrashData},
    {"getObjectMetatable", core_getObjectMetatable},
    {"cleanUTF8forConsole", core_cleanUTF8},
    {"_exit", core_exit},
    {"_logmessage", core_logmessage},
    {"_notify", core_notify},
    {NULL, NULL}
};

// ---------------------------------------------------------------------------
// Lifecycle (ported from MJLuaAlloc/Init/Deinit/Dealloc)
// ---------------------------------------------------------------------------

static MeiLuaSkinDelegate *sSkinDelegate = nil;

static int LuaRuntimeAtPanic(lua_State *L) {
    LuaRuntimeDeliverLog([NSString stringWithFormat:@"LUA_AT_PANIC: %s", lua_tostring(L, -1)]);
    if (oldPanicFunction) return oldPanicFunction(L);
    return 0;
}

static BOOL LuaRuntimeAllocState(void) {
    if (!sSkinDelegate) {
        sSkinDelegate = [[MeiLuaSkinDelegate alloc] init];
    }
    LuaSkin *skin = [LuaSkin sharedWithDelegate:sSkinDelegate];
    // After a reload (destroyLuaState), sharedWithDelegate: does not recreate
    // the state itself — do it manually, mirroring upstream MJLuaAlloc.
    if (!LuaSkin.mainLuaState) {
        [skin createLuaState];
        skin.delegate = sSkinDelegate;
        skin = [LuaSkin sharedWithState:NULL];
    }
    oldPanicFunction = lua_atpanic([skin L], &LuaRuntimeAtPanic);
    return skin.L != NULL;
}

static void LuaRuntimeCallShutdownCallback(void) {
    LuaSkin *skin = [LuaSkin sharedWithState:NULL];
    lua_State *L = skin.L;
    if (!L) return;

    lua_getglobal(L, "hs");
    if (!lua_istable(L, -1)) { lua_pop(L, 1); return; }
    lua_getfield(L, -1, "shutdownCallback");
    if (lua_type(L, -1) == LUA_TNIL) {
        lua_pop(L, 2);
    } else {
        [skin protectedCallAndError:@"hs.shutdownCallback" nargs:0 nresults:0];
        lua_pop(L, 1); // hs global
    }
}

static void LuaRuntimeDestroyState(void) {
    LuaSkin *skin = [LuaSkin sharedWithState:NULL];
    [skin destroyLuaState];
}

// Runs setup.lua, which wires package.path/cpath to the vendored runtime and
// finishes in `hs._coresetup.setup`, loading the user's init.lua.
static BOOL LuaRuntimeInitEnvironment(void) {
    LuaSkin *skin = [LuaSkin sharedWithState:NULL];
    lua_State *L = skin.L;

    refTable = [skin registerLibrary:"core" functions:corelib metaFunctions:nil];
    pushAppInfo(L);
    lua_setfield(L, -2, "processInfo");
    lua_setglobal(L, "hs");

    NSString *setupPath = [NSBundle.mainBundle pathForResource:@"setup" ofType:@"lua"];
    if (!setupPath) {
        LuaRuntimeDeliverLog(@"setup.lua missing from app bundle (vendored runtime incomplete)");
        return NO;
    }

    int loadResult = luaL_loadfile(L, setupPath.fileSystemRepresentation);
    if (loadResult != 0) {
        NSString *msg = [NSString stringWithFormat:@"%s", lua_tostring(L, -1)];
        lua_pop(L, 1);
        LuaRuntimeDeliverLog([NSString stringWithFormat:@"unable to load setup.lua: %@", msg]);
        return NO;
    }

    NSString *modPath = [NSBundle.mainBundle pathForResource:@"extensions" ofType:nil];
    NSString *fullPath = [sConfigDir stringByAppendingPathComponent:sConfigFile];
    lua_pushstring(L, modPath.fileSystemRepresentation);                                   // 1. modpath
    lua_pushstring(L, NSBundle.mainBundle.privateFrameworksPath.fileSystemRepresentation); // 2. frameworkspath
    lua_pushstring(L, sConfigFile.UTF8String);                                            // 3. prettypath
    lua_pushstring(L, fullPath.fileSystemRepresentation);                                 // 4. fullpath
    lua_pushstring(L, sConfigDir.fileSystemRepresentation);                               // 5. configdir
    NSString *docsPath = [NSBundle.mainBundle pathForResource:@"docs" ofType:@"json"];
    lua_pushstring(L, docsPath.fileSystemRepresentation);                                 // 6. docstringspath
    lua_pushboolean(L, [NSFileManager.defaultManager fileExistsAtPath:fullPath]);         // 7. hasinitfile
    lua_pushboolean(L, YES);                                                              // 8. autoload extensions

    if (lua_pcall(L, 8, 2, 0) != LUA_OK) {
        NSString *errorMessage = [NSString stringWithFormat:@"%s", lua_tostring(L, -1)];
        lua_pop(L, 1);
        LuaRuntimeDeliverLog([NSString stringWithFormat:@"error running setup.lua: %@", errorMessage]);
        return NO;
    }

    // setup.lua returns (evalfn, completionsForWordFn). Errors inside the
    // user's init.lua already went through hs.showError → log; treat a
    // malformed return as a runtime failure.
    if (lua_gettop(L) != 2 || lua_type(L, -1) != LUA_TFUNCTION || lua_type(L, -2) != LUA_TFUNCTION) {
        lua_pop(L, lua_gettop(L));
        LuaRuntimeDeliverLog(@"setup.lua did not return its two functions");
        return NO;
    }

    evalfn = [skin luaRef:refTable];
    completionsForWordFn = [skin luaRef:refTable];
    return YES;
}

// ---------------------------------------------------------------------------
// LuaRuntime
// ---------------------------------------------------------------------------

@implementation LuaRuntime {
    BOOL _running;
}

+ (instancetype)shared {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sShared = [[self alloc] init];
    });
    return sShared;
}

- (void)setLogHandler:(void (^)(NSString *))logHandler {
    sLogHandler = [logHandler copy];
}

- (void)setOpenConsoleHandler:(void (^)(void))openConsoleHandler {
    sOpenConsoleHandler = [openConsoleHandler copy];
}

- (void)setNotifyHandler:(void (^)(NSString *))notifyHandler {
    sNotifyHandler = [notifyHandler copy];
}

- (NSString *)configDir {
    return sConfigDir;
}

- (BOOL)isRunning {
    return _running;
}

- (BOOL)startWithConfigDir:(NSString *)configDir {
    NSAssert(NSThread.isMainThread, @"LuaRuntime is main-thread only");
    if (_running) return YES;

    sConfigDir = [configDir copy];

    // Load the host-symbol library BEFORE any hs.* dylib is dlopened:
    // HSapplication/HSuielement/HSwindow (vendored HSuicore) and the MJ*
    // stubs live in MeiHSRuntime.dylib. Executables don't export symbols,
    // so these classes can't live in the app binary — once this dylib is
    // in the process image set, later flat-namespace binds resolve to it.
    NSString *runtimeDylib = [NSBundle.mainBundle.privateFrameworksPath
                              stringByAppendingPathComponent:@"MeiHSRuntime.dylib"];
    if (!dlopen(runtimeDylib.fileSystemRepresentation, RTLD_NOW)) {
        LuaRuntimeDeliverLog([NSString stringWithFormat:@"failed to load MeiHSRuntime.dylib: %s", dlerror()]);
        sConfigDir = nil;
        return NO;
    }

    if (!LuaRuntimeAllocState()) {
        LuaRuntimeDeliverLog(@"failed to create Lua state");
        sConfigDir = nil;
        return NO;
    }
    if (!LuaRuntimeInitEnvironment()) {
        LuaRuntimeDestroyState();
        sConfigDir = nil;
        return NO;
    }

    _running = YES;
    sRunning = YES;
    return YES;
}

- (void)stop {
    NSAssert(NSThread.isMainThread, @"LuaRuntime is main-thread only");
    if (!_running) return;

    LuaRuntimeCallShutdownCallback();
    LuaRuntimeDestroyState();
    evalfn = LUA_NOREF;
    completionsForWordFn = LUA_NOREF;
    _running = NO;
    sRunning = NO;
}

- (void)reload {
    NSAssert(NSThread.isMainThread, @"LuaRuntime is main-thread only");
    if (!sConfigDir) return;
    NSString *dir = [sConfigDir copy];
    [self stop];
    [self startWithConfigDir:dir];
}

- (NSString *)runString:(NSString *)command {
    NSAssert(NSThread.isMainThread, @"LuaRuntime is main-thread only");
    if (!_running) return nil;

    LuaSkin *skin = [LuaSkin sharedWithState:NULL];
    lua_State *L = skin.L;

    [skin pushLuaRef:refTable ref:evalfn];
    if (!lua_isfunction(L, -1)) {
        lua_pop(L, 1);
        return @"";
    }
    lua_pushstring(L, command.UTF8String);
    if (![skin protectedCallAndTraceback:1 nresults:1]) {
        const char *errorMsg = lua_tostring(L, -1);
        [skin logError:[NSString stringWithUTF8String:errorMsg ?: "unknown error"]];
    }

    size_t len;
    const unsigned char *s = (const unsigned char *)lua_tolstring(L, -1, &len);
    NSString *str = [[NSString alloc] initWithData:[NSData dataWithBytes:s length:len] encoding:NSUTF8StringEncoding];
    if (str == nil) {
        str = [skin getValidUTF8:s ofLength:len];
    }
    lua_pop(L, 1);
    return str;
}

- (void)notifyTextDropped:(NSString *)text {
    NSAssert(NSThread.isMainThread, @"LuaRuntime is main-thread only");
    if (!_running) return;

    LuaSkin *skin = [LuaSkin sharedWithState:NULL];
    lua_State *L = skin.L;

    lua_getglobal(L, "hs");
    lua_getfield(L, -1, "textDroppedToDockIconCallback");
    if (lua_type(L, -1) == LUA_TNIL) {
        lua_pop(L, 2);
    } else {
        [skin pushNSObject:text];
        [skin protectedCallAndError:@"hs.textDroppedToDockIconCallback" nargs:1 nresults:0];
        lua_pop(L, 1); // hs global
    }
}

- (void)notifyAccessibilityStateChanged {
    NSAssert(NSThread.isMainThread, @"LuaRuntime is main-thread only");
    if (!_running) return;

    LuaSkin *skin = [LuaSkin sharedWithState:NULL];
    lua_State *L = skin.L;

    lua_getglobal(L, "hs");
    lua_getfield(L, -1, "accessibilityStateCallback");
    if (lua_type(L, -1) == LUA_TNIL) {
        lua_pop(L, 2);
    } else {
        [skin protectedCallAndError:@"hs.accessibilityStateCallback" nargs:0 nresults:0];
        lua_pop(L, 1); // hs global
    }
}

@end
