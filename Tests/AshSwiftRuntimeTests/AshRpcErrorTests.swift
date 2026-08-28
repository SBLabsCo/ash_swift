import Foundation
import XCTest
@testable import AshSwiftRuntime

/// Decode-boundary tests for `AshRpcServerError`. A typed refusal's payload —
/// its `vars` — is the reason a client can say anything specific about the
/// refusal, so these pin the full error shape the RPC pipeline emits and the
/// leniency that keeps an unexpected shape from failing the whole envelope.
final class AshRpcErrorTests: XCTestCase {
    private func decode(_ json: String) throws -> AshRpcServerError {
        try JSONDecoder().decode(AshRpcServerError.self, from: Data(json.utf8))
    }

    // The shape an `AshTypescript.Rpc.Error` impl returns, in the camelCase form
    // the backend's output formatter puts on the wire. Modeled on the quota
    // refusal from issue #81: the counts live in `vars`.
    func testDecodesFullErrorShape() throws {
        let error = try decode(#"""
        {
          "type": "video_quota_exceeded",
          "message": "Video limit of %{limit} reached",
          "shortMessage": "Video limit reached",
          "vars": {"limit": 10, "created": 10},
          "fields": ["videos"],
          "path": ["account"],
          "details": {"suggestion": "Upgrade your plan"}
        }
        """#)

        XCTAssertEqual(error.type, "video_quota_exceeded")
        XCTAssertEqual(error.message, "Video limit of %{limit} reached")
        XCTAssertEqual(error.shortMessage, "Video limit reached")
        XCTAssertEqual(error.vars, ["limit": .number(10), "created": .number(10)])
        XCTAssertEqual(error.fields, ["videos"])
        XCTAssertEqual(error.path, ["account"])
        XCTAssertEqual(error.details, ["suggestion": .string("Upgrade your plan")])
    }

    // Plenty of error shapes carry only a subset of the fields, so every one is
    // optional and an absent key decodes as nil rather than failing.
    func testAbsentFieldsDecodeAsNil() throws {
        let error = try decode(#"{"type":"unauthorized","message":"not allowed"}"#)

        XCTAssertEqual(error.type, "unauthorized")
        XCTAssertNil(error.shortMessage)
        XCTAssertNil(error.vars)
        XCTAssertNil(error.fields)
        XCTAssertNil(error.path)
        XCTAssertNil(error.details)
    }

    // `vars` is an open map: its values are whatever the error put there, so it
    // decodes to the runtime's dynamic-JSON representation.
    func testVarsCarryAnyJSONValue() throws {
        let error = try decode(#"""
        {"vars":{"s":"a","n":1.5,"b":true,"nul":null,"arr":[1],"obj":{"k":"v"}}}
        """#)

        XCTAssertEqual(error.vars?["s"], .string("a"))
        XCTAssertEqual(error.vars?["n"], .number(1.5))
        XCTAssertEqual(error.vars?["b"], .bool(true))
        XCTAssertEqual(error.vars?["nul"], .null)
        XCTAssertEqual(error.vars?["arr"], .array([.number(1)]))
        XCTAssertEqual(error.vars?["obj"], .object(["k": .string("v")]))
    }

    // A nested input's path carries list indices as numbers. Stringifying them
    // keeps the path usable instead of discarding it.
    func testPathStringifiesNumericSegments() throws {
        let error = try decode(#"{"path":["rows",0,"label"]}"#)

        XCTAssertEqual(error.path, ["rows", "0", "label"])
    }

    // A field whose shape we don't expect degrades to nil. It must not throw:
    // the envelope decode is what turns a `success: false` body into
    // `AshRpcError.server`, and a throw there would surface as `decodingFailed`
    // instead — losing the refusal the caller needs to handle.
    func testUnexpectedFieldShapesDegradeToNil() throws {
        let error = try decode(#"""
        {"type":42,"message":"real","vars":[],"fields":"videos","path":[{"a":1}],"details":7}
        """#)

        XCTAssertNil(error.type)
        XCTAssertEqual(error.message, "real")
        XCTAssertNil(error.vars)
        XCTAssertNil(error.fields)
        XCTAssertNil(error.path)
        XCTAssertNil(error.details)
    }

    // Round-trips through Encodable: nil fields are omitted, present ones keep
    // their wire key.
    func testEncodesOnlyPresentFields() throws {
        let error = AshRpcServerError(
            type: "required",
            message: "is required",
            shortMessage: "Required field",
            vars: ["field": .string("title")],
            fields: ["title"]
        )

        let data = try JSONEncoder().encode(error)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["shortMessage"] as? String, "Required field")
        XCTAssertEqual(object["vars"] as? [String: String], ["field": "title"])
        XCTAssertNil(object["path"])
        XCTAssertNil(object["details"])
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(try decode(encoded), error)
    }
}
