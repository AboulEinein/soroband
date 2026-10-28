import Charts
import SwiftUI

/// Option C's popover in SwiftUI. `charts` draws the hourly beads with Swift Charts instead of shapes.
struct SwiftUIPopover: View {
    let charts: Bool
    @State private var tab = 0
    @State private var grown = false
    private let blue = Color(nsColor: Fake.blue)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            hero
            Picker("", selection: $tab) {
                Text("Apps").tag(0)
                Text("Networks").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden()
            HStack {
                Text("Today on \(Fake.network)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("All networks", isOn: .constant(false)).toggleStyle(.switch).controlSize(.mini)
                    .font(.caption)
            }
            VStack(spacing: 9) {
                ForEach(Fake.apps, id: \.name) { app in row(app) }
            }
            footer
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { withAnimation(.spring(duration: 0.5)) { grown = true } }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "wifi").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28).background(blue.gradient, in: .rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text(Fake.network).font(.system(size: 13, weight: .semibold))
                    Text(Fake.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("↓ \(Fake.speed.0)")
                    Text("↑ \(Fake.speed.1)")
                }
                .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Fake.total).font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                Text(Fake.unit).font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("today on\nthis network").font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            HStack {
                Text("↓ \(Fake.down) download")
                Text("↑ \(Fake.up) upload")
                Spacer()
                Text("all \(Fake.allNetworks)")
            }
            .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            if charts { chartBeads } else { shapeBeads }
            HStack {
                ForEach(["12 AM", "6", "12 PM", "6", "11 PM"], id: \.self) { label in
                    Text(label)
                    if label != "11 PM" { Spacer() }
                }
            }
            .font(.system(size: 9.5)).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(blue.opacity(0.18).gradient)
                RadialGradient(
                    colors: [blue.opacity(0.35), .clear], center: .topLeading, startRadius: 0, endRadius: 260)
            }
            .clipShape(.rect(cornerRadius: 14))
        }
    }

    private var shapeBeads: some View {
        let peak = Fake.hours.max() ?? 1
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(Fake.hours.indices, id: \.self) { hour in
                let future = hour > Fake.nowHour
                RoundedRectangle(cornerRadius: 3)
                    .fill(future ? Color.secondary.opacity(0.2) : blue.opacity(0.9))
                    .frame(height: future ? 3 : max(3, (grown ? Fake.hours[hour] / peak : 0) * 30))
                    .overlay {
                        if hour == Fake.nowHour {
                            RoundedRectangle(cornerRadius: 4).stroke(blue.opacity(0.6), lineWidth: 1.5).padding(-2.5)
                        }
                    }
            }
        }
        .frame(height: 30, alignment: .bottom)
    }

    private var chartBeads: some View {
        Chart(Fake.hours.indices, id: \.self) { hour in
            BarMark(x: .value("Hour", hour), y: .value("MB", grown ? Fake.hours[hour] : 0))
                .foregroundStyle(hour > Fake.nowHour ? Color.secondary.opacity(0.2) : blue.opacity(0.9))
                .cornerRadius(3)
        }
        .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
        .frame(height: 30)
    }

    private func row(_ app: (name: String, path: String, value: String, share: Double)) -> some View {
        HStack(spacing: 10) {
            Group {
                if app.path.isEmpty || !Fake.icons {
                    Image(systemName: "ellipsis.circle").font(.system(size: 18)).foregroundStyle(.secondary)
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable()
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(app.name).font(.system(size: 13))
                    Spacer()
                    Text(app.value).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(app.path.isEmpty ? Color.secondary : blue)
                            .frame(width: proxy.size.width * (grown ? app.share : 0))
                    }
                }
                .frame(height: 4)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: {}) {
                HStack(spacing: 10) {
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(Fake.week.indices, id: \.self) { day in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(day == Fake.week.count - 1 ? Color.primary : Color.secondary.opacity(0.5))
                                .frame(width: 4, height: Fake.week[day] / 11.5 * 20)
                        }
                    }
                    .frame(height: 20, alignment: .bottom)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("History").font(.system(size: 12, weight: .semibold))
                        Text("62.3 GB this month").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("⌘Y").font(.system(size: 10)).foregroundStyle(.tertiary)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            ForEach(["gearshape", "power"], id: \.self) { symbol in
                Button(action: {}) {
                    Image(systemName: symbol).frame(width: 36, height: 36)
                        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
