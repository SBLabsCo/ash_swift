import Foundation
import XCTest
@testable import AshSwiftRuntime

/// A `Transport` that returns a canned response, so we can exercise the client
/// without a live backend.
private struct StubTransport: Transport {
    let status: Int
    let body: Data
    let onRequest: @Sendable (URLRequest) -> Void

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        onRequest(request)
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (body, http)
    }
}

/// Integration tests for the one client entry point, `execute`. Every request
/// shape crosses the same seam, so these construct a request value and assert on
/// the wire round-trip and envelope handling.
final class AshRpcClientTests: XCTestCase {
    private func config() -> AshRpcConfig {
        AshRpcConfig(
            baseURL: URL(string: "https://example.com")!,
            headers: ["Authorization": "Bearer t"]
        )
    }

    func testExecutePostsToResolvedEndpointWithHeaders() async throws {
        let captured = CapturedRequest()
        let stub = StubTransport(status: 200, body: Data(#"{"success":true,"data":[]}"#.utf8)) {
            captured.value = $0
        }
        let client = AshRpcClient(config: config(), transport: stub)

        _ = try await client.execute(RawRequest(action: "list_todos"))

        let request = try XCTUnwrap(captured.value)
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/rpc/run")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testRunEndpointURLPreservesBaseURLPathPrefix() {
        let config = AshRpcConfig(baseURL: URL(string: "https://example.com/api/v1")!)
        XCTAssertEqual(config.runEndpointURL.absoluteString, "https://example.com/api/v1/rpc/run")

        let trailing = AshRpcConfig(baseURL: URL(string: "https://example.com/api/v1/")!)
        XCTAssertEqual(trailing.runEndpointURL.absoluteString, "https://example.com/api/v1/rpc/run")
    }

    func testExecuteRawReturnsBodyOnSuccess() async throws {
        let body = Data(#"{"success":true,"data":{"id":"1"}}"#.utf8)
        let stub = StubTransport(status: 200, body: body) { _ in }
        let client = AshRpcClient(config: config(), transport: stub)

        let data = try await client.execute(RawRequest(action: "get_todo"))
        XCTAssertEqual(data, body)
    }

    func testExecuteThrowsServerErrorOnFailureEnvelope() async {
        let body = Data(#"{"success":false,"errors":[{"type":"invalid","message":"nope"}]}"#.utf8)
        let stub = StubTransport(status: 200, body: body) { _ in }
        let client = AshRpcClient(config: config(), transport: stub)

        do {
            try await client.execute(RawRequest(action: "create_todo"))
            XCTFail("expected an error")
        } catch let AshRpcError.server(errors) {
            XCTAssertEqual(errors.first?.message, "nope")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testExecuteThrowsHttpStatusOnNon2xx() async {
        let stub = StubTransport(status: 500, body: Data("boom".utf8)) { _ in }
        let client = AshRpcClient(config: config(), transport: stub)

        do {
            try await client.execute(RawRequest(action: "list_todos"))
            XCTFail("expected an error")
        } catch let AshRpcError.httpStatus(code, _) {
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testExecuteListDecodesArrayFromEnvelope() async throws {
        let json = #"{"success":true,"data":[{"id":"1","title":"A"},{"id":"2","title":"B"}]}"#
        let stub = StubTransport(status: 200, body: Data(json.utf8)) { _ in }
        let client = AshRpcClient(config: config(), transport: stub)

        struct Item: Decodable { let id: String?; let title: String? }
        let items: [Item] = try await client.execute(ListRequest(action: "list_todos"))

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.last?.title, "B")
    }

    func testExecuteGetOptionalDecodesNullDataAsNil() async throws {
        let json = #"{"success":true,"data":null}"#
        let stub = StubTransport(status: 200, body: Data(json.utf8)) { _ in }
        let client = AshRpcClient(config: config(), transport: stub)

        struct Item: Decodable { let id: String? }
        let item: Item? = try await client.execute(GetOptionalRequest(action: "find_todo"))

        XCTAssertNil(item)
    }

    func testExecuteOffsetDecodesOffsetPageFromEnvelope() async throws {
        let json = #"{"success":true,"data":{"results":[{"id":"1","title":"Test"}],"hasMore":false,"limit":10,"offset":0,"count":null,"type":"offset"}}"#
        let stub = StubTransport(status: 200, body: Data(json.utf8)) { _ in }
        let client = AshRpcClient(config: config(), transport: stub)

        struct Item: Decodable { let id: String?; let title: String? }
        let page: OffsetPage<Item> = try await client.execute(OffsetPageRequest(action: "list_todos_offset"))

        XCTAssertEqual(page.results.count, 1)
        XCTAssertEqual(page.results.first?.title, "Test")
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(page.limit, 10)
        XCTAssertEqual(page.offset, 0)
        XCTAssertNil(page.count)
    }

    func testExecuteKeysetDecodesKeysetPageFromEnvelope() async throws {
        let json = #"{"success":true,"data":{"results":[{"id":"1"}],"hasMore":true,"limit":5,"after":null,"before":null,"previousPage":"prev-cursor","nextPage":"next-cursor","count":null,"type":"keyset"}}"#
        let stub = StubTransport(status: 200, body: Data(json.utf8)) { _ in }
        let client = AshRpcClient(config: config(), transport: stub)

        struct Item: Decodable { let id: String? }
        let page: KeysetPage<Item> = try await client.execute(KeysetPageRequest(action: "list_todos_keyset"))

        XCTAssertEqual(page.results.count, 1)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.limit, 5)
        XCTAssertNil(page.after)
        XCTAssertNil(page.before)
        XCTAssertEqual(page.nextPage, "next-cursor")
        XCTAssertEqual(page.previousPage, "prev-cursor")
    }

    func testExecuteOffsetSendsPageParamsInRequestBody() async throws {
        let captured = CapturedRequest()
        let json = #"{"success":true,"data":{"results":[],"hasMore":false,"limit":5,"offset":10,"count":null}}"#
        let stub = StubTransport(status: 200, body: Data(json.utf8)) { captured.value = $0 }
        let client = AshRpcClient(config: config(), transport: stub)

        struct Item: Decodable & Sendable {}
        let _: OffsetPage<Item> = try await client.execute(
            OffsetPageRequest(action: "list_todos_offset", page: OffsetPageParams(limit: 5, offset: 10))
        )

        let request = try XCTUnwrap(captured.value)
        let body = try XCTUnwrap(request.httpBody)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let page = try XCTUnwrap(parsed["page"] as? [String: Any])
        XCTAssertEqual(page["limit"] as? Int, 5)
        XCTAssertEqual(page["offset"] as? Int, 10)
    }

    func testExecuteKeysetSendsPageParamsInRequestBody() async throws {
        let captured = CapturedRequest()
        let json = #"{"success":true,"data":{"results":[],"hasMore":false,"limit":5,"after":null,"before":null,"nextPage":null,"previousPage":null,"count":null}}"#
        let stub = StubTransport(status: 200, body: Data(json.utf8)) { captured.value = $0 }
        let client = AshRpcClient(config: config(), transport: stub)

        struct Item: Decodable & Sendable {}
        let _: KeysetPage<Item> = try await client.execute(
            KeysetPageRequest(action: "list_todos_keyset", page: KeysetPageParams(limit: 5, after: "cursor-abc"))
        )

        let request = try XCTUnwrap(captured.value)
        let body = try XCTUnwrap(request.httpBody)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let page = try XCTUnwrap(parsed["page"] as? [String: Any])
        XCTAssertEqual(page["limit"] as? Int, 5)
        XCTAssertEqual(page["after"] as? String, "cursor-abc")
    }

    func testExecuteDestroyReturnsOnSuccessEnvelope() async throws {
        let body = Data(#"{"success":true}"#.utf8)
        let stub = StubTransport(status: 200, body: body) { _ in }
        let client = AshRpcClient(config: config(), transport: stub)
        // must not throw; Void result is discarded
        try await client.execute(DestroyRequest(action: "destroy_todo", identity: "uuid-1"))
    }

    func testExecuteOffsetThrowsDecodingFailedForBareArray() async {
        let json = #"{"success":true,"data":[{"id":"1"}]}"#
        let stub = StubTransport(status: 200, body: Data(json.utf8)) { _ in }
        let client = AshRpcClient(config: config(), transport: stub)

        struct Item: Decodable { let id: String? }
        do {
            let _: OffsetPage<Item> = try await client.execute(OffsetPageRequest(action: "list_todos"))
            XCTFail("expected decodingFailed")
        } catch AshRpcError.decodingFailed {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Sort string assembly

    // A sortable field set, as codegen emits per resource: a String-backed enum
    // whose raw values are the camelCase wire field names.
    private enum TodoSortField: String, Sendable {
        case title
        case dueAt
        case score
    }

    func testSortDirectionModifiersMatchAshSortString() {
        XCTAssertEqual(SortDirection.ascending.sortModifier, "")
        XCTAssertEqual(SortDirection.descending.sortModifier, "-")
        XCTAssertEqual(SortDirection.ascendingNilsFirst.sortModifier, "++")
        XCTAssertEqual(SortDirection.descendingNilsLast.sortModifier, "--")
    }

    func testAshSortStringIsNilForEmptySort() {
        let sort: [SortField<TodoSortField>] = []
        XCTAssertNil(ashSortString(sort))
    }

    func testAshSortStringDefaultsToAscendingWithBareFieldName() {
        XCTAssertEqual(ashSortString([SortField(TodoSortField.title)]), "title")
    }

    func testAshSortStringEncodesEachDirectionModifier() {
        XCTAssertEqual(ashSortString([SortField(TodoSortField.title, .descending)]), "-title")
        XCTAssertEqual(ashSortString([SortField(TodoSortField.score, .ascendingNilsFirst)]), "++score")
        XCTAssertEqual(ashSortString([SortField(TodoSortField.score, .descendingNilsLast)]), "--score")
    }

    func testAshSortStringJoinsMultipleFieldsInPriorityOrder() {
        let sort = [
            SortField(TodoSortField.score, .descending),
            SortField(TodoSortField.dueAt, .ascendingNilsFirst),
            SortField(TodoSortField.title),
        ]
        XCTAssertEqual(ashSortString(sort), "-score,++dueAt,title")
    }

    func testExecuteListSendsSortStringInRequestBody() async throws {
        let captured = CapturedRequest()
        let stub = StubTransport(status: 200, body: Data(#"{"success":true,"data":[]}"#.utf8)) {
            captured.value = $0
        }
        let client = AshRpcClient(config: config(), transport: stub)

        struct Item: Decodable & Sendable {}
        let _: [Item] = try await client.execute(ListRequest(action: "list_todos", sort: "-title"))

        let request = try XCTUnwrap(captured.value)
        let body = try XCTUnwrap(request.httpBody)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(parsed["sort"] as? String, "-title")
    }

    func testExecuteListOmitsSortKeyWhenNil() async throws {
        let captured = CapturedRequest()
        let stub = StubTransport(status: 200, body: Data(#"{"success":true,"data":[]}"#.utf8)) {
            captured.value = $0
        }
        let client = AshRpcClient(config: config(), transport: stub)

        struct Item: Decodable & Sendable {}
        let _: [Item] = try await client.execute(ListRequest(action: "list_todos"))

        let request = try XCTUnwrap(captured.value)
        let body = try XCTUnwrap(request.httpBody)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(parsed["sort"])
    }

    func testExecuteOffsetSendsSortAlongsidePage() async throws {
        let captured = CapturedRequest()
        let json = #"{"success":true,"data":{"results":[],"hasMore":false,"limit":5,"offset":0,"count":null}}"#
        let stub = StubTransport(status: 200, body: Data(json.utf8)) { captured.value = $0 }
        let client = AshRpcClient(config: config(), transport: stub)

        struct Item: Decodable & Sendable {}
        let _: OffsetPage<Item> = try await client.execute(
            OffsetPageRequest(action: "list_todos_offset", page: OffsetPageParams(limit: 5), sort: "-title")
        )

        let request = try XCTUnwrap(captured.value)
        let body = try XCTUnwrap(request.httpBody)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(parsed["sort"] as? String, "-title")
        let page = try XCTUnwrap(parsed["page"] as? [String: Any])
        XCTAssertEqual(page["limit"] as? Int, 5)
    }
}

/// Reference box so the `@Sendable` capture can record the request the stub saw.
private final class CapturedRequest: @unchecked Sendable {
    var value: URLRequest?
}
