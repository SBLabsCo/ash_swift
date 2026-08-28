import Foundation

/// A single error object as returned by the backend in a failure envelope
/// (`{"success": false, "errors": [...]}`).
///
/// The fields mirror the map an `AshTypescript.Rpc.Error` implementation
/// returns, with the keys in the camelCase form the backend's output formatter
/// puts on the wire. Every field is optional: which of them an error carries
/// varies by error class, so this is the lenient decode-boundary view.
///
/// `vars` is where a typed refusal's *data* lives — the values a client needs to
/// say something specific about the refusal rather than reading the same numbers
/// back from elsewhere in the API. Its keys go through the same output formatter
/// as the rest of the response, so a multi-word var key arrives camelCased
/// (`max_length` on the server is `maxLength` here).
///
/// ```swift
/// } catch let AshRpcError.server(errors) {
///     if let quota = errors.first(where: { $0.type == "video_quota_exceeded" }),
///        case .number(let limit)? = quota.vars?["limit"] {
///         show("You've used all \(Int(limit)) of your videos")
///     }
/// }
/// ```
public struct AshRpcServerError: Codable, Sendable, Equatable {
    /// Machine-readable error code — the value to branch on (`"required"`,
    /// `"video_quota_exceeded"`).
    public let type: String?

    /// The full message. May still contain `%{key}` placeholders: the backend
    /// leaves interpolation to the client, and `vars` holds the values.
    public let message: String?

    /// A concise version of `message`, suitable as a title.
    public let shortMessage: String?

    /// The error's payload — whatever the backend's `to_error/1` attached. An
    /// open map, so its values are the runtime's dynamic-JSON representation.
    public let vars: [String: AshJSON]?

    /// The field names an error applies to, for field-level errors.
    public let fields: [String]?

    /// The path to the error's location in a nested input.
    public let path: [String]?

    /// Extra context (suggestions, hints) that pipeline-level errors attach.
    public let details: [String: AshJSON]?

    public init(
        type: String? = nil,
        message: String? = nil,
        shortMessage: String? = nil,
        vars: [String: AshJSON]? = nil,
        fields: [String]? = nil,
        path: [String]? = nil,
        details: [String: AshJSON]? = nil
    ) {
        self.type = type
        self.message = message
        self.shortMessage = shortMessage
        self.vars = vars
        self.fields = fields
        self.path = path
        self.details = details
    }

    /// Decodes per field rather than all-or-nothing: a field whose shape we
    /// don't expect becomes `nil` instead of throwing. This decode is what turns
    /// a `success: false` body into `AshRpcError.server`, so a throw here would
    /// surface as `decodingFailed` and lose the refusal the caller has to handle.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        func string(_ key: CodingKeys) -> String? {
            (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil
        }

        func object(_ key: CodingKeys) -> [String: AshJSON]? {
            (try? container.decodeIfPresent([String: AshJSON].self, forKey: key)) ?? nil
        }

        // `fields` and `path` are arrays of names, but a path into a nested
        // input carries list indices as JSON numbers — decoding straight to
        // `[String]` would drop the whole path in exactly the nested case where
        // it matters most. Decode dynamically and stringify the scalars.
        func stringArray(_ key: CodingKeys) -> [String]? {
            guard let raw = (try? container.decodeIfPresent([AshJSON].self, forKey: key)) ?? nil
            else { return nil }

            var segments: [String] = []
            segments.reserveCapacity(raw.count)
            for value in raw {
                switch value {
                case .string(let s): segments.append(s)
                case .number(let n): segments.append(Self.segmentString(n))
                case .bool(let b): segments.append(String(b))
                // A composite segment has no sensible string form, and dropping
                // just that one would silently misreport the path — so the whole
                // array degrades to nil.
                case .null, .array, .object: return nil
                }
            }
            return segments
        }

        self.type = string(.type)
        self.message = string(.message)
        self.shortMessage = string(.shortMessage)
        self.vars = object(.vars)
        self.fields = stringArray(.fields)
        self.path = stringArray(.path)
        self.details = object(.details)
    }

    /// Renders a numeric path segment as a list index (`0`) rather than a
    /// Double's default spelling (`0.0`) when it is integral.
    private static func segmentString(_ value: Double) -> String {
        // `Int(exactly:)` already rejects a non-integral (or out-of-range) value.
        if let index = Int(exactly: value) { return String(index) }
        return String(value)
    }
}

/// Every failure the runtime can surface, thrown so callers handle them with
/// `do`/`catch` (ADR-0004).
public enum AshRpcError: Error, Sendable {
    /// The response was not an `HTTPURLResponse`.
    case invalidResponse

    /// A non-2xx HTTP status. Carries the status code and raw body.
    case httpStatus(code: Int, body: Data)

    /// The backend returned `{"success": false, "errors": [...]}`.
    case server(errors: [AshRpcServerError])

    /// The response body could not be decoded into the expected shape.
    case decodingFailed(description: String)
}
