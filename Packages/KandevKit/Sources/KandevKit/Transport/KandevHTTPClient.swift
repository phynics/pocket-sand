import Foundation

/// The HTTP half of the Kandev API.
///
/// `/ws` carries most of the API, but not the flat task list and not the session
/// list for a task — the first-party client fetches those over HTTP. This type
/// exists so callers never have to know which transport a given piece of data
/// comes from.
public actor KandevHTTPClient {
    public struct Configuration: Sendable {
        public var baseURL: URL
        public var token: String?

        public init(baseURL: URL, token: String? = nil) {
            self.baseURL = baseURL
            self.token = token
        }
    }

    private let configuration: Configuration
    private let session: URLSession

    public init(configuration: Configuration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    public func get<Response: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
        as type: Response.Type = Response.self
    ) async throws -> Response {
        let data = try await self.data(path, query: query)
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw KandevError.malformedFrame(
                "\(path) did not match \(Response.self): \(error)"
            )
        }
    }

    /// Sends a body and decodes the answer.
    public func post<Response: Decodable>(
        _ path: String,
        body: JSONValue,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        let data = try await self.data(path, query: [], method: "POST", body: body)
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw KandevError.malformedFrame("\(path) did not match \(Response.self): \(error)")
        }
    }

    /// Sends a body with query parameters, where the answer carries nothing this
    /// client needs. Archive and delete take their options as query flags.
    public func post(_ path: String, query: [URLQueryItem], body: JSONValue? = nil) async throws {
        _ = try await self.data(path, query: query, method: "POST", body: body)
    }

    /// Sends a DELETE with query parameters and any headers the route needs.
    public func delete(
        _ path: String,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:]
    ) async throws {
        _ = try await self.data(path, query: query, method: "DELETE", headers: headers)
    }

    /// Sends a body where the answer carries nothing this client needs.
    ///
    /// Not every route answers with the object it changed, and a caller that
    /// reads the object back from the source of truth does not need it to.
    public func post(_ path: String, body: JSONValue) async throws {
        _ = try await self.data(path, query: [], method: "POST", body: body)
    }

    private func data(
        _ path: String,
        query: [URLQueryItem],
        method: String = "GET",
        headers: [String: String] = [:],
        body: JSONValue? = nil
    ) async throws -> Data {
        guard var components = URLComponents(
            url: configuration.baseURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw KandevError.invalidBaseURL(configuration.baseURL.absoluteString)
        }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw KandevError.invalidBaseURL(configuration.baseURL.absoluteString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        if let token = configuration.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw KandevError.malformedFrame("\(path) returned no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw KandevError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8)
            )
        }
        return data
    }
}
