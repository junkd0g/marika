import Foundation
import MarikaCore
import Observation

@MainActor @Observable final class ContainerForward {
    let name: String
    let port: Int
    var ready = false
    var running = true
    var output = ""
    @ObservationIgnored private var process: ProcessGroup?
    init(name: String, port: Int) { self.name = name; self.port = port }
    func start(_ launch: ContainerProcessLaunch) throws {
        let group = ProcessGroup(output: { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                self.output = String((self.output + String(decoding: data, as: UTF8.self)).suffix(6_000))
                if self.output.contains("Forwarding from 127.0.0.1:") { self.ready = true }
            }
        }, completion: { [weak self] _ in Task { @MainActor in self?.running = false; self?.ready = false } })
        process = group; try launch.start(group)
    }
    func stop() { process?.stop(); process = nil; running = false; ready = false }
}
