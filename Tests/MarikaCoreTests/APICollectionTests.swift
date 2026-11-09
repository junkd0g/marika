import Foundation
import Testing
@testable import MarikaCore

struct APICollectionTests {
    @Test func headersAcceptEmptyValuesAndPreserveColons() throws {
        let fields = try APICollection.parseHeaders("  X-Empty:\r\nAuthorization: Bearer a:b\r\n\r\nX-Tab:\tvalue\t")
        #expect(fields == ["X-Empty": "", "Authorization": "Bearer a:b", "X-Tab": "value"])
    }

    @Test func headersRejectInvalidNamesAndControlCharacters() {
        for input in [": value", "Bad Name: value", "Bad(Name): value", "Héader: value", "X-Test: one\u{0}two", "X-Test: one\rtwo", "X-Test: one\u{7F}two"] {
            #expect(throws: AgentError.self) { try APICollection.parseHeaders(input) }
        }
    }

    @Test func headersRejectCaseInsensitiveDuplicates() {
        #expect(throws: AgentError.self) { try APICollection.parseHeaders("X-Mode: first\nx-mode: second") }
        #expect(throws: AgentError.self) { try APICollection.parseHeaders("Accept: first\nAccept: second") }
    }

    @Test func sourceAndComposePathsStayInsideProject() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = temp.appendingPathComponent("server")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let external = temp.appendingPathComponent("outside.yml")
        try Data().write(to: external)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("compose.yml"), withDestinationURL: external)
        #expect(throws: AgentError.self) { try APICollection.projectFile("compose.yml", root: root) }
        #expect(throws: AgentError.self) { try APICollection.projectFile("../outside.yml", root: root) }
    }
    @Test func mixedCollectionKeepsGraphQLOperationsDistinctAndResolvesRPCSource() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try Data().write(to: temp.appendingPathComponent("schema.proto"))
        let json = #"""
        {"baseURL":"http://localhost:8080","endpoints":[
          {"name":"Player","method":"GRAPHQL","path":"/graphql","source":"schema.proto","body":"query { player }"},
          {"name":"League","method":"GRAPHQL","path":"/graphql","source":"schema.proto","body":"query { league }"},
          {"name":"Read","method":"GRPC","path":"sport.Query/Read","source":"schema.proto","protoFile":"schema.proto","target":"grpc://localhost:9090"}]}
        """#
        let collection = try JSONDecoder().decode(APICollection.self, from: Data(json.utf8))
        try collection.validate(at: temp)
        #expect(Set(collection.endpoints.map(\.id)).count == 3)
    }

    @Test func compareReportsNestedChangesAndIgnoresFormatting() {
        #expect(APICollection.differences("HTTP 200\n\n{\"items\":[1]}", "HTTP 200\n\n{\"items\":[2]}").contains("$.items[0]"))
        #expect(APICollection.differences("a\n\n{ \"a\": 1 }", "b\n\n{\"a\":1}") == "JSON values match.")
    }
}
