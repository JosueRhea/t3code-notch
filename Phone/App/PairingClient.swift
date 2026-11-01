import Foundation
import Network

/// Finds the Mac's pairing listener on the local network (Bonjour), sends the code and this
/// phone's push-to-start token, and reads the answer. Used once; after that the Mac reaches the
/// phone through Apple's push service from anywhere.
final class PairingClient {
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var finished = false
    private let queue = DispatchQueue(label: "pairing")

    func pair(_ request: PairingRequest, completion: @escaping (Result<PairingReply, Error>) -> Void) {
        let done: (Result<PairingReply, Error>) -> Void = { [weak self] result in
            guard let self, !self.finished else { return }
            self.finished = true
            self.browser?.cancel()
            self.connection?.cancel()
            DispatchQueue.main.async { completion(result) }
        }
        let browser = NWBrowser(for: .bonjour(type: LiveActivityProtocol.bonjourType, domain: nil), using: .tcp)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.connection == nil, let result = results.first else { return }
            self.send(request, to: result.endpoint, done: done)
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state { done(.failure(error)) }
        }
        browser.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 12) {
            done(.failure(PairingError("Couldn't find your Mac. Open “Pair iPhone…” in T3 Notch's menu, and be on the same Wi-Fi.")))
        }
    }

    private func send(_ request: PairingRequest, to endpoint: NWEndpoint, done: @escaping (Result<PairingReply, Error>) -> Void) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                var data = (try? JSONEncoder().encode(request)) ?? Data()
                data.append(0x0A)
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error { done(.failure(error)) }
                })
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                    if let data, let line = data.split(separator: 0x0A).first,
                       let reply = try? JSONDecoder().decode(PairingReply.self, from: Data(line)) {
                        done(.success(reply))
                    } else {
                        done(.failure(error ?? PairingError("The Mac didn't answer.")))
                    }
                }
            case .failed(let error):
                done(.failure(error))
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
}

struct PairingError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
