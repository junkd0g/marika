import Foundation
import Testing
@testable import MarikaCore

struct PreviewRecoveryTests {
    let config = PreviewConfiguration(command: "npm run dev", address: "http://localhost:3000")

    @Test func recoveryOnlyStartsTheMatchingLocalProjectServer() {
        #expect(PreviewRecovery.matches(URL(string: "http://127.0.0.1:3000/settings?q=one"), configuration: config))
        for value in ["http://localhost:5173/", "https://localhost:3000/", "https://example.com/", "http://example.com:3000/", "file:///tmp/index.html", "http://user:password@localhost:3000/"] {
            #expect(!PreviewRecovery.matches(URL(string: value), configuration: config))
        }
        #expect(!PreviewRecovery.matches(URL(string: config.address), configuration: nil))
        #expect(!PreviewRecovery.matches(URL(string: config.address), configuration: PreviewConfiguration(command: " ", address: config.address)))
    }

    @Test func aKnownDynamicPortCanRecoverAndTheRouteIsPreserved() {
        let page = URL(string: "http://localhost:3001/settings/profile?theme=dark#account")!
        #expect(PreviewRecovery.matches(page, configuration: config, runningAddress: URL(string: "http://localhost:3001/")))
        #expect(PreviewRecovery.reloadURL(page, server: URL(string: "http://127.0.0.1:3002/")!)?.absoluteString == "http://127.0.0.1:3002/settings/profile?theme=dark#account")
    }
}
