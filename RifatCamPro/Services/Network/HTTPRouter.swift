import Foundation

// MARK: - HTTP Method

enum HTTPMethod: String, Sendable {
    case GET
    case POST
    case PUT
    case DELETE
    case PATCH
    case HEAD
}

// MARK: - HTTP Status Code

enum HTTPStatusCode: Int, Sendable {
    case ok = 200
    case created = 201
    case noContent = 204
    case badRequest = 400
    case unauthorized = 401
    case forbidden = 403
    case notFound = 404
    case methodNotAllowed = 405
    case internalServerError = 500
    case serviceUnavailable = 503

    var description: String {
        switch self {
        case .ok: return "OK"
        case .created: return "Created"
        case .noContent: return "No Content"
        case .badRequest: return "Bad Request"
        case .unauthorized: return "Unauthorized"
        case .forbidden: return "Forbidden"
        case .notFound: return "Not Found"
        case .methodNotAllowed: return "Method Not Allowed"
        case .internalServerError: return "Internal Server Error"
        case .serviceUnavailable: return "Service Unavailable"
        }
    }
}

// MARK: - HTTP Request

struct HTTPRequest: Sendable {
    let method: HTTPMethod
    let path: String
    let headers: [String: String]
    let body: Data?
    var queryParameters: [String: String] = [:]
    var pathParameters: [String: String] = [:]

    var contentType: String? {
        headers["content-type"]
    }

    var authorization: String? {
        headers["authorization"]
    }

    func jsonBody<T: Decodable>(_ type: T.Type) -> T? {
        guard let body = body else { return nil }
        return try? JSONDecoder().decode(type, from: body)
    }

    func jsonBodyDictionary() -> [String: Any]? {
        guard let body = body else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}

// MARK: - HTTP Response

struct HTTPResponse: Sendable {
    var statusCode: HTTPStatusCode
    var headers: [String: String]
    var body: Data?

    init(statusCode: HTTPStatusCode = .ok, headers: [String: String] = [:], body: Data? = nil) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    init(json: Any, statusCode: HTTPStatusCode = .ok) {
        self.statusCode = statusCode
        self.headers = ["Content-Type": "application/json"]
        if JSONSerialization.isValidJSONObject(json) {
            self.body = try? JSONSerialization.data(withJSONObject: json)
        } else {
            self.body = nil
        }
    }

    init<T: Encodable>(encodable: T, statusCode: HTTPStatusCode = .ok) {
        self.statusCode = statusCode
        self.headers = ["Content-Type": "application/json"]
        self.body = try? JSONEncoder().encode(encodable)
    }

    init(error: String, statusCode: HTTPStatusCode = .badRequest) {
        self.statusCode = statusCode
        self.headers = ["Content-Type": "application/json"]
        self.body = try? JSONSerialization.data(withJSONObject: ["error": error])
    }

    static func ok(json: Any) -> HTTPResponse {
        HTTPResponse(json: json, statusCode: .ok)
    }

    static func error(_ message: String, code: HTTPStatusCode = .badRequest) -> HTTPResponse {
        HTTPResponse(error: message, statusCode: code)
    }
}

// MARK: - Route Handler

typealias RouteHandler = @Sendable (HTTPRequest) async -> HTTPResponse

// MARK: - Route Definition

struct Route: Sendable {
    let method: HTTPMethod
    let pathPattern: String
    let handler: RouteHandler

    func matchComponents() -> [String] {
        pathPattern.split(separator: "/").map(String.init)
    }
}

// MARK: - HTTP Router

final class HTTPRouter: @unchecked Sendable {

    private var routes: [Route] = []
    private let lock = NSLock()

    func register(method: HTTPMethod, path: String, handler: @escaping RouteHandler) {
        lock.withLock {
            routes.append(Route(method: method, pathPattern: path, handler: handler))
        }
    }

    func get(_ path: String, handler: @escaping RouteHandler) {
        register(method: .GET, path: path, handler: handler)
    }

    func post(_ path: String, handler: @escaping RouteHandler) {
        register(method: .POST, path: path, handler: handler)
    }

    func put(_ path: String, handler: @escaping RouteHandler) {
        register(method: .PUT, path: path, handler: handler)
    }

    func delete(_ path: String, handler: @escaping RouteHandler) {
        register(method: .DELETE, path: path, handler: handler)
    }

