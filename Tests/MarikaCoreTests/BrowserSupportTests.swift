import Foundation
import Testing

@testable import MarikaCore

struct BrowserSupportTests {
    @Test func addressesHandleLocalPortsPublicSitesAndRejectExecutableSchemes() throws {
        let root = URL(fileURLWithPath: "/tmp/project")
        #expect(try BrowserAddress.resolve("localhost:3000/settings", projectRoot: root).absoluteString == "http://localhost:3000/settings")
        #expect(try BrowserAddress.resolve("127.0.0.1:5173", projectRoot: root).scheme == "http")
        #expect(try BrowserAddress.resolve("example.com/docs", projectRoot: root).absoluteString == "https://example.com/docs")
        for address in ["javascript:alert(1)", "data:text/html,hello", "mailto:a@example.com", "ftp://example.com", "https://name:secret@example.com"] {
            #expect(throws: (any Error).self) { try BrowserAddress.resolve(address, projectRoot: root) }
        }
        #expect(!BrowserAddress.isLocal(try #require(URL(string: "http://localhost.evil.example"))))
        #expect(!BrowserAddress.isLocal(try #require(URL(string: "http://127.0.0.1.evil.example"))))
        #expect(BrowserAddress.isLocal(try #require(URL(string: "http://[::1]:3000"))))
    }

    @Test func filePreviewsCannotEscapeThroughSymlinksOrSiblingPrefixes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let html = root.appendingPathComponent("index.html")
        try Data("<h1>Preview</h1>".utf8).write(to: html)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside.html"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        #expect(try BrowserAddress.resolve("index.html", projectRoot: root) == html.resolvingSymlinksInPath())
        #expect(throws: (any Error).self) { try BrowserAddress.resolve("outside.html", projectRoot: root) }
        #expect(throws: (any Error).self) { try BrowserAddress.validate(URL(fileURLWithPath: root.path + "-other/index.html"), projectRoot: root) }
    }

    @Test func originsSeparateSchemesAndPortsAndNormalizeDefaultPorts() throws {
        func origin(_ text: String) throws -> String { BrowserAddress.origin(try #require(URL(string: text))) }
        #expect(try origin("https://example.com/a") == origin("https://example.com:443/b"))
        #expect(try origin("http://localhost:3000") != origin("http://localhost:5173"))
        #expect(try origin("https://example.com") != origin("http://example.com"))
    }

    @Test func browserCredentialsStayOutOfCommandArgumentsAndGlobalConfig() throws {
        let config = BrowserMCPConfiguration(executable: URL(fileURLWithPath: "/tmp/My App/Browser"), endpoint: "http://127.0.0.1:1234/browser", token: "private-token")
        #expect(!config.codexArguments.joined().contains("private-token"))
        #expect(!String(decoding: try config.claudeConfig.serialized(), as: UTF8.self).contains("private-token"))
        #expect(config.claudeConfig["mcpServers"]?["marika_browser"]?["env"]?["MARIKA_BROWSER_TOKEN"]?.string == "${MARIKA_BROWSER_TOKEN}")
        let launch = AgentLaunch(executable: URL(fileURLWithPath: "/tmp/codex"), environment: ["PATH": "/usr/bin"], workingDirectory: URL(fileURLWithPath: "/tmp"), settings: AgentSettings(), browser: config)
        #expect(launch.environment["MARIKA_BROWSER_TOKEN"] == "private-token")
        #expect(launch.environment["PATH"] == "/usr/bin")
    }

    @Test func bridgeAcceptsAuthenticatedRequestsAndRejectsMissingCredentials() async throws {
        let bridge = try BrowserBridgeServer(token: "test-private-token") { params in
            BrowserTools.text("handled " + (params["name"]?.string ?? ""))
        }
        defer { bridge.stop() }
        let endpoint = try await bridge.start()
        var request = URLRequest(url: try #require(URL(string: endpoint)))
        request.httpMethod = "POST"
        request.httpBody = try JSONValue.object(["name": "browser_tabs"]).serialized()
        request.timeoutInterval = 5
        let (_, denied) = try await URLSession.shared.data(for: request)
        #expect((denied as? HTTPURLResponse)?.statusCode == 401)
        request.setValue("Bearer test-private-token", forHTTPHeaderField: "Authorization")
        let (data, accepted) = try await URLSession.shared.data(for: request)
        #expect((accepted as? HTTPURLResponse)?.statusCode == 200)
        #expect(try JSONValue(parsing: data)["content"]?[0]?["text"]?.string == "handled browser_tabs")
    }
}
