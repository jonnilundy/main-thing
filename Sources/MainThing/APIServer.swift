import Foundation
import Network
import MainThingCore
import os

/// Loopback HTTP server on the main queue. One listener for 127.0.0.1, one for ::1.
@MainActor
final class APIServer {
    static let defaultPort: UInt16 = 7788

    let port: UInt16
    private let store: TaskStore
    private let log = Logger(subsystem: MainThingBundleID, category: "server")
    private var listeners: [NWListener] = []
    private var connections: [ObjectIdentifier: ClientConnection] = [:]
    /// Called with true when 127.0.0.1 is bound, false when the bind fails.
    var onStatus: (@MainActor (Bool) -> Void)?

    /// `defaults write com.jonnilundy.mainthing port 7799` overrides the port. `MAINTHING_PORT` in
    /// the environment overrides both, for a second copy in tests.
    static func configuredPort(_ defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment) -> UInt16 {
        if let raw = environment["MAINTHING_PORT"], let value = Int(raw), (1...65535).contains(value) {
            return UInt16(value)
        }
        let value = defaults.integer(forKey: "port")
        return (1...65535).contains(value) ? UInt16(value) : defaultPort
    }

    init(store: TaskStore, port: UInt16 = APIServer.configuredPort()) {
        self.store = store
        self.port = port
    }

    func start() {
        startListener(host: .ipv4(.loopback), label: "127.0.0.1")
        startListener(host: .ipv6(.loopback), label: "[::1]")
    }

    private func startListener(host: NWEndpoint.Host, label: String) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: host, port: nwPort)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            log.error("listener setup failed on \(label, privacy: .public):\(self.port, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    self.log.info("listening on \(label, privacy: .public):\(self.port, privacy: .public)")
                    if label == "127.0.0.1" { self.onStatus?(true) }
                case .failed(let error):
                    self.log.error("bind failed on \(label, privacy: .public):\(self.port, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    if label == "127.0.0.1" { self.onStatus?(false) }
                case .cancelled:
                    self.log.notice("listener on \(label, privacy: .public) cancelled")
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                self?.accept(connection)
            }
        }
        listener.start(queue: .main)
        listeners.append(listener)
    }

    private func accept(_ connection: NWConnection) {
        let client = ClientConnection(
            connection,
            handler: { [weak self] request in
                self?.handle(request) ?? .error(500, "server is gone")
            },
            onClose: { [weak self] client in
                self?.connections.removeValue(forKey: ObjectIdentifier(client))
            }
        )
        connections[ObjectIdentifier(client)] = client
        client.start()
    }

    private func handle(_ request: HTTPRequest) -> HTTPResponse {
        let response = store.handle(request)
        if response.status >= 400 {
            log.notice("rejected \(request.method, privacy: .public) \(request.path, privacy: .public): \(response.status, privacy: .public) \(response.bodyText, privacy: .public)")
        }
        return response
    }
}

/// One TCP connection: read one request, write one response, close.
@MainActor
final class ClientConnection {
    private let connection: NWConnection
    private let handler: @MainActor (HTTPRequest) -> HTTPResponse
    private let onClose: @MainActor (ClientConnection) -> Void
    private var parser = HTTPRequestParser()
    private var closed = false

    init(
        _ connection: NWConnection,
        handler: @escaping @MainActor (HTTPRequest) -> HTTPResponse,
        onClose: @escaping @MainActor (ClientConnection) -> Void
    ) {
        self.connection = connection
        self.handler = handler
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                if case .failed = state { self?.close() }
            }
        }
        connection.start(queue: .main)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                if error != nil {
                    self.close()
                    return
                }
                var step = HTTPRequestParser.Step.needMore
                if let data, !data.isEmpty {
                    step = self.parser.feed(data)
                }
                switch step {
                case .needMore:
                    if isComplete { self.close() } else { self.receive() }
                case .request(let request):
                    self.respond(self.handler(request), drainFirst: false)
                case .failure(let response):
                    self.respond(response, drainFirst: true)
                }
            }
        }
    }

    private func respond(_ response: HTTPResponse, drainFirst: Bool) {
        connection.send(content: response.serialized(), completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if drainFirst {
                    self.drain(budget: 1_048_576)
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(2))
                        self?.close()
                    }
                } else {
                    self.close()
                }
            }
        })
    }

    /// After refusing a request early (413, 400 on the head), keep reading what the client
    /// is still sending so it gets the response instead of a connection reset.
    private func drain(budget: Int) {
        guard budget > 0 else {
            close()
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                if isComplete || error != nil {
                    self.close()
                    return
                }
                self.drain(budget: budget - (data?.count ?? 0))
            }
        }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose(self)
    }
}
