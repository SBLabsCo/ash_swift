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

    // A pure get? read (issue #91) has no lookup channel: a bare request sends no
    // input/getBy (and the body has no identity field at all).
    func testGetRequestOmitsEmptyLookupDicts() throws {
        let json = try encodedBody(GetRequest<Stub>(action: "get_todo"))
        XCTAssertEqual(json["action"] as? String, "get_todo")
        XCTAssertNil(json["input"], "empty input dict must be omitted from the JSON")
        XCTAssertNil(json["getBy"], "empty getBy dict must be omitted from the JSON")
    }

    // Both get types build their body through the shared `GetRead`; pin that they
    // send the same request for the same inputs.
    func testGetAndGetOptionalRequestSendTheSameBody() throws {
        let args = AnyEncodable(StubInput(title: "x"))
        let required = try encodedBody(
            GetRequest<Stub>(action: "a", input: ["id": "1"], getBy: ["slug": "s"], arguments: args, fields: ["id"]))
        let optional = try encodedBody(
            GetOptionalRequest<Stub>(
                action: "a", input: ["id": "1"], getBy: ["slug": "s"], arguments: args, fields: ["id"]))
        XCTAssertEqual(NSDictionary(dictionary: required), NSDictionary(dictionary: optional))
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

    // Both paged types build their body through the shared `PagedBody`; pin the
    // body shape once and that each type sends the same body for the same inputs.
    func testPageRequestsShareBodyShape() throws {
        let input = AnyEncodable(StubInput(title: "x"))
        let filter = AnyEncodable(StubInput(title: "f"))
        let bare = try encodedBody(OffsetPageRequest<Stub>(action: "a"))
        XCTAssertNil(bare["page"], "nil page must be omitted so the backend uses its default")
        XCTAssertNil(bare["input"])
        XCTAssertNil(bare["sort"], "nil sort must be omitted")
        XCTAssertNil(bare["filter"], "nil filter must be omitted")

        let offset = try encodedBody(
            OffsetPageRequest<Stub>(
                action: "a", input: input, page: OffsetPageParams(limit: 5, offset: 10), filter: filter,
                sort: "-title", fields: ["id"]))
        XCTAssertEqual(offset["action"] as? String, "a")
        XCTAssertEqual(offset["fields"] as? [String], ["id"])
        XCTAssertEqual(offset["sort"] as? String, "-title")
        XCTAssertEqual(offset["input"] as? [String: String], ["title": "x"])
        XCTAssertEqual(offset["filter"] as? [String: String], ["title": "f"])
        let offsetPage = try XCTUnwrap(offset["page"] as? [String: Any])
        XCTAssertEqual(offsetPage["limit"] as? Int, 5)
        XCTAssertEqual(offsetPage["offset"] as? Int, 10)

        let keyset = try encodedBody(
            KeysetPageRequest<Stub>(
                action: "a", input: input, page: KeysetPageParams(limit: 5, after: "cursor"), filter: filter,
                sort: "-title", fields: ["id"]))
        let keysetPage = try XCTUnwrap(keyset["page"] as? [String: Any])
        XCTAssertEqual(keysetPage["limit"] as? Int, 5)
        XCTAssertEqual(keysetPage["after"] as? String, "cursor")
        // Everything but `page` must match, so a key added later is covered too.
        var offsetRest = offset
        offsetRest["page"] = nil
        var keysetRest = keyset
        keysetRest["page"] = nil
        XCTAssertEqual(NSDictionary(dictionary: offsetRest), NSDictionary(dictionary: keysetRest))

        let keysetBare = try encodedBody(KeysetPageRequest<Stub>(action: "a"))
        XCTAssertNil(keysetBare["page"])
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
        XCTAssertNil(json["input"], "an argument-less destroy omits input")
    }

    func testDestroyRequestBodyCarriesInputWhenGiven() throws {
        let json = try encodedBody(
            DestroyRequest(
                action: "archive_todo", identity: "uuid-9",
                input: AnyEncodable(StubInput(title: "why")))
        )
        XCTAssertEqual(json["action"] as? String, "archive_todo")
        XCTAssertEqual(json["identity"] as? String, "uuid-9")
        let input = try XCTUnwrap(json["input"] as? [String: Any])
        XCTAssertEqual(input["title"] as? String, "why")
    }

    func testGenericActionRequestBodyCarriesInput() throws {
        let json = try encodedBody(
            GenericActionRequest<Stub, StubInput>(action: "echo", input: StubInput(title: "hi"))
        )
        XCTAssertEqual(json["action"] as? String, "echo")
        let input = try XCTUnwrap(json["input"] as? [String: Any])
        XCTAssertEqual(input["title"] as? String, "hi")
        XCTAssertNil(json["fields"], "generic actions in this slice carry no field selection")
    }

    func testGenericActionRequestOmitsInputWhenNil() throws {
        // A no-argument action: `input` is nil and must not reach the wire.
        let json = try encodedBody(GenericActionRequest<Stub, EmptyActionInput>(action: "ping"))
        XCTAssertEqual(json["action"] as? String, "ping")
        XCTAssertNil(json["input"], "a no-arg generic action sends no input key")
    }

    func testVoidActionRequestBodyCarriesInput() throws {
        let json = try encodedBody(
            VoidActionRequest<StubInput>(action: "request_magic_link", input: StubInput(title: "a@b.com"))
        )
        XCTAssertEqual(json["action"] as? String, "request_magic_link")
        let input = try XCTUnwrap(json["input"] as? [String: Any])
        XCTAssertEqual(input["title"] as? String, "a@b.com")
    }

    func testVoidActionRequestOmitsInputWhenNil() throws {
        let json = try encodedBody(VoidActionRequest<EmptyActionInput>(action: "ping"))
        XCTAssertEqual(json["action"] as? String, "ping")
        XCTAssertNil(json["input"], "a no-arg void action sends no input key")
    }

    // Read-action arguments (issue #87).

    func testListRequestCarriesReadArgumentsUnderInput() throws {
        let json = try encodedBody(
            ListRequest<Stub>(action: "search", input: AnyEncodable(StubInput(title: "x")), fields: ["id"])
        )
        XCTAssertEqual(json["input"] as? [String: String], ["title": "x"])
    }

    func testListRequestOmitsInputWhenNil() throws {
        let json = try encodedBody(ListRequest<Stub>(action: "list_todos", fields: ["id"]))
        XCTAssertNil(json["input"], "a read without arguments sends no input key")
    }

    func testGetRequestMergesGetByLookupAndArgumentsIntoOneInputObject() throws {
        let json = try encodedBody(
            GetRequest<Stub>(
                action: "get_scoped",
                input: ["id": "1"],
                arguments: AnyEncodable(StubInput(title: "x")),
                fields: ["id"]
            )
        )
        XCTAssertEqual(json["input"] as? [String: String], ["id": "1", "title": "x"])
    }

    // Codegen keeps the key sets disjoint, but pin the documented tie-break: on an
    // overlap the lookup value (encoded last) wins and the key appears once.
    func testGetRequestLookupWinsOnOverlappingKey() throws {
        let json = try encodedBody(
            GetRequest<Stub>(
                action: "get_scoped",
                input: ["title": "lookup"],
                arguments: AnyEncodable(StubInput(title: "argument")),
                fields: ["id"]
            )
        )
        XCTAssertEqual(json["input"] as? [String: String], ["title": "lookup"])
    }

    func testGetRequestArgumentsAloneBecomeTheInputObject() throws {
        let json = try encodedBody(
            GetRequest<Stub>(
                action: "find_scoped",
                getBy: ["title": "t"],
                arguments: AnyEncodable(StubInput(title: "x")),
                fields: ["id"]
            )
        )
        XCTAssertEqual(json["getBy"] as? [String: String], ["title": "t"])
        XCTAssertEqual(json["input"] as? [String: String], ["title": "x"])
    }

    // MARK: decode

    func testGetOptionalRequestDecodesNullDataAsNil() throws {
        let request = GetOptionalRequest<Stub>(action: "fetch_todo")
        XCTAssertNil(try request.decode(from: Data(#"{"data":null}"#.utf8), using: JSONDecoder()))
        XCTAssertEqual(
            try request.decode(from: Data(#"{"data":{"id":"1"}}"#.utf8), using: JSONDecoder())?.id, "1")
    }

    func testGetRequestDecodesRecordAsNonOptional() throws {
        let record: Stub = try GetRequest<Stub>(action: "get_todo")
            .decode(from: Data(#"{"data":{"id":"1"}}"#.utf8), using: JSONDecoder())
        XCTAssertEqual(record.id, "1")
    }

    func testDataEnvelopeRequestUnwrapsDataKey() throws {
        let data = Data(#"{"data":[{"id":"1"},{"id":"2"}]}"#.utf8)
        let items = try ListRequest<Stub>(action: "list_todos").decode(from: data, using: JSONDecoder())
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.last?.id, "2")
    }

    func testGenericActionRequestDecodesOptionalRecordAndNull() throws {
        // A resource-returning generic action (`Stub?`): a selected record decodes,
        // `data: null` decodes to nil instead of throwing.
        let request = GenericActionRequest<Stub?, EmptyActionInput>(action: "summarize", fields: [.scalar("id")])
        XCTAssertEqual(
            try request.decode(from: Data(#"{"data":{"id":"1"}}"#.utf8), using: JSONDecoder())?.id, "1")
        XCTAssertNil(try request.decode(from: Data(#"{"data":null}"#.utf8), using: JSONDecoder()))
    }

    func testGenericActionRequestUnwrapsScalarData() throws {
        // A scalar-returning generic action unwraps the `data` key (here a String).
        let data = Data(#"{"data":"pong"}"#.utf8)
        let result = try GenericActionRequest<String, EmptyActionInput>(action: "ping")
            .decode(from: data, using: JSONDecoder())
        XCTAssertEqual(result, "pong")
    }

    func testVoidActionRequestDecodeIgnoresData() throws {
        // A void action's decode is a no-op — the `{"data":{}}` envelope a void
        // generic action returns must decode without throwing.
        let data = Data(#"{"data":{}}"#.utf8)
        try VoidActionRequest<EmptyActionInput>(action: "request_magic_link")
            .decode(from: data, using: JSONDecoder())
    }
}

private struct Stub: Decodable, Sendable {
    let id: String?
}

private struct StubInput: Encodable, Sendable {
    let title: String
}
