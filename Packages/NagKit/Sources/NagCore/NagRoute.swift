import Foundation

public enum NagRoute: Hashable, Sendable {
    case add(NagRequest)
    case newNag
    case nags
    case nag(UUID)
    case scan(taskID: UUID)
    case unlock(profileID: UUID)

    public init(url: URL, now: Date, calendar: Calendar) throws(NagRequestError) {
        guard NagRequest.isNagURL(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw .unsupportedURL }
        let action = (components.host ?? components.path)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        switch action {
        case "add", "new": self = .add(try NagRequest(url: url, now: now, calendar: calendar))
        case "new-nag", "newnag": self = .newNag
        case "nags": self = .nags
        case "nag": self = .nag(try Self.id(in: components))
        case "scan": self = .scan(taskID: try Self.id(in: components))
        case "unlock": self = .unlock(profileID: try Self.id(in: components))
        default: throw .unsupportedURL
        }
    }

    public var url: URL {
        switch self {
        case .add(let request):
            // Deliberately lossy: this convenience URL carries only the title.
            var components = URLComponents()
            components.scheme = NagRequest.urlScheme
            components.host = "add"
            components.queryItems = [URLQueryItem(name: "title", value: request.title)]
            return components.url!
        case .newNag: return URL(string: "nag://new-nag")!
        case .nags: return URL(string: "nag://nags")!
        case .nag(let id): return Self.url(host: "nag", id: id)
        case .scan(let taskID): return Self.url(host: "scan", id: taskID)
        case .unlock(let profileID): return Self.url(host: "unlock", id: profileID)
        }
    }

    private static func id(in components: URLComponents) throws(NagRequestError) -> UUID {
        let raw = components.queryItems?.first(where: { $0.name == "id" })?.value ?? ""
        guard let id = UUID(uuidString: raw) else { throw .invalidValue(parameter: "id", value: raw) }
        return id
    }

    private static func url(host: String, id: UUID) -> URL {
        var components = URLComponents()
        components.scheme = NagRequest.urlScheme
        components.host = host
        components.queryItems = [URLQueryItem(name: "id", value: id.uuidString)]
        return components.url!
    }
}
