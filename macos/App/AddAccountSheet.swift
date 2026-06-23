import SwiftUI
import AppKit

struct AddAccountSheet: View {
    @ObservedObject var model: CounterModel
    var replaceId: String? = nil
    var replaceLabel: String? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var step = 1
    @State private var loginId: String? = nil
    @State private var authorizeURL: String? = nil
    @State private var code = ""
    @State private var msg: (text: String, error: Bool)? = nil
    @State private var busy = false

    private var isRelogin: Bool { replaceId != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(isRelogin ? "Re-login" : "Add account")
                    .font(Theme.ui(15, .semibold)).foregroundColor(Theme.ink)
                Spacer()
                Button { dismiss() } label: { Text("✕").font(Theme.ui(14)).foregroundColor(Theme.ink3) }
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            Rectangle().fill(Theme.hair).frame(height: 1)

            VStack(alignment: .leading, spacing: 14) {
                if step == 1 { stepOne } else { stepTwo }
                if let m = msg {
                    Text(m.text).font(Theme.mono(12, .regular))
                        .foregroundColor(m.error ? Theme.alarm : Theme.ok)
                }
            }
            .padding(20)
        }
        .frame(width: 470)
        .background(Theme.panel)
        .onAppear { if isRelogin { label = replaceLabel ?? "" } }
    }

    private var stepOne: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isRelogin
                 ? "Sign in again to **\(replaceLabel ?? "this account")** to restore live data. The old token expired or was revoked."
                 : "Sign into a Claude account once. It stays logged in afterward.")
                .font(Theme.ui(13)).foregroundColor(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            fieldLabel("Label — optional, defaults to the account email")
            TextField("e.g. work / personal / client", text: $label)
                .textFieldStyle(.plain).padding(9)
                .background(Theme.bg).cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hair, lineWidth: 1))
                .font(Theme.mono(13, .regular)).foregroundColor(Theme.ink)
            HStack {
                Button { Task { await beginLogin() } } label: {
                    Text(busy ? "Starting…" : "Open Claude login")
                }
                .buttonStyle(PrimaryButton()).disabled(busy)
            }
        }
    }

    private var stepTwo: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("A login tab opened in your browser. Sign in, approve, then copy the code Claude shows you and paste it below.")
                .font(Theme.ui(13)).foregroundColor(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            if let u = authorizeURL {
                Button { NSWorkspace.shared.open(URL(string: u)!) } label: {
                    Text("Re-open the login page").font(Theme.mono(12, .regular)).foregroundColor(Theme.accent)
                }.buttonStyle(.plain)
            }
            fieldLabel("Paste the code")
            TextEditor(text: $code)
                .font(Theme.mono(12, .regular)).foregroundColor(Theme.ink)
                .scrollContentBackground(.hidden)
                .frame(height: 64).padding(6)
                .background(Theme.bg).cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hair, lineWidth: 1))
            HStack(spacing: 12) {
                Button { Task { await finish() } } label: { Text(busy ? "Exchanging…" : "Finish") }
                    .buttonStyle(PrimaryButton()).disabled(busy)
                Button { step = 1; msg = nil } label: { Text("start over").font(Theme.ui(12)).foregroundColor(Theme.ink3) }
                    .buttonStyle(.plain)
            }
        }
    }

    private func fieldLabel(_ s: String) -> some View {
        Text(s).font(Theme.mono(10.5, .regular)).foregroundColor(Theme.ink3).tracking(0.4)
    }

    private func beginLogin() async {
        busy = true; msg = ("Starting…", false)
        defer { busy = false }
        guard let start = await model.startLogin(label: label, replaceId: replaceId) else {
            msg = ("Could not reach the local engine.", true); return
        }
        loginId = start.loginId
        authorizeURL = start.authorizeUrl
        NSWorkspace.shared.open(URL(string: start.authorizeUrl)!)
        msg = nil
        step = 2
    }

    private func finish() async {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { msg = ("Paste the code first.", true); return }
        guard let loginId = loginId else { msg = ("Start the login first.", true); step = 1; return }
        busy = true; msg = ("Exchanging…", false)
        defer { busy = false }
        let out = await model.finishLogin(loginId: loginId, code: trimmed)
        if let err = out.error {
            msg = ("Failed: \(out.message ?? err)", true)
        } else {
            msg = ("Added \(out.label ?? "account")", false)
            await model.load()
            try? await Task.sleep(nanoseconds: 600_000_000)
            dismiss()
        }
    }
}

struct RemoveSheet: View {
    @ObservedObject var model: CounterModel
    let account: AccountDTO
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Remove account").font(Theme.ui(15, .semibold)).foregroundColor(Theme.ink)
            Text("Remove **\(account.name)** from the dashboard? This only forgets the token here — it does not affect the Claude subscription.")
                .font(Theme.ui(13)).foregroundColor(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button { dismiss() } label: { Text("Cancel") }.buttonStyle(SoftButton())
                Button { busy = true; Task { await model.deleteAccount(account.id); dismiss() } } label: {
                    Text(busy ? "Removing…" : "Remove")
                }.buttonStyle(PillButton(color: Theme.alarm)).disabled(busy)
            }
        }
        .padding(20).frame(width: 430).background(Theme.panel)
    }
}

struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.ui(13, .semibold)).foregroundColor(Color(hex: 0x0c0f13))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Theme.accent)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
