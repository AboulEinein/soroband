import SwiftUI

/// One black shape hanging from the top edge of the screen. At rest it is exactly the notch; a glance widens it
/// sideways at notch height; a moment grows it down into a panel. Content fades in after the shape has grown.
struct IslandView: View {
    @Environment(IslandModel.self) private var model
    @Environment(UsageStore.self) private var store
    let geometry: IslandGeometry

    private static let wing: CGFloat = 92

    private var showsHotspotGlance: Bool {
        model.current == nil && model.isOn(.hotspotMeter) && store.currentNetwork.kind == .hotspot
    }

    private struct Metrics: Equatable {
        var width: CGFloat
        var height: CGFloat
        var radius: CGFloat
        /// Width of the part inside the menu bar band.
        var bandWidth: CGFloat
    }

    private var metrics: Metrics {
        let band = geometry.menuBarHeight
        let notch = geometry.hasNotch ? geometry.notchWidth : 0
        let clearBand = model.seamless ? nil as CGFloat? : notch
        if let moment = model.current {
            let (w, h): (CGFloat, CGFloat) = switch moment.content {
            case .hog, .background: (470, band + 100)
            case .peek: (450, band + 104)
            default: (450, band + 66)
            }
            return Metrics(width: w, height: h, radius: 26, bandWidth: clearBand ?? w)
        }
        if showsHotspotGlance {
            if model.seamless {
                return Metrics(width: notch + 2 * Self.wing, height: band, radius: 11, bandWidth: notch + 2 * Self.wing)
            }
            return Metrics(width: max(notch + 60, 200), height: band + 26, radius: 13, bandWidth: notch)
        }
        return Metrics(width: notch, height: geometry.hasNotch ? band : 0, radius: 9, bandWidth: notch)
    }

    private var glanceInWings: Bool { model.seamless }

    var body: some View {
        let m = metrics
        let band = geometry.menuBarHeight
        ZStack(alignment: .top) {
            GeometryReader { proxy in
                let shape = IslandShape(width: m.width, height: m.height, radius: m.radius, bandWidth: m.bandWidth, band: band)
                shape
                    .fill(.black)
                    // `onHover` fires anywhere in the view's frame (the whole panel), so test the pointer
                    // against the island's own outline instead.
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            model.hoverChanged(shape.path(in: CGRect(origin: .zero, size: proxy.size)).contains(point))
                        case .ended:
                            model.hoverChanged(false)
                        }
                    }
            }
            Group {
                if let moment = model.current {
                    MomentView(moment: moment)
                        .frame(width: m.width, height: m.height - band)
                        .padding(.top, band)
                        .id(moment.id)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                                .animation(.easeOut(duration: 0.22).delay(0.14)),
                            removal: .opacity.animation(.easeIn(duration: 0.1))))
                } else if showsHotspotGlance {
                    Group {
                        if glanceInWings {
                            HotspotGlance(notchWidth: geometry.hasNotch ? geometry.notchWidth : 0, wing: Self.wing)
                                .frame(width: m.width, height: band)
                        } else {
                            HotspotGlance(notchWidth: 18, wing: (m.width - 18) / 2)
                                .frame(width: m.width, height: m.height - band)
                                .padding(.top, band)
                        }
                    }
                    .transition(.opacity.animation(.easeOut(duration: 0.2).delay(0.1)))
                }
            }
            .allowsHitTesting(model.current != nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: m)
    }
}

