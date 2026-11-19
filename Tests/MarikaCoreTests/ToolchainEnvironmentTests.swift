import Foundation
import Testing
@testable import MarikaCore

struct ToolchainEnvironmentTests {
    @Test func explicitDeveloperToolchainSurvivesShellCapture() async {
        let environment = await ShellEnvironment.capture(from: ["SHELL": "/bin/sh", "DEVELOPER_DIR": "/Applications/ChosenXcode.app/Contents/Developer", "TOOLCHAINS": "com.apple.dt.toolchain.XcodeDefault"])
        #expect(environment["DEVELOPER_DIR"] == "/Applications/ChosenXcode.app/Contents/Developer")
        #expect(environment["TOOLCHAINS"] == "com.apple.dt.toolchain.XcodeDefault")
    }
}
