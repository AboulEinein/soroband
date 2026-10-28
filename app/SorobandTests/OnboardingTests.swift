import CoreLocation
import Testing

@testable import Soroband

struct OnboardingTests {
    @Test func firstRunAsksForLocationOnce() {
        #expect(Onboarding.shouldShow(status: .notDetermined, alreadyShown: false))
        #expect(!Onboarding.shouldShow(status: .notDetermined, alreadyShown: true))
    }

    @Test func aChoiceAlreadyMadeIsNotAskedAgain() {
        // macOS shows its prompt only while undetermined; after that the window would offer nothing.
        for status in [CLAuthorizationStatus.authorizedAlways, .denied, .restricted] {
            #expect(!Onboarding.shouldShow(status: status, alreadyShown: false))
        }
    }
}
