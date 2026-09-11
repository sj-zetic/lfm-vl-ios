import SwiftUI

@main
struct ZeticMLangeLLMSampleApp: App {
    @UIApplicationDelegateAdaptor(ZeticMLangeLLMSampleAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
