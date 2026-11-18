import SwiftUI

/// Shown next to the Mac clock on the support page: the difference is the glass-to-glass latency.
struct ClockView: View {
    var body: some View {
        TimelineView(.animation) { context in
            Text(context.date, format: .dateTime.hour().minute().second().secondFraction(.fractional(3)))
                .font(.system(size: 40, weight: .bold, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
