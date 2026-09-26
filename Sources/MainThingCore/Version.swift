/// The app version: the one source. scripts/build-app.sh writes it into the bundle as
/// `CFBundleShortVersionString`, and scripts/release.sh bumps it.
public let MainThingVersion = "0.4.1"

/// The build number: an integer that goes up by one with every release. build-app.sh writes it as
/// `CFBundleVersion`, which Sparkle compares to decide that an update is newer.
public let MainThingBuild = 5

/// Bundle identifier of the release app. Also the `os.Logger` subsystem and the `UserDefaults`
/// domain. Any other bundle id is a test copy, with its own list and config (`AppPaths`).
public let MainThingBundleID = "com.jonnilundy.mainthing"
