import SwiftUI
import AppKit

@main
struct CraigsClaudeCounterApp: App {
    @StateObject private var model = CounterModel()

    var body: some Scene {
        WindowGroup {
            DashboardView(model: model)
                .onAppear { model.start() }
                .background(Theme.bg)
        }
        .defaultSize(width: 1100, height: 560)
        .windowResizability(.contentMinSize)
    }
}

@MainActor
final class CounterModel: ObservableObject {
    @Published var snapshot: UsageSnapshot?
    @Published var lastError: String?
    @Published var loadedAt: Date?
    @Published var tick = Date()

    /// The local engine (the Node server). Override with CCC_BASE_URL.
    let baseURL: URL = {
        if let s = ProcessInfo.processInfo.environment["CCC_BASE_URL"], let u = URL(string: s) { return u }
        return URL(string: "http://127.0.0.1:4319")!
    }()

    private var pollTimer: Timer?
    private var tickTimer: Timer?

    func start() {
        guard pollTimer == nil else { return }
        Task { await load() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { await self?.load() }
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick = Date() }
        }
    }

    func load() async {
        do {
            var req = URLRequest(url: baseURL.appendingPathComponent("api/usage"))
            req.timeoutInterval = 8
            req.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: data)
            loadedAt = Date()
            lastError = nil
        } catch {
            lastError = "engine offline"
        }
    }

    // v1: account management runs through the web dashboard's proven login flow.
    func openAddAccount() { NSWorkspace.shared.open(baseURL) }
    func openReLogin(_ a: AccountDTO) { NSWorkspace.shared.open(baseURL) }

    func openRemove(_ a: AccountDTO) {
        Task {
            var req = URLRequest(url: baseURL.appendingPathComponent("api/accounts/\(a.id)"))
            req.httpMethod = "DELETE"
            _ = try? await URLSession.shared.data(for: req)
            await load()
        }
    }
}
