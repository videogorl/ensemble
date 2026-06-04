import Foundation

/// Immutable header context for Plex requests so URL/request assembly stays
/// separate from transport execution inside `PlexAPIClient`.
struct PlexRequestHeaderContext: Sendable {
    let clientIdentifier: String
    let productName: String
    let productVersion: String
    let platformName: String
    let deviceName: String

    func apply(to request: inout URLRequest, token: String, accept: String = "application/json") {
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        request.setValue(clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue(productName, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(productVersion, forHTTPHeaderField: "X-Plex-Version")
        request.setValue(platformName, forHTTPHeaderField: "X-Plex-Platform")
        request.setValue(deviceName, forHTTPHeaderField: "X-Plex-Device-Name")
        request.setValue(deviceName, forHTTPHeaderField: "X-Plex-Device")
        request.setValue("controller", forHTTPHeaderField: "X-Plex-Provides")
    }
}

/// Pure request-construction helper used by `PlexAPIClient` shared transport code.
/// It knows how to build Plex-authenticated URLs and headers but performs no I/O.
struct PlexRequestBuilder: Sendable {
    let baseURL: String
    let token: String
    let headerContext: PlexRequestHeaderContext

    func makeRequest(
        method: String,
        path: String,
        query: [String: String] = [:],
        includeTokenInQuery: Bool = true,
        accept: String = "application/json"
    ) throws -> URLRequest {
        guard var components = URLComponents(string: baseURL) else {
            throw PlexAPIError.invalidURL
        }

        components.path = path
        var queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        if includeTokenInQuery {
            queryItems.append(URLQueryItem(name: "X-Plex-Token", value: token))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let requestURL = components.url else {
            throw PlexAPIError.invalidURL
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        headerContext.apply(to: &request, token: token, accept: accept)
        return request
    }
}
