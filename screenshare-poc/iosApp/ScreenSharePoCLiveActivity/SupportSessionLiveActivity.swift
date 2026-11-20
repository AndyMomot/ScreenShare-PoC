// Widget extension UI for the support-session Live Activity. It only renders; the End button's intent runs in the app.
import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Extension entry point; the bundle contains only the Live Activity.
@main
struct SupportSessionWidgets: WidgetBundle {
    var body: some Widget {
        SupportSessionLiveActivity()
    }
}

/// Session indicator outside the app: Dynamic Island and Lock Screen, with the time and an End button.
struct SupportSessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SupportSessionAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.supportName, systemImage: context.state.phase.icon)
                        .foregroundStyle(context.state.phase.color)
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedTime(since: context.attributes.startedAt)
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.phase.title(wholeDevice: context.attributes.wholeDevice))
                            .font(.subheadline)
                        Spacer()
                        Button(intent: EndSupportSessionIntent()) {
                            Text("End").bold()
                        }
                        .tint(.red)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.phase.icon)
                    .foregroundStyle(context.state.phase.color)
            } compactTrailing: {
                ElapsedTime(since: context.attributes.startedAt)
                    .frame(maxWidth: 44)
            } minimal: {
                Image(systemName: context.state.phase.icon)
                    .foregroundStyle(context.state.phase.color)
            }
        }
    }
}

/// Lock Screen / banner presentation of the activity.
private struct LockScreenView: View {
    let context: ActivityViewContext<SupportSessionAttributes>

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: context.state.phase.icon)
                .font(.title2)
                .foregroundStyle(context.state.phase.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(context.state.phase.title(wholeDevice: context.attributes.wholeDevice))
                    .font(.headline)
                    .foregroundStyle(.white)
                HStack(spacing: 4) {
                    Text(context.attributes.supportName)
                    Text("·")
                    ElapsedTime(since: context.attributes.startedAt)
                }
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Button(intent: EndSupportSessionIntent()) {
                Text("End").bold()
            }
            .tint(.red)
        }
        .padding(16)
    }
}

/// Self-updating session timer; the system renders `timerInterval` text without app updates.
private struct ElapsedTime: View {
    let since: Date

    var body: some View {
        Text(timerInterval: since...Date.distantFuture, countsDown: false)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
    }
}

/// Icon, color and text per phase, shared by all presentations.
private extension SupportSessionAttributes.Phase {
    var icon: String {
        switch self {
        case .viewing: "eye.fill"
        case .control: "hand.tap.fill"
        case .paused: "pause.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .viewing: .red
        case .control: .orange
        case .paused: .gray
        }
    }

    func title(wholeDevice: Bool) -> String {
        switch self {
        case .viewing: wholeDevice ? "Support sees your screen" : "Support sees the app"
        case .control: "Support can control the app"
        case .paused: "Sharing paused · open the app"
        }
    }
}