/// A rounded rectangle flush with the top edge, with small outward fillets where it meets the screen edge,
/// like the hardware notch. When `bandWidth` is narrower than `width`, the part inside the menu bar band stays
/// that narrow and the shape widens only below the band.
struct IslandShape: Shape {
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat
    var bandWidth: CGFloat
    let band: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(width, height), AnimatablePair(radius, bandWidth)) }
        set {
            width = newValue.first.first; height = newValue.first.second
            radius = newValue.second.first; bandWidth = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard width > 1, height > 1 else { return p }
        let cx = rect.midX
        let left = cx - width / 2, right = cx + width / 2
        let r = min(radius, height / 2, width / 2)
        let ear = min(6, height / 3)
        let necked = bandWidth < width - 12 && height > band + 12 && bandWidth > 0
        let nl = cx - bandWidth / 2, nr = cx + bandWidth / 2
        let topLeft = necked ? nl : left, topRight = necked ? nr : right

        p.move(to: CGPoint(x: topLeft - ear, y: 0))
        p.addQuadCurve(to: CGPoint(x: topLeft, y: ear), control: CGPoint(x: topLeft, y: 0))
        if necked {
            let f: CGFloat = 8
            p.addLine(to: CGPoint(x: nl, y: band - f))
            p.addQuadCurve(to: CGPoint(x: nl - f, y: band), control: CGPoint(x: nl, y: band))
            p.addLine(to: CGPoint(x: left + f, y: band))
            p.addQuadCurve(to: CGPoint(x: left, y: band + f), control: CGPoint(x: left, y: band))
        }
        p.addLine(to: CGPoint(x: left, y: height - r))
        p.addQuadCurve(to: CGPoint(x: left + r, y: height), control: CGPoint(x: left, y: height))
        p.addLine(to: CGPoint(x: right - r, y: height))
        p.addQuadCurve(to: CGPoint(x: right, y: height - r), control: CGPoint(x: right, y: height))
        if necked {
            let f: CGFloat = 8
            p.addLine(to: CGPoint(x: right, y: band + f))
            p.addQuadCurve(to: CGPoint(x: right - f, y: band), control: CGPoint(x: right, y: band))
            p.addLine(to: CGPoint(x: nr + f, y: band))
            p.addQuadCurve(to: CGPoint(x: nr, y: band - f), control: CGPoint(x: nr, y: band))
        }
        p.addLine(to: CGPoint(x: topRight, y: ear))
        p.addQuadCurve(to: CGPoint(x: topRight + ear, y: 0), control: CGPoint(x: topRight, y: 0))
        p.closeSubpath()
        return p
    }
}

/// Hotspot glance: today's hotspot bytes in the left wing, live speed in the right, the notch between.
private struct HotspotGlance: View {
    @Environment(UsageStore.self) private var store
    let notchWidth: CGFloat
    let wing: CGFloat

    var body: some View {
        let today = store.records(in: store.todayInterval, network: store.currentNetworkID).totals.total
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "personalhotspot").foregroundStyle(store.currentNetwork.tint)
                Text(formatBytes(today)).fontWeight(.semibold)
            }
            .frame(width: wing)
            Spacer().frame(width: notchWidth)
            Text("↓ \(formatRate(store.liveDown))")
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: wing)
        }
        .font(.system(size: 11.5))
        .lineLimit(1)
        .monospacedDigit()
        .foregroundStyle(.white)
    }
}

private struct MomentView: View {
    @Environment(IslandModel.self) private var model
    @Environment(UsageStore.self) private var store
    let moment: Moment

