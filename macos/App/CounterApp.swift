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
    func openHistory(_ a: AccountDTO) { activeSheet = .history(a) }

    /// One account's logged usage for a range, plus the engine's summary of it.
    func history(accountId: String, range: HistoryRange) async throws -> ([HistoryRecordDTO], HistorySummaryDTO?, Double?) {
        func url(_ path: String, _ items: [URLQueryItem]) -> URL {
            var c = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
            c.queryItems = items
            return c.url!
        }
        var q = [URLQueryItem(name: "account", value: accountId), URLQueryItem(name: "since", value: range.rawValue), URLQueryItem(name: "limit", value: "0")]
        if let step = range.step { q.append(URLQueryItem(name: "step", value: step)) }
        async let hist = URLSession.shared.data(from: url("api/history", q))
        async let summ = URLSession.shared.data(from: url("api/history/summary", [URLQueryItem(name: "account", value: accountId), URLQueryItem(name: "since", value: range.rawValue)]))
        let (hData, hResp) = try await hist
        guard (hResp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        // `account` also matches label substrings; keep only this account's rows.
        let records = try JSONDecoder().decode(HistoryResp.self, from: hData).records.filter { $0.account == accountId }
        let summary = (try? await summ).flatMap { try? JSONDecoder().decode(HistorySummaryResp.self, from: $0.0) }
        return (records, summary?.accounts.first { $0.account == accountId }, summary?.intervalMs)
    }

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
    case history(AccountDTO)
    var id: String {
        switch self {
        case .add: return "add"
        case .relogin(let id, _): return "relogin-\(id)"
        case .remove(let a): return "remove-\(a.id)"
        case .history(let a): return "history-\(a.id)"
        }
    }
}

struct LoginStartResp: Decodable { let loginId: String; let authorizeUrl: String }
struct LoginFinishResp: Decodable { let ok: Bool?; let error: String?; let message: String?; let label: String? }
