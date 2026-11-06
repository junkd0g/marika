import Foundation
import MarikaCore

@main
struct MarikaBrowserMCP {
    static func main() async {
        let environment = ProcessInfo.processInfo.environment
        while let line = readLine() {
            guard let request = try? JSONValue(parsing: Data(line.utf8)), let id = request["id"] else { continue }
            let result: JSONValue
            switch request["method"]?.string {
            case "initialize":
                result = ["protocolVersion": request["params"]?["protocolVersion"] ?? "2024-11-05",
                          "capabilities": ["tools": [:]], "serverInfo": ["name": "marika-browser", "version": "0.1.0"],
                          "instructions": .string(BrowserTools.instructions + "\n\n" + AgentTaskTools.instructions)]
            case "ping": result = [:]
            case "tools/list": result = ["tools": .array(BrowserTools.definitions + AgentTaskTools.definitions)]
            case "resources/list": result = ["resources": []]
            case "prompts/list": result = ["prompts": []]
            case "tools/call": result = await call(request["params"] ?? [:], environment: environment)
            default:
                write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Unknown method"]])
                continue
            }
            write(["jsonrpc": "2.0", "id": id, "result": result])
        }
    }

    private static func call(_ params: JSONValue, environment: [String: String]) async -> JSONValue {
        guard let endpoint = environment["MARIKA_BROWSER_ENDPOINT"].flatMap(URL.init(string:)),
            endpoint.scheme == "http", endpoint.host == "127.0.0.1", endpoint.path == "/browser",
            let token = environment["MARIKA_BROWSER_TOKEN"], !token.isEmpty
        else { return BrowserTools.text("The Marika browser connection is unavailable. Reopen the agent session.", error: true) }
        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 40
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try params.serialized()
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw BrowserError.message("Browser connection rejected the request.") }
            return try JSONValue(parsing: data)
        } catch { return BrowserTools.text("Browser tool failed: \(error.localizedDescription)", error: true) }
    }

    private static func write(_ value: JSONValue) {
        guard var data = try? value.serialized() else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}
