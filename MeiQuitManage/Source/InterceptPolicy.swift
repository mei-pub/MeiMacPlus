/// Pure decision logic: given the current configuration and the frontmost
/// app, decide whether a ⌘Q press should be intercepted (held) or passed
/// through to the target app untouched.
enum InterceptPolicy {

    /// - Returns: `true` → intercept and require the user to hold ⌘Q;
    ///   `false` → let the original keypress reach the app (instant quit).
    static func shouldIntercept(
        enabled: Bool,
        invertList: Bool,
        whitelist: [String],
        frontmostBundleID: String?
    ) -> Bool {
        guard enabled else { return false }
        // If we cannot determine the frontmost app, do not interfere.
        guard let bundleID = frontmostBundleID, !bundleID.isEmpty else { return false }
        let isListed = whitelist.contains(bundleID)
        // Normal mode: listed apps quit instantly, everything else is protected.
        // Inverted mode: only listed apps are protected.
        return invertList ? isListed : !isListed
    }
}
