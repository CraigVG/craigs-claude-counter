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
    @Published var activeSheet: ActiveSheet? = nil

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

    // Native account management — presents a sheet; the only browser step is the
    // actual claude.ai sign-in (unavoidable: Cloudflare + the real login).
    func openAddAccount() { activeSheet = .add }
    func openReLogin(_ a: AccountDTO) { activeSheet = .relogin(id: a.id, label: a.name) }
    func openRemove(_ a: AccountDTO) { activeSheet = .remove(a) }

    func startLogin(label: String, replaceId: String?) async -> LoginStartResp? {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/login/start"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["label": label, "replaceId": replaceId ?? NSNull()] as [String: Any])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let out = try? JSONDecoder().decode(LoginStartResp.self, from: data) else { return nil }
        return out
    }

    func finishLogin(loginId: String, code: String) async -> LoginFinishResp {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/login/finish"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["loginId": loginId, "pastedCode": code])
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let out = try? JSONDecoder().decode(LoginFinishResp.self, from: data) else {
            return LoginFinishResp(ok: false, error: "network", message: "could not reach the local engine", label: nil)
        }
        return out
    }

    func deleteAccount(_ id: String) async {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/accounts/\(id)"))
        req.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: req)
        await load()
    }
}

enum ActiveSheet: Identifiable {
    case add
    case relogin(id: String, label: String)
    case remove(AccountDTO)
    var id: String {
        switch self {
        case .add: return "add"
        case .relogin(let id, _): return "relogin-\(id)"
        case .remove(let a): return "remove-\(a.id)"
        }
    }
}

struct LoginStartResp: Decodable { let loginId: String; let authorizeUrl: String }
struct LoginFinishResp: Decodable { let ok: Bool?; let error: String?; let message: String?; let label: String? }
