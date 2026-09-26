/// How far above the menu bar level the notch panel sits: one, so the notch stays over full screen
/// apps. A test copy may go `MAIN_THING_PANEL_LEVEL_OFFSET` (1 to 20) levels higher, so a demo
/// recording can put a backdrop between the installed app's notch and its own. The release app
/// ignores the variable.
public enum PanelLevel {
    public static let aboveMenuBar = 1
    public static let maximumExtra = 20

    public static func offset(environment: [String: String], bundleID: String?) -> Int {
        guard !AppPaths.isRelease(bundleID: bundleID),
              let extra = Env.value("PANEL_LEVEL_OFFSET", in: environment).flatMap(Int.init),
              (1...maximumExtra).contains(extra)
        else { return aboveMenuBar }
        return aboveMenuBar + extra
    }
}
