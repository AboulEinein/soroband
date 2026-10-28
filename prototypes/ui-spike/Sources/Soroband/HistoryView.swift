import Charts
import SwiftUI

enum HistoryRange: String, CaseIterable, Identifiable {
    case day = "Day", week = "Week", month = "Month", year = "Year", all = "All Time"
    var id: String { rawValue }

    /// Calendar unit one step of the range covers; nil for All Time.
    var period: Calendar.Component? {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        case .all: nil
        }
    }

    var bucket: Calendar.Component {
        switch self {
        case .day: .hour
        case .week, .month, .all: .day
        case .year: .month
        }
    }
}

struct HistoryView: View {
    @Environment(UsageStore.self) private var store
    @State var selection: String? = "all"
    @State var range: HistoryRange = .month
    @State private var anchor = Date.now
    var expandedApp: String? = nil
    var hoverDate: Date? = nil

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("All Networks", systemImage: "globe").tag("all")
                ForEach(NetworkKind.allCases) { kind in
                    let nets = store.networks.filter { $0.kind == kind }
                    if !nets.isEmpty {
                        Section(kind.label) {
                            ForEach(nets) { net in
                                Label {
                                    Text(net.name)
                                } icon: {
                                    Image(systemName: kind.symbol).foregroundStyle(net.tint)
                                }
                                .badge(net.id == store.currentNetworkID ? Text("Connected").font(.caption2) : nil)
                                .tag(net.id)
                            }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            HistoryDetail(networkID: selection == "all" ? nil : selection, range: range, anchor: anchor, expandedApp: expandedApp, hoverDate: hoverDate)
                .toolbar {
                    ToolbarItemGroup {
                        Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                            .disabled(range == .all)
                        Button("Today") { anchor = .now }
                            .disabled(range == .all)
                        Button { shift(1) } label: { Image(systemName: "chevron.right") }
                            .disabled(range == .all)
                        Picker("Range", selection: $range) {
                            ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }
        }
    }

    private func shift(_ direction: Int) {
        guard let period = range.period else { return }
        anchor = Calendar.current.date(byAdding: period, value: direction, to: anchor)!
    }
}

