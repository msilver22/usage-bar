import AppKit
import Combine
import Foundation
import UsageCore

@MainActor
final class UpdateStore: ObservableObject {
    @Published private(set) var availableUpdate: UpdateInfo?
    @Published private(set) var isChecking = false
    @Published private(set) var isUpdating = false
    @Published private(set) var error: String?
    @Published private(set) var lastCheckedAt: Date?
    @Published var autoUpdate: Bool {
        didSet { UserDefaults.standard.set(autoUpdate, forKey: Self.autoUpdateKey) }
    }

    let repoPath: String?
    let builtCommit: String?
    var isConfigured: Bool { repoPath != nil && builtCommit != nil }
    var isPanelOpen: () -> Bool = { false }

    private static let autoUpdateKey = "autoUpdateFromMain"
    private static let checkInterval: TimeInterval = 3600
    private static let panelStaleInterval: TimeInterval = 900
    private var timer: Timer?
    private var checkTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?

    init(info: [String: Any]? = Bundle.main.infoDictionary) {
        self.repoPath = info?["UsageBarRepoPath"] as? String
        self.builtCommit = info?["UsageBarGitCommit"] as? String
        self.autoUpdate = UserDefaults.standard.bool(forKey: Self.autoUpdateKey)
    }

    func startMonitoring() {
        guard isConfigured, timer == nil else { return }
        // Delay the initial check briefly so launch stays instant.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.check(userInitiated: false)
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.check(userInitiated: false) }
        }
    }

    func checkIfStale() {
        guard isConfigured, !isChecking, !isUpdating else { return }
        if let lastCheckedAt, Date().timeIntervalSince(lastCheckedAt) < Self.panelStaleInterval { return }
        check(userInitiated: false)
    }

    func checkNow() { check(userInitiated: true) }

    private func check(userInitiated: Bool) {
        guard let repoPath, let builtCommit, !isChecking, !isUpdating else { return }
        isChecking = true
        if userInitiated { error = nil }
        checkTask?.cancel()
        checkTask = Task {
            do {
                let status = try await Task.detached {
                    try AppUpdater.check(repoPath: repoPath, builtCommit: builtCommit)
                }.value
                guard !Task.isCancelled else { return }
                isChecking = false
                lastCheckedAt = Date()
                error = nil
                switch status {
                case .upToDate:
                    availableUpdate = nil
                case .available(let info):
                    availableUpdate = info
                    if autoUpdate && !userInitiated && !isPanelOpen() {
                        applyUpdate()
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                isChecking = false
                if userInitiated { self.error = error.localizedDescription }
            }
        }
    }

    func applyUpdate() {
        guard let repoPath, !isUpdating else { return }
        isUpdating = true
        error = nil
        let targetApp = Bundle.main.bundlePath
        updateTask = Task {
            do {
                let builtApp = try await Task.detached {
                    try AppUpdater.prepareUpdate(repoPath: repoPath)
                }.value
                try AppUpdater.relaunch(builtAppPath: builtApp, targetAppPath: targetApp)
                NSApp.terminate(nil)
            } catch {
                isUpdating = false
                self.error = error.localizedDescription
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        checkTask?.cancel()
        updateTask?.cancel()
    }
}
