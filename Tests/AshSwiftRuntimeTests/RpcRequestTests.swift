import Foundation
import XCTest
@testable import AshSwiftRuntime

/// Pure tests for the request values behind `execute`. `makeBody()` is a pure
/// function, so the wire-body construction that used to be buried in the
/// client's private methods is now testable without a transport. Each test
/// encodes the body and asserts on the resulting JSON — the actual wire contract.
final class RpcRequestTests: XCTestCase {
    private func encodedBody<R: RpcRequest>(_ request: R) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request.makeBody())
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: makeBody

    func testListRequestBodyCarriesActionAndFields() throws {
        let json = try encodedBody(ListRequest<Stub>(action: "list_todos", fields: ["id", "title"]))
        XCTAssertEqual(json["action"] as? String, "list_todos")
        XCTAssertEqual(json["fields"] as? [String], ["id", "title"])
    }

    func testGetRequestOmitsEmptyLookupDicts() throws {
        let json = try encodedBody(GetRequest<Stub>(action: "get_todo"))
        XCTAssertEqual(json["action"] as? String, "get_todo")
        XCTAssertNil(json["input"], "empty input dict must be omitted from the JSON")
        XCTAssertNil(json["getBy"], "empty getBy dict must be omitted from the JSON")
    }

    func testGetRequestIncludesInputWhenPresent() throws {
        let json = try encodedBody(GetRequest<Stub>(action: "get_todo", input: ["id": "abc"]))
        let input = try XCTUnwrap(json["input"] as? [String: String])
        XCTAssertEqual(input["id"], "abc")
        XCTAssertNil(json["getBy"], "unused getBy dict must still be omitted")
    }

    func testGetRequestIncludesGetByWhenPresent() throws {
        let json = try encodedBody(GetRequest<Stub>(action: "get_todo", getBy: ["slug": "milk"]))
        let getBy = try XCTUnwrap(json["getBy"] as? [String: String])
        XCTAssertEqual(getBy["slug"], "milk")
        XCTAssertNil(json["input"], "unused input dict must still be omitted")
    }

    func testOffsetPageRequestOmitsPageWhenNil() throws {
        let json = try encodedBody(OffsetPageRequest<Stub>(action: "list_todos_offset"))
        XCTAssertNil(json["page"], "nil page must be omitted so the backend uses its default")
    }

    func testOffsetPageRequestCarriesPageParams() throws {
        let json = try encodedBody(
            OffsetPageRequest<Stub>(action: "list_todos_offset", page: OffsetPageParams(limit: 5, offset: 10))
        )
        let page = try XCTUnwrap(json["page"] as? [String: Any])
        XCTAssertEqual(page["limit"] as? Int, 5)
        XCTAssertEqual(page["offset"] as? Int, 10)
    }

    func testCreateRequestBodyCarriesInput() throws {
        let json = try encodedBody(CreateRequest<Stub, StubInput>(action: "create_todo", input: StubInput(title: "New")))
        XCTAssertEqual(json["action"] as? String, "create_todo")
        let input = try XCTUnwrap(json["input"] as? [String: Any])
        XCTAssertEqual(input["title"] as? String, "New")
    }

    func testUpdateRequestBodyCarriesIdentityAndInput() throws {
        let json = try encodedBody(
            UpdateRequest<Stub, StubInput>(action: "update_todo", identity: "uuid-1", input: StubInput(title: "Edit"))
        )
        XCTAssertEqual(json["identity"] as? String, "uuid-1")
        let input = try XCTUnwrap(json["input"] as? [String: Any])
        XCTAssertEqual(input["title"] as? String, "Edit")
    }

    func testDestroyRequestBodyCarriesIdentityOnly() throws {
        let json = try encodedBody(DestroyRequest(action: "destroy_todo", identity: "uuid-9"))
        XCTAssertEqual(json["action"] as? String, "destroy_todo")
        XCTAssertEqual(json["identity"] as? String, "uuid-9")
        XCTAssertNil(json["fields"], "destroy carries no field selection")
    }

    // MARK: decode

    func testDataEnvelopeRequestUnwrapsDataKey() throws {
        let data = Data(#"{"data":[{"id":"1"},{"id":"2"}]}"#.utf8)
        let items = try ListRequest<Stub>(action: "list_todos").decode(from: data, using: JSONDecoder())
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.last?.id, "2")
    }
}

private struct Stub: Decodable, Sendable {
    let id: String?
}

private struct StubInput: Encodable, Sendable {
    let title: String
}
