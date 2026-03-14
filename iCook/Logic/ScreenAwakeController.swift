import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import IOKit.pwr_mgt
#endif

private let keepScreenOnUserDefaultsKey = "KeepScreenOn"

final class ScreenAwakeController {
    static let shared = ScreenAwakeController()

    private var activeRequestIDs: Set<UUID> = []

#if os(macOS)
    private var noDisplaySleepAssertionID: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
    private var noIdleSleepAssertionID: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
#endif

    private init() {}

    func setRequestActive(id: UUID, isActive: Bool) {
        DispatchQueue.main.async {
            let didChange: Bool
            if isActive {
                didChange = self.activeRequestIDs.insert(id).inserted
            } else {
                didChange = self.activeRequestIDs.remove(id) != nil
            }

            if didChange {
                self.applyCurrentState()
            }
        }
    }

    private func applyCurrentState() {
        let shouldKeepAwake = !activeRequestIDs.isEmpty

#if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = shouldKeepAwake
#elseif os(macOS)
        if shouldKeepAwake {
            acquireAssertion(
                type: kIOPMAssertionTypeNoDisplaySleep,
                name: "iCook Keep Screen On",
                id: &noDisplaySleepAssertionID
            )
            acquireAssertion(
                type: kIOPMAssertionTypeNoIdleSleep,
                name: "iCook Keep Awake",
                id: &noIdleSleepAssertionID
            )
        } else {
            releaseAssertion(&noDisplaySleepAssertionID)
            releaseAssertion(&noIdleSleepAssertionID)
        }
#endif
    }

#if os(macOS)
    private func acquireAssertion(type: String, name: String, id: inout IOPMAssertionID) {
        guard id == IOPMAssertionID(kIOPMNullAssertionID) else { return }

        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name as CFString,
            &id
        )

        if result != kIOReturnSuccess {
            printD("Failed to acquire power assertion '\(name)': \(result)")
            id = IOPMAssertionID(kIOPMNullAssertionID)
        }
    }

    private func releaseAssertion(_ id: inout IOPMAssertionID) {
        guard id != IOPMAssertionID(kIOPMNullAssertionID) else { return }
        IOPMAssertionRelease(id)
        id = IOPMAssertionID(kIOPMNullAssertionID)
    }
#endif
}

private struct KeepScreenAwakeModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(keepScreenOnUserDefaultsKey) private var keepScreenOn = false
    @State private var requestID = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear {
                updateWakeState()
            }
            .onChange(of: keepScreenOn) { _, _ in
                updateWakeState()
            }
            .onChange(of: scenePhase) { _, _ in
                updateWakeState()
            }
            .onDisappear {
                ScreenAwakeController.shared.setRequestActive(id: requestID, isActive: false)
            }
    }

    private func updateWakeState() {
        ScreenAwakeController.shared.setRequestActive(
            id: requestID,
            isActive: keepScreenOn && scenePhase == .active
        )
    }
}

extension View {
    func keepScreenAwakeSettingApplied() -> some View {
        modifier(KeepScreenAwakeModifier())
    }
}
