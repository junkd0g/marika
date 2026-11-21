import AppKit
import MarikaCore
import Observation
#if !MARIKA_APP_STORE
import Sparkle
#endif

@MainActor
@Observable
final class AppUpdates: NSObject {
    enum Status: String { case idle, checking, current, available, noReleases, failed }
    let installedVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? marikaCoreVersion
    let installedBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Development"
    private(set) var status = Status.idle
    private(set) var release: PublishedRelease?
    private(set) var lastChecked: Date?
    private(set) var errorMessage: String?
    @ObservationIgnored private let checker = ReleaseChecker()
    #if !MARIKA_APP_STORE
    @ObservationIgnored private var sparkle: SPUStandardUpdaterController?
    #endif
    @ObservationIgnored var allowRelaunch: () -> Bool = { false }
    #if DEBUG
        @ObservationIgnored var releaseOverride: (@Sendable () async throws -> PublishedRelease?)?
    #endif

    var supportsInstallation: Bool {
        #if MARIKA_APP_STORE
        false
        #else
        Bundle.main.bundleURL.pathExtension == "app" && SignedUpdateConfiguration(
            feedURL: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            publicKey: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String) != nil
        #endif
    }

    func check() async {
        #if MARIKA_APP_STORE
        NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!)
        #else
        guard status != .checking else { return }
        status = .checking; errorMessage = nil
        do {
            let latest: PublishedRelease?
            #if DEBUG
                if let releaseOverride { latest = try await releaseOverride() }
                else { latest = try await checker.latest() }
            #else
                latest = try await checker.latest()
            #endif
            try Task.checkCancellation()
            release = latest; lastChecked = Date()
            guard let latest else { status = .noReleases; return }
            guard let installed = ReleaseVersion(installedVersion) else {
                status = .failed; errorMessage = "This build has an unrecognized version. You can view releases on GitHub."; return
            }
            status = latest.version > installed ? .available : .current
        } catch is CancellationError {
            status = .idle
        } catch {
            status = .failed; errorMessage = error.localizedDescription
        }
        #endif
    }

    func install() {
        #if !MARIKA_APP_STORE
        guard status == .available, supportsInstallation else { return }
        guard allowRelaunch() else {
            errorMessage = "Finish active agents and save editor changes before installing an update."
            return
        }
        if sparkle == nil {
            let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
            sparkle = controller
            controller.startUpdater()
        }
        guard let sparkle, sparkle.updater.canCheckForUpdates else { return }
        // Sparkle downloads from the configured appcast and verifies the EdDSA signature.
        sparkle.checkForUpdates(nil)
        #endif
    }
}

#if !MARIKA_APP_STORE
extension AppUpdates: SPUUpdaterDelegate {

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        // Recheck immediately before relaunch: an agent may have started since the dialog opened.
        let allowed = allowRelaunch()
        if !allowed { errorMessage = "Finish active agents and save editor changes, then try installing again." }
        return allowed
    }
}

#endif

extension AppModel {
    func configureUpdater() {
        updates.allowRelaunch = { [weak self] in self?.canInstallAppUpdate == true }
    }

    var canInstallAppUpdate: Bool {
        isReady && !workspaceLoadFailed && !controllers.values.contains(where: \.isBusy)
            && !allEditors.contains(where: { $0.documents.contains(where: { $0.isModified || $0.isSaving }) }) && storageError == nil
    }
}
