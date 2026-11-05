import SwiftUI

/// The ui-spike's island in SwiftUI, hosted in an `NSHostingView` in the panel.
@MainActor @Observable
final class SwiftUIIslandModel {
    var current: Content?
    var id = 0
}

struct SwiftUIIsland: View {
    let model: SwiftUIIslandModel
    let geometry: IslandGeometry

    var body: some View {
        let m = metrics(for: model.current, geometry: geometry)
        let band = geometry.menuBarHeight
        ZStack(alignment: .top) {
            IslandShape(m: m, band: band).fill(.black)
            if let content = model.current {
                MomentRow(lines: .of(content))
                    .frame(width: m.width, height: m.height - band)
                    .padding(.top, band)
                    .id(model.id)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                                .animation(.easeOut(duration: 0.22).delay(0.14)),
                            removal: .opacity.animation(.easeIn(duration: 0.1))))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: m)
    }
}

struct IslandShape: Shape {
    var m: Metrics
    let band: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(m.width, m.height), AnimatablePair(m.radius, m.bandWidth)) }
        set { m = Metrics(width: newValue.first.first, height: newValue.first.second, radius: newValue.second.first, bandWidth: newValue.second.second) }
    }

    func path(in rect: CGRect) -> Path { Path(islandPath(m, band: band, in: rect, flipped: false)) }
}

private struct MomentRow: View {
    let lines: Lines

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(nsImage: lines.icon).resizable().frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(lines.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(lines.subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let trailing = lines.trailing {
                    Text(trailing).font(.system(size: 13, weight: .semibold))
                }
            }
            if !lines.buttons.isEmpty {
                HStack(spacing: 8) {
                    ForEach(lines.buttons, id: \.self) { title in
                        Button {} label: {
                            Text(title).font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(.white.opacity(0.12), in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .monospacedDigit()
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
