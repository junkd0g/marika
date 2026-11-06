import Foundation

public struct WorkspaceRuntime: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case ssh, container }
    public var kind: Kind
    public var target: String
    public var directory: String
    public init(kind: Kind, target: String, directory: String) { self.kind = kind; self.target = target; self.directory = directory }
    public func invocation(_ command: String, environment: [String: String]) throws -> (URL, [String]) {
        guard !target.isEmpty, !target.hasPrefix("-"), target.range(of: #"^[A-Za-z0-9_.@:-]+$"#, options: .regularExpression) != nil,
              directory.hasPrefix("/"), !directory.contains("\0") else { throw AgentError.launchFailed("Enter a valid host/container and absolute workspace path.") }
        let script = "cd " + Self.quote(directory) + " && " + command
        if kind == .ssh { return (URL(fileURLWithPath: "/usr/bin/ssh"), ["-T", "-o", "BatchMode=yes", "--", target, script]) }
        guard let docker = ShellEnvironment.locate("docker", in: environment) else { throw AgentError.launchFailed("Docker is not installed.") }
        return (docker, ["exec", "-i", target, "sh", "-lc", script])
    }
    public static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public func run(_ command: String, localRoot: URL, environment: [String: String], input: URL? = nil, timeout: Double = 30) async throws -> CommandResult {
        let (executable, args) = try invocation(command, environment: environment)
        return try await Command.run(executable, args, workingDirectory: localRoot, environment: environment, timeout: timeout, outputLimit: 8_000_000, inputFile: input)
    }
}

public protocol WorkspaceFiles: Actor {
    func entries(in path: String) async throws -> [ProjectFileEntry]
    func filePaths(limit: Int) async throws -> [String]
    func open(_ path: String) async throws -> ProjectFileContent
    func read(_ path: String) async throws -> TextFileSnapshot
    func preview(_ path: String) async throws -> FilePreviewSnapshot
    func write(_ text: String, replacing snapshot: TextFileSnapshot, overwrite: Bool) async throws -> TextFileSnapshot
}

public actor RemoteFiles: WorkspaceFiles {
    private let runtime: WorkspaceRuntime
    private let cache: URL
    private let environment: [String: String]
    public init(runtime: WorkspaceRuntime, cache: URL, environment: [String: String]) { self.runtime = runtime; self.cache = cache; self.environment = environment }
    private func request(_ operation: String, path: String = "", extra: [String: JSONValue] = [:]) async throws -> JSONValue {
        var payload: [String: JSONValue] = ["root": .string(runtime.directory), "op": .string(operation), "path": .string(path)]
        payload.merge(extra) { _, value in value }
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try JSONValue.object(payload).serialized().write(to: input, options: .atomic)
        defer { try? FileManager.default.removeItem(at: input) }
        let result = try await runtime.run("python3 -c " + WorkspaceRuntime.quote(Self.bridge), localRoot: cache, environment: environment, input: input)
        guard result.succeeded else { throw AgentError.launchFailed(result.errorOutput.isEmpty ? "Remote filesystem request failed." : result.errorOutput) }
        let response = try JSONValue(parsing: result.stdout)
        if let error = response["error"]?.string { throw AgentError.launchFailed(error) }
        return response
    }
    public func entries(in path: String = "") async throws -> [ProjectFileEntry] {
        let response = try await request("list", path: path)
        return (response.array ?? []).compactMap { value in
            guard let name = value["name"]?.string else { return nil }
            return ProjectFileEntry(path: path.isEmpty ? name : path + "/" + name, name: name, isDirectory: value["directory"]?.bool == true, isSymbolicLink: value["link"]?.bool == true)
        }.sorted { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public func filePaths(limit: Int = 20_000) async throws -> [String] {
        (try await request("paths", extra: ["limit": .int(Int64(limit))])).array?.compactMap(\.string) ?? []
    }
    private func download(_ path: String) async throws -> URL {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw ProjectFileError.outsideProject }
        let result = try await request("read", path: path)
        guard let encoded = result["data"]?.string, let data = Data(base64Encoded: encoded) else { throw ProjectFileError.notRegularFile }
        let url = cache.appendingPathComponent(path)
        guard url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(cache.standardizedFileURL.resolvingSymlinksInPath().path + "/") else { throw ProjectFileError.outsideProject }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return url
    }
    public func open(_ path: String) async throws -> ProjectFileContent { _ = try await download(path); return try await ProjectFiles(root: cache).open(path) }
    public func read(_ path: String) async throws -> TextFileSnapshot { _ = try await download(path); return try await ProjectFiles(root: cache).read(path) }
    public func preview(_ path: String) async throws -> FilePreviewSnapshot { _ = try await download(path); return try await ProjectFiles(root: cache).preview(path) }
    public func write(_ text: String, replacing snapshot: TextFileSnapshot, overwrite: Bool = false) async throws -> TextFileSnapshot {
        guard var data = text.data(using: snapshot.encoding) else { throw ProjectFileError.notText }
        if snapshot.hasUTF8BOM { data.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0) }
        guard data.count <= ProjectFiles.maxFileBytes else { throw ProjectFileError.tooLarge }
        _ = try await request("write", path: snapshot.path, extra: ["data": .string(data.base64EncodedString()), "expected": .string(snapshot.data.base64EncodedString()), "overwrite": .bool(overwrite)])
        return try await read(snapshot.path)
    }
    private static let bridge = #"""
import os,sys,json,base64,tempfile,stat
try:
 a=json.load(sys.stdin); root=os.path.realpath(a['root']); p=os.path.realpath(os.path.join(root,a['path']))
 if os.path.commonpath([root,p])!=root: raise Exception('Path outside remote workspace')
 skip={'.git','.build','node_modules','.swiftpm','__pycache__','.venv'}
 if a['op']=='list':
  out=[{'name':n,'directory':os.path.isdir(os.path.join(p,n)) and not os.path.islink(os.path.join(p,n)),'link':os.path.islink(os.path.join(p,n))} for n in os.listdir(p) if n not in skip]
 elif a['op']=='paths':
  out=[]
  for d,dirs,files in os.walk(root):
   dirs[:]=[n for n in dirs if n not in skip and not os.path.islink(os.path.join(d,n))]
   for n in files:
    out.append(os.path.relpath(os.path.join(d,n),root))
    if len(out)>=a['limit']: break
   if len(out)>=a['limit']: break
 elif a['op']=='read':
  if not os.path.isfile(p) or os.path.getsize(p)>5000000: raise Exception('Remote preview limit is 5 MB')
  out={'data':base64.b64encode(open(p,'rb').read()).decode()}
 elif a['op']=='write':
  expected=base64.b64decode(a['expected']); data=base64.b64decode(a['data'])
  if not a['overwrite'] and (not os.path.isfile(p) or open(p,'rb').read()!=expected): raise Exception('Remote file changed on disk; reload before saving')
  mode=os.stat(p).st_mode if os.path.exists(p) else 0o644
  fd,tmp=tempfile.mkstemp(dir=os.path.dirname(p))
  try:
   with os.fdopen(fd,'wb') as f: f.write(data); f.flush(); os.fsync(f.fileno())
   os.chmod(tmp,stat.S_IMODE(mode)); os.replace(tmp,p)
  finally:
   if os.path.exists(tmp): os.unlink(tmp)
  out={'saved':True}
 else: raise Exception('Unknown operation')
 print(json.dumps(out))
except Exception as e: print(json.dumps({'error':str(e)}))
"""#
}
