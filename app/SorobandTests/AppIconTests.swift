import AppKit
import Foundation
import Testing

@testable import Soroband

@MainActor
struct AppIconTests {
    /// Every icon Settings offers is a word the core stores: one the core refused would leave the
    /// pick unsaved. Asked of the core itself, so a change to its list goes red here. The test
    /// host's settings are shared, so the value is put back.
    @Test func theCoreTakesEveryIconSettingsOffers() throws {
        let original = try #require(Core.setting(AppIcon.settingKey))
        defer { Core.setSetting(AppIcon.settingKey, to: original) }
        for icon in AppIcon.allCases {
            #expect(Core.setSetting(AppIcon.settingKey, to: icon.rawValue), "\(icon.rawValue)")
            #expect(Core.setting(AppIcon.settingKey) == icon.rawValue)
        }
        #expect(!Core.setSetting(AppIcon.settingKey, to: "hairline"))
        #expect(AppIcon.hairlineCoral.label == "Hairline Coral")
        #expect(AppIcon.plum.label == "Plum")
    }

    /// Finder's icon is written by a Release build, and by a Debug build only when asked: Debug
    /// builds of every worktree share one data directory, and an `Icon\r` in a build's bundle
    /// fails Xcode's next signing of it. The test host never writes.
    @Test func onlyReleaseOrAnAskingDebugBuildWritesFinder() {
        let key = FinderIcon.debugEnvironmentKey
        #expect(FinderIcon.isEnabled(isDebug: false, environment: [:]))
        #expect(!FinderIcon.isEnabled(isDebug: true, environment: [:]))
        #expect(FinderIcon.isEnabled(isDebug: true, environment: [key: "1"]))
        #expect(!FinderIcon.isEnabled(isDebug: true, environment: [key: "0"]))
        #expect(!FinderIcon.isEnabled(isDebug: true, environment: [key: ""]))
        for isDebug in [false, true] {
            #expect(
                !FinderIcon.isEnabled(
                    isDebug: isDebug, environment: [key: "1", "XCTestConfigurationFilePath": "/tmp/x"]))
        }
    }

    /// `soroband config set app_icon` reaches the UI process: the snapshot the menu bar process
    /// sends carries the icon it read, even when nothing else changed.
    @Test func theSnapshotSentCarriesTheAppIcon() throws {
        let original = try #require(Core.setting(AppIcon.settingKey))
        defer {
            Core.setSetting(AppIcon.settingKey, to: original)
            Usage.shared.reloadSettings()
        }
        Usage.shared.reloadSettings()
        let picked: AppIcon = original == AppIcon.plum.rawValue ? .hairlineSky : .plum
        #expect(Core.setSetting(AppIcon.settingKey, to: picked.rawValue))
        Usage.shared.reloadSettings()
        #expect(UISnapshot.current().appIcon == picked)
    }

    /// The UI process takes the icon from the snapshot and shows it (About reads
    /// `NSApp.applicationIconImage`); graphite gives the bundle's icon back.
    @Test func theUIProcessAppliesTheMirroredIcon() {
        let usage = Usage()
        var snapshot = UISnapshot.current()
        snapshot.appIcon = .hairlineSky
        usage.mirror(snapshot)
        #expect(usage.appIcon == .hairlineSky)
        let custom = NSApp.applicationIconImage
        snapshot.appIcon = .graphite
        usage.mirror(snapshot)
        #expect(usage.appIcon == .graphite)
        #expect(NSApp.applicationIconImage !== custom, "graphite restores the bundle's icon")
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

    /// A bundle this account cannot change (another user's install, a read-only disk image) is never written, at a
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
