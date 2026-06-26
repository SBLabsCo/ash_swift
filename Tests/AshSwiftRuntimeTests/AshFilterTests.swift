import XCTest

@testable import AshSwiftRuntime

/// Pure tests for the hand-written filter operator generics and their type
/// erasure through `AnyEncodable`. These pin the exact camelCase wire keys the
/// reused AshTypescript RPC pipeline accepts, and prove unset operators are
/// omitted from the JSON.
final class AshFilterTests: XCTestCase {
    private func encoded<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    // MARK: operator key spelling

    func testEquatableOperatorsEmitsEqAndNotEqOnly() throws {
        XCTAssertEqual(try encoded(EquatableOperators(eq: true)), #"{"eq":true}"#)
        XCTAssertEqual(try encoded(EquatableOperators(notEq: false)), #"{"notEq":false}"#)
    }

    func testEnumOperatorsEmitsInArrayUnderTheInKey() throws {
        XCTAssertEqual(try encoded(EnumOperators(in: ["a", "b"])), #"{"in":["a","b"]}"#)
    }

    func testComparableOperatorsSpellsEveryComparisonKey() throws {
        let ops = ComparableOperators(
            lessThan: 1,
            lessThanOrEqual: 2,
            greaterThan: 3,
            greaterThanOrEqual: 4
        )
        XCTAssertEqual(
            try encoded(ops),
            #"{"greaterThan":3,"greaterThanOrEqual":4,"lessThan":1,"lessThanOrEqual":2}"#
        )
        // ComparableOperators also carries `in`; pin its wire key here too.
        XCTAssertEqual(try encoded(ComparableOperators(in: [1, 5])), #"{"in":[1,5]}"#)
    }

    func testNullableOperatorsSpellIsNil() throws {
        XCTAssertEqual(
            try encoded(NullableComparableOperators<Int>(isNil: true)),
            #"{"isNil":true}"#
        )
    }

    // MARK: nil omission

    func testUnsetOperatorsAreOmitted() throws {
        // Only the set operator appears; the rest of the bag is absent, not null.
        XCTAssertEqual(try encoded(NullableEnumOperators(eq: "x")), #"{"eq":"x"}"#)
    }

    // MARK: type erasure + request body threading

    func testAnyEncodableForwardsToWrappedValue() throws {
        let erased = AnyEncodable(EquatableOperators(eq: true))
        XCTAssertEqual(try encoded(erased), #"{"eq":true}"#)
    }

    func testListRequestBodyCarriesTheFilterMap() throws {
        // Mirrors what generated code emits: a typed filter, type-erased into the request.
        struct DemoFilter: Encodable, Sendable {
            var completed: EquatableOperators<Bool>?
        }
        var filter = DemoFilter()
        filter.completed = EquatableOperators(eq: true)

        let request = ListRequest<FilterStub>(
            action: "list_todos",
            filter: AnyEncodable(filter)
        )
        let json = try encoded(request.makeBody())

        XCTAssertTrue(json.contains(#""filter":{"completed":{"eq":true}}"#), json)
    }

    func testListRequestBodyOmitsFilterWhenNil() throws {
        let json = try encoded(ListRequest<FilterStub>(action: "list_todos").makeBody())
        XCTAssertFalse(json.contains("filter"), json)
    }
}

private struct FilterStub: Decodable, Sendable {}
