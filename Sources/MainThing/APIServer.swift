import Foundation
import Network
import MainThingCore
import os

/// Loopback HTTP server on the main queue. One listener for 127.0.0.1, one for ::1.
/// Tries port 80 first, then 7788 when 80 is taken or refused (see `APIPort`). Both listeners
/// must come up on the same port; if either fails the pair is dropped and the next port is tried.
@MainActor
final class APIServer {
    /// The port in use, or the one being tried. Settled once `onStatus` has fired.
    private(set) var port: UInt16
    let candidates: [UInt16]
    private var remaining: ArraySlice<UInt16>
    private let store: TaskStore
    private let log = Logger(subsystem: MainThingBundleID, category: "server")
    private var listeners: [NWListener] = []
    private var ready: Set<String> = []
    /// Bumped on every port attempt, so a late state update from a dropped listener is ignored.
    private var attempt = 0
    private var connections: [ObjectIdentifier: ClientConnection] = [:]
    /// Called with true and the port once both listeners are up, false when every candidate failed.
    var onStatus: (@MainActor (Bool, UInt16) -> Void)?

    /// `defaults write <bundle id> port 7799` pins the port. `MAINTHING_PORT` in the environment
    /// overrides both, for a second copy in tests. Without either: 80, then 7788.
    static func configuredPorts(_ defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment) -> [UInt16] {
        APIPort.candidates(environment: environment["MAINTHING_PORT"], defaultsValue: defaults.integer(forKey: "port"))
    }

    init(store: TaskStore, ports: [UInt16] = APIServer.configuredPorts()) {
        self.store = store
        self.candidates = ports.isEmpty ? [APIPort.fallback] : ports
        self.remaining = self.candidates[...]
        self.port = self.candidates[0]
    }

    func start() {
        tryNextPort()
    }

    private func tryNextPort() {
        for listener in listeners { listener.stateUpdateHandler = nil; listener.cancel() }
        listeners = []
        ready = []
        attempt += 1
        guard let next = remaining.first else {
            log.error("no port left to try: \(self.candidates.map(String.init).joined(separator: ", "), privacy: .public)")
            onStatus?(false, port)
            return
        }
        remaining = remaining.dropFirst()
        port = next
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
            portFailed()
            return
        }

        let attempt = self.attempt
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.attempt == attempt else { return }
                switch state {
                case .ready:
                    self.log.info("listening on \(label, privacy: .public):\(self.port, privacy: .public)")
                    self.ready.insert(label)
                    if self.ready.count == 2 {
                        self.log.notice("api on port \(self.port, privacy: .public)")
                        self.onStatus?(true, self.port)
                    }
                case .failed(let error):
                    self.log.error("bind failed on \(label, privacy: .public):\(self.port, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    self.portFailed()
                case .cancelled:
                    self.log.notice("listener on \(label, privacy: .public):\(self.port, privacy: .public) cancelled")
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

    /// One listener of the pair failed: drop both and move to the next port.
    private func portFailed() {
        if let next = remaining.first {
            log.notice("port \(self.port, privacy: .public) is not available, trying \(next, privacy: .public)")
        }
        tryNextPort()
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
        let response = store.handle(request, port: port)
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
