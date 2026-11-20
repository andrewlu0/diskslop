import Sparkle

final class AppUpdateDriver: SPUStandardUserDriver, SPUUpdaterDelegate {
    private enum Offer {
        case available(SUAppcastItem, SPUUserUpdateState, (SPUUserUpdateChoice) -> Void)
        case prepared(() -> Void)
    }
    var availabilityChanged: ((Bool) -> Void)?
    private var offer: Offer? {
        didSet { availabilityChanged?(hasOffer) }
    }
    var hasOffer: Bool { offer != nil }
    var menuTitle: String {
        if case .prepared = offer { return "Install Update and Restart…" }
        return "Check for Updates…"
    }
    private var relaunchWhenReady = false

    func installAvailableUpdate() {
        guard let pending = offer else { return }
        offer = nil
        relaunchWhenReady = true
        switch pending {
        case let .available(_, _, reply): reply(.install)
        case let .prepared(installNow): installNow()
        }
    }

    func checkFromMenu(using updater: SPUUpdater) {
        switch offer {
        case let .available(item, state, reply):
            offer = nil
            super.showUpdateFound(with: item, state: state, reply: reply)
            super.showUpdateInFocus()
        case .prepared: installAvailableUpdate()
        case nil: updater.checkForUpdates()
        }
    }

    override func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState,
                                  reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if state.userInitiated || item.isInformationOnlyUpdate {
            super.showUpdateFound(with: item, state: state, reply: reply)
        } else {
            offer = .available(item, state, reply)
        }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock installNow: @escaping () -> Void) -> Bool {
        offer = .prepared(installNow)
        return true
    }

    override func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if relaunchWhenReady { reply(.install) }
        else { super.showReady(toInstallAndRelaunch: reply) }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        offer = nil
        relaunchWhenReady = false
    }
}
