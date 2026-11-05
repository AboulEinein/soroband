import Foundation
import Testing

@testable import Soroband

/// The options the menu bar process hands the UI process's History window, as arguments.
struct HistoryOptionsTests {
    @Test func everyOptionSurvivesTheTrip() throws {
        let options = HistoryOptions(
            range: .year, date: Date(timeIntervalSince1970: 1_793_088_000.5), network: 3, current: 2,
            requested: Date(timeIntervalSince1970: 1_793_164_454.25), expandedApp: "/Applications/Safari.app",
            hover: Date(timeIntervalSince1970: 1_793_000_000))
        #expect(HistoryOptions(arguments: options.arguments) == options)
        let request = try JSONEncoder().encode(UIRequest.showHistory(arguments: options.arguments, replacing: false))
        guard case .showHistory(let arguments, _, _) = try JSONDecoder().decode(UIRequest.self, from: request) else {
            Issue.record("not a History request")
            return
        }
        #expect(HistoryOptions(arguments: arguments) == options)
    }

    @Test func historyNeedsItsFlagAndDefaultsToThisMonthOnEveryNetwork() {
        #expect(HistoryOptions(arguments: ["--range", "year"]) == nil)
        let plain = HistoryOptions(arguments: ["--history"])
        #expect(plain == HistoryOptions())
        #expect(plain?.range == .month)
        #expect(plain?.network == nil)
    }

    @Test func unreadableValuesFallBackToTheDefaults() {
        let options = HistoryOptions(arguments: ["--history", "--range", "fortnight", "--network", "Home"])
        #expect(options?.range == .month)
        #expect(options?.network == nil)
    }

    @Test func anAppIDWithSpacesStaysOneValue() {
        let options = HistoryOptions(expandedApp: "/Applications/Some App.app")
        #expect(HistoryOptions(arguments: options.arguments)?.expandedApp == "/Applications/Some App.app")
    }
}