    var body: some View {
        Group {
            switch moment.content {
            case .joined(let id): joined(store.network(id))
            case .left(let id, let since): left(store.network(id), since: since)
            case .hotspot: EmptyView()
            case .peek: peek
            case .hog(let appID, let bytes, let minutes): hog(store.app(appID), bytes: bytes, minutes: minutes)
            case .background(let appID, let bytes, let uploading): background(store.app(appID), bytes: bytes, uploading: uploading)
            case .transfer(let appID, let via, let bytes, let rate, let done): transfer(store.app(appID), via: via, bytes: bytes, rate: rate, done: done)
            case .recap: recap
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Peek

    private var peek: some View {
        let net = store.currentNetwork
        let today = store.records(in: store.todayInterval, network: net.id)
        let apps = today.grouped(by: \.appID).prefix(3)
        return VStack(alignment: .leading, spacing: 12) {
            Row(title: "\(net.name) · today \(formatBytes(today.totals.total))",
                subtitle: "↓ \(formatBytes(today.totals.down))  ↑ \(formatBytes(today.totals.up))  ·  now ↓ \(formatRate(store.liveDown))") {
                NetworkTile(net: net)
            } trailing: { EmptyView() }
            HStack(spacing: 16) {
                ForEach(apps, id: \.id) { row in
                    HStack(spacing: 6) {
                        AppIconView(app: store.app(row.id))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(store.app(row.id).name).font(.system(size: 11)).lineLimit(1)
                            Text(formatBytes(row.totals.total)).font(.system(size: 11, weight: .semibold))
                        }
                    }
                }
            }
            .monospacedDigit()
        }
    }

    // MARK: Network summaries

    private func joined(_ net: Network) -> some View {
        let week = store.records(in: Calendar.current.dateInterval(of: .weekOfYear, for: .now)!, network: net.id).totals.total
        let lastSeen = store.lastSeenBefore(net.id, store.connectedSince)
        return Row(title: "Joined \(net.name)",
                   subtitle: "\(formatBytes(week)) this week" + (lastSeen.map { " · last here \($0.formatted(.relative(presentation: .named)))" } ?? " · first visit")) {
            NetworkTile(net: net)
        } trailing: {
            Stat(label: "Today here", value: formatBytes(store.records(in: store.todayInterval, network: net.id).totals.total))
        }
    }

    private func left(_ net: Network, since: Date) -> some View {
        let session = store.records(in: DateInterval(start: since, end: .now), network: net.id)
        let top = session.grouped(by: \.appID).first
        let duration = Duration.seconds(Date.now.timeIntervalSince(since)).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return Row(title: "Left \(net.name)", subtitle: "\(formatBytes(session.totals.total)) over \(duration)") {
            NetworkTile(net: net)
        } trailing: {
            if let top {
                HStack(spacing: 6) {
                    AppIconView(app: store.app(top.id))
                    Stat(label: "Top: \(store.app(top.id).name)", value: formatBytes(top.totals.total))
                }
            }
        }
    }

    private var recap: some View {
        let today = store.records(in: store.todayInterval)
        let networks = today.grouped(by: \.networkID)
        let topApp = today.grouped(by: \.appID).first.map { store.app($0.id).name } ?? "–"
        return Row(title: "Today: \(formatBytes(today.totals.total)) across \(networks.count) network\(networks.count == 1 ? "" : "s")",
                   subtitle: "Top app: \(topApp) · counter resets now, history kept") {
            Image(systemName: "calendar").font(.title2).frame(width: 34, height: 34)
        } trailing: { EmptyView() }
    }

    // MARK: Alerts

    private func hog(_ app: AppInfo, bytes: Int64, minutes: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Row(title: "\(app.name) used \(formatBytes(bytes)) in \(minutes) min",
                subtitle: "on \(store.currentNetwork.name) (\(store.currentNetwork.kind.label))") {
                AppIconView(app: app).scaleEffect(1.6).frame(width: 34, height: 34)
            } trailing: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                if model.offerPause && store.currentNetwork.kind == .hotspot {
                    IslandButton(title: "Pause until off hotspot", prominent: true) { model.dismiss() }
                }
                IslandButton(title: "Ignore \(app.name)") { model.dismiss() }
                IslandButton(title: "Details") { model.dismiss() }
            }
        }
    }

    private func background(_ app: AppInfo, bytes: Int64, uploading: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Row(title: "\(app.name) · background \(uploading ? "upload" : "download")",
                subtitle: "\(formatBytes(bytes)) in the last few minutes, no app in front") {
                AppIconView(app: app).scaleEffect(1.6).frame(width: 34, height: 34)
            } trailing: {
                Image(systemName: "moon.zzz.fill").foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                IslandButton(title: "Details", prominent: true) { model.dismiss() }
                IslandButton(title: "Ignore \(app.name)") { model.dismiss() }
            }
        }
    }

    private func transfer(_ app: AppInfo, via: String?, bytes: Int64, rate: Double, done: Bool) -> some View {
        Row(title: via.map { "\(app.name) via \($0)" } ?? app.name,
            subtitle: done ? "Finished · \(formatBytes(bytes))" : "\(formatBytes(bytes)) so far · \(formatRate(rate))") {
            ZStack {
                AppIconView(app: app)
                if done {
                    Circle().stroke(.green, lineWidth: 2.5)
                } else {
                    SpinningArc()
                }
            }
            .frame(width: 34, height: 34)
        } trailing: {
            if done {
                Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
            }
        }
    }
}

private struct Row<Leading: View, Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            leading()
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .monospacedDigit()
    }
}

private struct Stat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
            Text(value).font(.system(size: 13, weight: .semibold))
        }
    }
}

private struct NetworkTile: View {
    let net: Network

    var body: some View {
        Image(systemName: net.kind.symbol)
            .font(.system(size: 15, weight: .semibold))
            .frame(width: 34, height: 34)
            .background(net.tint.gradient, in: .rect(cornerRadius: 9))
    }
}

private struct IslandButton: View {
    let title: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.white.opacity(prominent ? 0.24 : 0.12), in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

private struct SpinningArc: View {
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.3)
            .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}
