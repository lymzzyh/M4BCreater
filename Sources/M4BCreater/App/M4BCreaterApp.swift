import AppKit
import SwiftUI

@main
struct M4BCreaterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var coordinator = ConversionCoordinator()

    var body: some Scene {
        // Build the view values on the main actor before passing them to SwiftUI's scene builders.
        let mainContent = ContentView()
            .environmentObject(coordinator)
            .frame(minWidth: 1180, minHeight: 760)
        let settingsContent = SettingsView()
            .environmentObject(coordinator)
            .frame(width: 620, height: 420)

        Self.scenes(mainContent: mainContent, settingsContent: settingsContent)
    }

    @SceneBuilder
    private nonisolated static func scenes<MainContent: View, SettingsContent: View>(
        mainContent: MainContent,
        settingsContent: SettingsContent
    ) -> some Scene {
        WindowGroup {
            mainContent
        }
        .windowStyle(.titleBar)

        Settings {
            settingsContent
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let singleInstance = SingleInstanceController()

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard singleInstance.acquireOrNotifyExistingInstance() else {
            NSApp.terminate(nil)
            return
        }
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(activateExistingWindow),
            name: SingleInstanceController.activateNotificationName,
            object: nil
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            self.activateExistingWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        singleInstance.releaseLock()
    }

    @objc private func activateExistingWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
    }
}

private final class SingleInstanceController {
    static let activateNotificationName = Notification.Name("com.m4bcreater.activateExistingWindow")

    private var lockFileDescriptor: Int32 = -1

    func acquireOrNotifyExistingInstance() -> Bool {
        let lockURL = Self.lockFileURL()
        try? FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let descriptor = open(lockURL.path(percentEncoded: false), O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            return true
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            notifyExistingInstance()
            return false
        }

        lockFileDescriptor = descriptor
        writeCurrentPID(to: descriptor)
        return true
    }

    func releaseLock() {
        guard lockFileDescriptor >= 0 else { return }
        flock(lockFileDescriptor, LOCK_UN)
        close(lockFileDescriptor)
        lockFileDescriptor = -1
    }

    private func notifyExistingInstance() {
        DistributedNotificationCenter.default().postNotificationName(
            Self.activateNotificationName,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    private func writeCurrentPID(to descriptor: Int32) {
        let pid = "\(getpid())\n"
        _ = ftruncate(descriptor, 0)
        _ = lseek(descriptor, 0, SEEK_SET)
        pid.withCString { pointer in
            _ = write(descriptor, pointer, strlen(pointer))
        }
    }

    private static func lockFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appending(path: "M4BCreater", directoryHint: .isDirectory)
            .appending(path: "M4BCreater.lock")
    }
}
