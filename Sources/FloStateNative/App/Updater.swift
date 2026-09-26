import AppKit
import Sparkle

/// In-app updates (Sparkle 2). The feed and EdDSA public key come from the
/// Info.plist written by scripts/bundle.sh (SUFeedURL, SUPublicEDKey,
/// SUEnableAutomaticChecks, SUScheduledCheckInterval).
///
/// Debug/testing feed override (e.g. a locally served appcast):
///   FLOSTATE_FEED_URL=http://localhost:8000/appcast.xml
///   defaults write app.flostate.native FloStateFeedURL http://localhost:8000/appcast.xml
@MainActor
final class AppUpdater: NSObject {
    nonisolated static let feedOverrideEnv = "FLOSTATE_FEED_URL"
    nonisolated static let feedOverrideDefault = "FloStateFeedURL"

    static var shared: AppUpdater?

    private let delegate = UpdaterDelegate()
    private(set) var controller: SPUStandardUpdaterController!

    /// Only a real, fully configured bundle updates itself (not tests or a bare binary).
    nonisolated static func isConfigured(_ bundle: Bundle = .main) -> Bool {
        bundle.bundleURL.pathExtension == "app"
            && bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil
            && bundle.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
    }

    nonisolated static func feedOverride(env: [String: String] = ProcessInfo.processInfo.environment,
                             defaults: UserDefaults = .standard) -> String? {
        if let s = env[feedOverrideEnv], !s.isEmpty { return s }
        if let s = defaults.string(forKey: feedOverrideDefault), !s.isEmpty { return s }
        return nil
    }

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
    }

    /// App menu "Check for Updates…", validated by the controller (disabled while a check runs).
    func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: MainMenu.checkForUpdatesTitle,
                              action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        item.target = controller
        return item
    }
}

final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    var relaunch = true

    func feedURLString(for updater: SPUUpdater) -> String? {
        AppUpdater.feedOverride()
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { relaunch }

    /// `--sparkle-probe` tracing.
    var trace: ((String) -> Void)?
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { trace?("will install \(item.versionString)") }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { trace?("aborted: \(error)") }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        trace?("cycle finished \(error.map { "\($0)" } ?? "ok")")
    }
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) { trace?("will relaunch/terminate") }
}

/// `--sparkle-probe`: headless end-to-end update check for scripts/test-update.sh.
/// No windows, no Dock icon: checks the feed (use FLOSTATE_FEED_URL), downloads,
/// verifies the EdDSA signature, then installs on termination without relaunching.
/// Prints one `probe: …` line per step; exits 0 once the installer has been handed
/// the update, 1 on any error / no update.
@MainActor
final class UpdateProbe: NSObject, SPUUserDriver {
    private let delegate = UpdaterDelegate()
    private var updater: SPUUpdater!
    private let install: Bool

    init(install: Bool) {
        self.install = install
        super.init()
        delegate.relaunch = false
        delegate.trace = { Self.log($0) }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            Self.log("terminating")
        }
    }

    static func run(_ args: [String]) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let probe = UpdateProbe(install: !args.contains("--no-install"))
        probe.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { log("timeout"); exit(1) }
        app.run()
        exit(0)
    }

    private static func log(_ s: String) {
        FileHandle.standardOutput.write("probe: \(s)\n".data(using: .utf8)!)
    }
    private func log(_ s: String) { Self.log(s) }

    private func start() {
        log("version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "?"))")
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: delegate)
        do { try updater.start() } catch { log("start failed: \(error)"); exit(1) }
        log("feed \(updater.feedURL?.absoluteString ?? "nil")")
        updater.checkForUpdates()
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { log("checking") }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        log("found \(appcastItem.displayVersionString) (\(appcastItem.versionString)) \(appcastItem.fileURL?.absoluteString ?? "")")
        if install { reply(.install) } else { exit(0) }
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        log("no update: \(error.localizedDescription)"); exit(1)
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        log("error: \(error.localizedDescription) \((error as NSError).userInfo)"); exit(1)
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { log("downloading") }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() { log("extracting (signature verified)") }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // Install-on-quit (no relaunch): dismiss, then quit; Autoupdate installs once we're gone.
        log("ready to install; quitting so it installs")
        reply(.dismiss)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        log("installing (terminated=\(applicationTerminated))")
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        log("installed (relaunched=\(relaunched))"); acknowledgement()
    }
    func dismissUpdateInstallation() {}
}
