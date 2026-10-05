import Foundation
import KandevKit

/// Sends arbitrary action frames to a live Kandev server and prints what comes
/// back, so payload shapes are read off the wire instead of guessed.
///
///     echo '[{"action":"workspace.list","payload":{}}]' | swift run kandev-probe http://kandev.local:38429
///
/// Arguments: `<baseURL> [--token <pat>] [--listen <seconds>]`
/// Input: a JSON array (or single object) of `{"action": ..., "payload": ...}`
@main
struct KandevProbe {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let rawBaseURL = arguments.first, let baseURL = URL(string: rawBaseURL) else {
            FileHandle.standardError.write(Data("usage: kandev-probe <baseURL> [--token <pat>] [--listen <seconds>]\n".utf8))
            exit(2)
        }

        let token = value(after: "--token", in: arguments)
        let listenSeconds = value(after: "--listen", in: arguments).flatMap(Double.init) ?? 0

        let requests: [ProbeRequest]
        do {
            requests = try readRequests()
        } catch {
            FileHandle.standardError.write(Data("could not read requests: \(error)\n".utf8))
            exit(2)
        }

        let transport = WebSocketTransport(
            configuration: .init(baseURL: baseURL, token: token)
        )

        do {
            try await transport.connect()
            print("connected to \(try KandevEndpoint.webSocketURL(baseURL: baseURL, token: nil).absoluteString)")
        } catch {
            FileHandle.standardError.write(Data("connect failed: \(error)\n".utf8))
            exit(1)
        }

        if listenSeconds > 0 {
            Task {
                for await envelope in transport.notifications {
                    print("\n<<< notification \(envelope.action ?? "(none)")")
                    print(encode(envelope))
                }
            }
        }

        for request in requests {
            print("\n>>> \(request.action)")
            do {
                let response = try await transport.send(
                    .request(action: request.action, payload: request.payload)
                )
                print("<<< response \(response.action ?? "(none)")")
                print(encode(response))
            } catch {
                print("!!! \(error)")
            }
        }

        if listenSeconds > 0 {
            print("\nlistening for \(listenSeconds)s...")
            try? await Task.sleep(for: .seconds(listenSeconds))
        }

        await transport.close()
    }

    private static func readRequests() throws -> [ProbeRequest] {
        let data = try FileHandle.standardInput.readToEnd() ?? Data()
        let trimmed = data.drop { $0 == 0x0A || $0 == 0x20 }
        guard !trimmed.isEmpty else { return [] }

        let decoder = JSONDecoder()
        if let list = try? decoder.decode([ProbeRequest].self, from: data) {
            return list
        }
        return [try decoder.decode(ProbeRequest.self, from: data)]
    }

    private static func encode(_ envelope: KandevEnvelope) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(envelope),
              let text = String(data: data, encoding: .utf8)
        else { return "(unencodable)" }
        return text
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

private struct ProbeRequest: Decodable {
    var action: String
    var payload: JSONValue?
}
