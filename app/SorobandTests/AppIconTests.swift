import AppKit
import Foundation
import Testing

@testable import Soroband

@MainActor
struct AppIconTests {
    /// The app's words must be the core's, in the core's order (`APP_ICON_OPTIONS`): a word only
    /// one side knows would be refused by `config set` or shown as graphite.
    @Test func theIconsAreTheCoresWords() {
        #expect(
            AppIcon.allCases.map(\.rawValue) == [
                "graphite", "indigo", "plum", "light", "hairline-coral", "hairline-indigo", "hairline-teal",
                "hairline-emerald", "hairline-amber", "hairline-rose", "hairline-sky", "hairline-graphite",
                "hairline-paper",
            ])
        #expect(AppIcon.hairlineCoral.label == "Hairline Coral")
        #expect(AppIcon.plum.label == "Plum")
    }

    /// A value the app does not know (a hand edit, a word from a newer Soroband) and a missing one
    /// show the bundle's own icon, as a fresh install does.
    @Test(arguments: ["hairline", "Indigo", "hairline_coral", "", "coral"])
    func unknownValuesFallBackToGraphite(value: String) {
        #expect(AppIcon(setting: value) == .graphite)
        #expect(AppIcon(setting: nil) == .graphite)
        #expect(AppIcon(setting: "hairline-paper") == .hairlinePaper)
    }

    /// Graphite is the bundle's icon, so it sets no custom image anywhere (nil restores the Dock's
    /// and Finder's default); every other icon is its own file in the bundle, the one in its name.
    @Test func graphiteSetsNoImageAndEveryOtherIconHasItsFile() throws {
        #expect(AppIcon.graphite.customImage() == nil)
        #expect(AppIcon.graphite.resourceName == "AppIcon")
        #expect(AppIcon.hairlineSky.resourceName == "AppIcon-hairline-sky")
        for icon in AppIcon.allCases {
            let url = try #require(
                Bundle.main.url(forResource: icon.resourceName, withExtension: "icns"), "\(icon) is in the bundle")
            let pixels = Set(try #require(NSImage(contentsOf: url)).representations.map(\.pixelsWide))
            if icon == .graphite {
                // The asset catalog's file, which Settings draws its 96-pixel tile from.
                #expect(pixels.contains(128), "\(pixels.sorted())")
            } else {
                // Finder and the Dock draw the icon from 16 to 1024 pixels, so each file carries
                // every size, the smallest drawn on its own rather than scaled down.
                #expect(pixels.isSuperset(of: [16, 32, 64, 128, 256, 512, 1024]), "\(icon): \(pixels.sorted())")
            }
        }
        #expect(AppIcon.indigo.customImage() != nil)
    }

    /// A launch with the bundle's icon chosen writes nothing to a bundle that has no custom icon,
    /// the common case: no image is decoded at launch.
    @Test func launchWithGraphiteOnAPlainBundleWritesNothing() {
        #expect(FinderIconPlan.atLaunch(.graphite, hasCustomIcon: false, written: nil, canWrite: true) == nil)
        #expect(FinderIconPlan.atLaunch(.graphite, hasCustomIcon: false, written: .plum, canWrite: true) == nil)
    }

    /// The icon is in place from an earlier launch: nothing to do.
    @Test func launchWithTheIconAlreadyInFinderWritesNothing() {
        #expect(FinderIconPlan.atLaunch(.plum, hasCustomIcon: true, written: .plum, canWrite: true) == nil)
    }

    /// An update replaces the bundle, which loses its `Icon\r`: the next launch writes it again.
    @Test func launchAfterAnUpdateReplacedTheBundleWritesTheIconAgain() {
        #expect(FinderIconPlan.atLaunch(.plum, hasCustomIcon: false, written: .plum, canWrite: true) == .set(.plum))
        #expect(FinderIconPlan.atLaunch(.plum, hasCustomIcon: false, written: nil, canWrite: true) == .set(.plum))
    }

    /// `soroband config set app_icon` while Soroband was not running: Finder still holds the last
    /// icon written, so the launch writes the new one, or takes it off for graphite.
    @Test func launchAfterTheSettingChangedWhileQuitWritesTheNewIcon() {
        #expect(
            FinderIconPlan.atLaunch(.light, hasCustomIcon: true, written: .plum, canWrite: true) == .set(.light))
        #expect(FinderIconPlan.atLaunch(.graphite, hasCustomIcon: true, written: .plum, canWrite: true) == .remove)
    }

    /// A custom icon Soroband never wrote (the user pasted one in Finder) stays with graphite; with
    /// another icon chosen, Soroband's replaces it.
    @Test func aCustomIconSorobandDidNotWriteStaysWithGraphite() {
        #expect(FinderIconPlan.atLaunch(.graphite, hasCustomIcon: true, written: nil, canWrite: true) == nil)
        #expect(
            FinderIconPlan.atLaunch(.hairlineTeal, hasCustomIcon: true, written: nil, canWrite: true)
                == .set(.hairlineTeal))
    }

    /// A bundle this account cannot change (another user installed it) is never written, at a
    /// launch or a change, so nothing retries a write that would fail; Settings says Finder keeps
    /// the default instead.
    @Test(arguments: AppIcon.allCases)
    func aBundleThisAccountCannotChangeIsNeverWritten(icon: AppIcon) {
        for hasCustomIcon in [false, true] {
            for written in [nil, AppIcon.plum] {
                #expect(
                    FinderIconPlan.atLaunch(icon, hasCustomIcon: hasCustomIcon, written: written, canWrite: false)
                        == nil)
            }
        }
        #expect(FinderIconPlan.changed(from: .graphite, to: icon, canWrite: false) == nil)
        #expect(FinderIconPlan.changed(from: icon, to: .graphite, canWrite: false) == nil)
    }

    /// A change while Soroband runs writes the new icon, graphite takes the custom one off, and a
    /// reread of unchanged settings (another key was set) writes nothing.
    @Test func aChangeWritesTheNewIconOrTakesItOff() {
        #expect(FinderIconPlan.changed(from: .graphite, to: .indigo, canWrite: true) == .set(.indigo))
        #expect(FinderIconPlan.changed(from: .indigo, to: .hairlineRose, canWrite: true) == .set(.hairlineRose))
        #expect(FinderIconPlan.changed(from: .indigo, to: .graphite, canWrite: true) == .remove)
        #expect(FinderIconPlan.changed(from: .indigo, to: .indigo, canWrite: true) == nil)
        #expect(FinderIconPlan.changed(from: .graphite, to: .graphite, canWrite: true) == nil)
    }

    /// The writer process, on a scratch folder: an icon gives it Finder's `Icon\r`, graphite
    /// takes it off again, and arguments that name no icon or no path write nothing.
    @Test func theWriterSetsAndRemovesTheCustomIcon() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AppIconWriter-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(FinderIcon.runWriter(["hairline-sky", folder.path]) == 0)
        #expect(FinderIcon.hasCustomIcon(folder))
        #expect(FinderIcon.runWriter(["graphite", folder.path]) == 0)
        #expect(!FinderIcon.hasCustomIcon(folder))
        #expect(FinderIcon.runWriter(["hairline", folder.path]) == 2)
        #expect(FinderIcon.runWriter(["plum"]) == 2)
        #expect(!FinderIcon.hasCustomIcon(folder))
    }

    /// The checks the launch makes, on real folders: a folder this account owns is writable and
    /// one it cannot write is not, and only a folder with an `Icon\r` file has a custom icon.
    @Test func theLaunchChecksReadTheBundleItself() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AppIconTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        #expect(FinderIcon.canWrite(folder))
        #expect(!FinderIcon.hasCustomIcon(folder))
        FileManager.default.createFile(atPath: folder.appendingPathComponent("Icon\r").path, contents: Data())
        #expect(FinderIcon.hasCustomIcon(folder))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        #expect(!FinderIcon.canWrite(folder))
    }
}