    func route(_ request: HTTPRequest) async -> HTTPResponse {
        let requestPath = normalizePath(request.path)
        let requestComponents = requestPath.split(separator: "/").map(String.init)

        var matchedRoutes: [Route] = []

        lock.withLock {
            matchedRoutes = routes.filter { route in
                let patternComponents = route.matchComponents()
                return patternComponents.count == requestComponents.count
                    && methodsMatch(route.method, request.method)
                    && pathMatches(pattern: patternComponents, request: requestComponents)
            }
        }

        if matchedRoutes.isEmpty {
            let methodExists = lock.withLock {
                routes.contains { route in
                    let patternComponents = route.matchComponents()
                    return patternComponents.count == requestComponents.count
                        && pathMatches(pattern: patternComponents, request: requestComponents)
                }
            }

            if methodExists {
                return HTTPResponse(
                    error: "Method \(request.method.rawValue) not allowed for \(request.path)",
                    statusCode: .methodNotAllowed
                )
            }
            return HTTPResponse(
                error: "Endpoint not found: \(request.method.rawValue) \(request.path)",
                statusCode: .notFound
            )
        }

        let route = matchedRoutes[0]
        var mutableRequest = request
        mutableRequest.pathParameters = extractPathParameters(
            pattern: route.matchComponents(),
            request: requestComponents
        )

        return await route.handler(mutableRequest)
    }

    private func normalizePath(_ path: String) -> String {
        var normalized = path
        if let queryIndex = normalized.firstIndex(of: "?") {
            normalized = String(normalized[..<queryIndex])
        }
        if normalized.hasSuffix("/") && normalized.count > 1 {
            normalized = String(normalized.dropLast())
        }
        if !normalized.hasPrefix("/") {
            normalized = "/" + normalized
        }
        return normalized
    }

    private func methodsMatch(_ routeMethod: HTTPMethod, _ requestMethod: HTTPMethod) -> Bool {
        routeMethod == requestMethod
    }

    private func pathMatches(pattern: [String], request: [String]) -> Bool {
        for (patternComponent, requestComponent) in zip(pattern, request) {
            if patternComponent.hasPrefix(":") {
                continue
            }
            if patternComponent != requestComponent {
                return false
            }
        }
        return true
    }

    private func extractPathParameters(pattern: [String], request: [String]) -> [String: String] {
        var params: [String: String] = [:]
        for (patternComponent, requestComponent) in zip(pattern, request) {
            if patternComponent.hasPrefix(":") {
                let paramName = String(patternComponent.dropFirst())
                params[paramName] = requestComponent
            }
        }
        return params
    }
}

// MARK: - URL Parsing Utilities

enum URLParser {

    static func parseQueryParameters(from urlString: String) -> [String: String] {
        guard let queryIndex = urlString.firstIndex(of: "?") else {
            return [:]
        }
        let queryString = String(urlString[urlString.index(after: queryIndex)...])
        var params: [String: String] = [:]

        for pair in queryString.split(separator: "&") {
            let keyValue = pair.split(separator: "=", maxSplits: 1)
            if keyValue.count == 2 {
                let key = String(keyValue[0]).removingPercentEncoding ?? String(keyValue[0])
                let value = String(keyValue[1]).removingPercentEncoding ?? String(keyValue[1])
                params[key] = value
            } else if keyValue.count == 1 {
                let key = String(keyValue[0]).removingPercentEncoding ?? String(keyValue[0])
                params[key] = ""
            }
        }
        return params
    }

    static func parsePath(from urlString: String) -> String {
        if let queryIndex = urlString.firstIndex(of: "?") {
            return String(urlString[..<queryIndex])
        }
        return urlString
    }

    static func parseHeaders(from rawHeaders: String) -> [String: String] {
        var headers: [String: String] = [:]
        let lines = rawHeaders.components(separatedBy: "\r\n")
        for line in lines {
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }
        return headers
    }

    static func parseHTTP(from data: Data) -> (method: HTTPMethod, path: String, headers: [String: String], body: Data?)? {
        guard let raw = String(data: data, encoding: .utf8) else { return nil }

        let components = raw.components(separatedBy: "\r\n\r\n")
        guard let headerSection = components.first else { return nil }

        let headerLines = headerSection.components(separatedBy: "\r\n")
        guard let requestLine = headerLines.first else { return nil }

        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else { return nil }

        let methodString = String(requestParts[0])
        let path = String(requestParts[1])

        guard let method = HTTPMethod(rawValue: methodString) else { return nil }

        var headers: [String: String] = [:]
        if headerLines.count > 1 {
            let rawHeaders = headerLines[1...].joined(separator: "\r\n")
            headers = parseHeaders(from: rawHeaders)
        }

        let body: Data?
        if components.count > 1 {
            let bodyString = components[1...].joined(separator: "\r\n\r\n")
            body = bodyString.data(using: .utf8)
        } else {
            body = nil
        }

        return (method, path, headers, body)
    }
}
