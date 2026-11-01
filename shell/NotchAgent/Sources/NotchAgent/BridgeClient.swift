import Foundation

/// Somewhere the notch sends messages: a socket, or a recorder in the tests.
@MainActor
protocol MessageSink: AnyObject {
    func send(_ payload: [String: Any])
}

/// Talks to the Python backend over ws://127.0.0.1:8765, reconnecting on its own
/// so a backend restart never takes the notch down with it.
@MainActor
final class BridgeClient: MessageSink {
    private let url: URL
    private var task: URLSessionWebSocketTask?
    private var session: URLSession!
    private var reconnectDelay: TimeInterval = 0.5
    private var stopped = false

    var onMessage: (([String: Any]) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?

    init(url: URL = Ports.backend) {
        self.url = url
        self.session = URLSession(configuration: .default)
    }

    func connect() {
        stopped = false
        var request = URLRequest(url: url)
        request.setValue("Bearer \(BridgeToken.read)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        receive()
        // The socket reports failure only on the first receive, so probe it.
        task.sendPing { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.handleDrop(error)
                } else {
                    self.reconnectDelay = 0.5
                    self.onConnectionChange?(true)
                }
            }
        }
    }

    func disconnect() {
        stopped = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    func send(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.handleDrop(error)
                case .success(let message):
                    if case .string(let text) = message,
                       let data = text.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.onMessage?(obj)
                    }
                    self.receive()
                }
            }
        }
    }

    private func handleDrop(_ error: Error) {
        guard !stopped else { return }
        onConnectionChange?(false)
        task?.cancel()
        task = nil
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 5)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }
}
