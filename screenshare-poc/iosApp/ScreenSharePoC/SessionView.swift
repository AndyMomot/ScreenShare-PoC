import Shared
import SwiftUI

struct SessionView: View {
    @EnvironmentObject private var session: SessionViewModel
    @State private var hostDraft = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    StatusCard()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                Section {
                    Picker("Stream quality", selection: $session.profile) {
                        ForEach(StreamProfile.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(session.streaming != nil)
                    LabeledContent("Server") {
                        TextField(session.discovered.map { "Auto · \($0.host)" } ?? "Auto", text: $hostDraft)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .onSubmit {
                                guard hostDraft != session.manualHost else { return }
                                session.manualHost = hostDraft
                                session.reconnect()
                            }
                    }
                } header: {
                    Text("Settings")
                } footer: {
                    Text("Quality applies to the next session. Leave Server empty to find the Mac running run.sh automatically.")
                }

                Section {
                    DisclosureGroup("Log (\(session.log.count))") {
                        ForEach(Array(session.log.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption.monospaced())
                        }
                    }
                }
            }
            .navigationTitle("ELD Support")
            .onAppear { hostDraft = session.manualHost }
        }
    }
}

/// One glance answer to "can support reach me, and are they watching".
private struct StatusCard: View {
    @EnvironmentObject private var session: SessionViewModel

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(tint.opacity(0.15)).frame(width: 56, height: 56)
                if showsProgress {
                    ProgressView()
                } else {
                    Image(systemName: icon).font(.title2.weight(.semibold)).foregroundStyle(tint)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(tint.opacity(0.35), lineWidth: 1))
        .animation(.default, value: title)
    }

    private var showsProgress: Bool {
        guard session.streaming == nil, session.requested == nil else { return false }
        switch session.link {
        case .searching, .connecting, .reconnecting: return true
        case .online, .offline: return false
        }
    }

    private var title: String {
        if let streaming = session.streaming {
            return streaming.paused ? "Session paused" : (streaming.controlEnabled ? "Support is controlling" : "Support is viewing")
        }
        if session.requested != nil { return "Support is asking to connect" }
        if let ended = session.state as? SessionStateEnded { return ended.reason }
        switch session.link {
        case .online: return "Support can reach you"
        case .searching: return "Looking for the support server…"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .offline: return "Support can't reach you"
        }
    }

    private var subtitle: String {
        if let streaming = session.streaming {
            return streaming.mode == CaptureMode.device ? "Whole screen is shared" : "Only this app is shared"
        }
        if session.requested != nil { return "Answer the request to start" }
        switch session.link {
        case .online: return "Waiting for a support request"
        case .searching: return "Start run.sh on a Mac in this network"
        case .connecting: return "Joining \(session.host ?? "server")"
        case .reconnecting: return "Connection dropped, restoring"
        case let .offline(retryIn, _): return "Server unreachable · retry in \(retryIn) s"
        }
    }

    private var icon: String {
        if session.streaming != nil { return "eye.fill" }
        if session.requested != nil { return "person.wave.2.fill" }
        if case .offline = session.link { return "wifi.exclamationmark" }
        return "checkmark.circle.fill"
    }

    private var tint: Color {
        if let streaming = session.streaming { return streaming.paused ? .orange : .red }
        if session.requested != nil { return .blue }
        switch session.link {
        case .online: return .green
        case .searching, .connecting, .reconnecting: return .orange
        case .offline: return .red
        }
    }
}
