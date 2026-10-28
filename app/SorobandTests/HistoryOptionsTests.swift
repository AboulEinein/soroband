import Foundation
import Testing

@testable import Soroband

/// The options the menu bar app hands the History process, as arguments at launch or as a line
/// on its standard input in standby.
struct HistoryOptionsTests {
    @Test func everyOptionSurvivesTheTrip() {
        let options = HistoryOptions(
            range: .year, date: Date(timeIntervalSince1970: 1_793_088_000.5), network: 3, current: 2,
            requested: Date(timeIntervalSince1970: 1_793_164_454.25), expandedApp: "/Applications/Safari.app",
            hover: Date(timeIntervalSince1970: 1_793_000_000))
        #expect(HistoryOptions(arguments: ["/path/Soroband"] + options.arguments) == options)
        // A standby line arrives without the executable's path.
        let line = options.arguments.joined(separator: HistoryOptions.separator)
        #expect(HistoryOptions(arguments: line.components(separatedBy: HistoryOptions.separator)) == options)
    }

    @Test func historyNeedsItsFlagAndDefaultsToThisMonthOnEveryNetwork() {
        #expect(HistoryOptions(arguments: ["/path/Soroband"]) == nil, "the menu bar app")
        #expect(HistoryOptions(arguments: ["/path/Soroband", "--range", "year"]) == nil)
        let plain = HistoryOptions(arguments: ["/path/Soroband", "--history", "--standby"])
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
        let line = options.arguments.joined(separator: HistoryOptions.separator)
        #expect(
            HistoryOptions(arguments: line.components(separatedBy: HistoryOptions.separator))?.expandedApp
                == "/Applications/Some App.app")
    }
}
