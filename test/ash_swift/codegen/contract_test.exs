defmodule AshSwift.Codegen.ContractTest do
  @moduledoc """
  Tests the RPC contract export (issue #85): `AshSwift.Codegen.Contract`
  builds the same intermediate model `AshSwift.Codegen.Reader` hands the
  emitter, described independently of Swift syntax, as a JSON-encodable
  document.

  Three layers, mirroring `AshSwift.Codegen.ReaderTest`'s split of "assert on
  the real fixture domain" vs "assert on hand-built IR", plus the drift guard
  the module's own moduledoc promises:

    * `build/1` / `encode/1` against `AshSwift.Test.Domain` end to end
      (determinism, round-tripping, real enum/action/query-surface shapes,
      the committed snapshot fixture).
    * the golden cross-check: the contract is diffed against what
      `AshSwift.Codegen.Emitter` *actually renders* for the same domain, so a
      change to either side that the other doesn't follow fails a real test
      rather than resting on a comment.
    * `build_from_ir/1` against small hand-built IR maps, so a field-add or
      action-removal is one map edit rather than a second compiled Ash
      resource.
  """
  use ExUnit.Case, async: true

  alias AshSwift.Codegen.{Contract, Emitter, Reader}

  @domains [AshSwift.Test.Domain]
  @fixture_path Path.join(__DIR__, "../../fixtures/contract/test_domain.json")

  describe "build/1 and encode/1 against the real fixture domain" do
    test "two runs over the same domains produce byte-identical JSON" do
      assert Contract.encode(@domains) == Contract.encode(@domains)
    end

    test "the document round-trips through Jason.decode!/1" do
      decoded = @domains |> Contract.encode() |> Jason.decode!()

      assert %{
               "contract_version" => 1,
               "ash_swift_version" => version,
               "actions" => actions,
               "types" => types,
               "enums" => enums
             } = decoded

      assert is_binary(version)
      assert is_list(actions) and actions != []
      assert is_list(types) and types != []
      assert is_list(enums) and enums != []
    end

    test "carries the ash_swift Hex version (from the compiled application spec) and a stable contract_version" do
      doc = Contract.build(@domains)

      assert doc.contract_version == 1
      assert doc.ash_swift_version == to_string(Application.spec(:ash_swift, :vsn))
    end

    test "enums list their sorted values" do
      doc = Contract.build(@domains)
      priority = Enum.find(doc.enums, &(&1.name == "TodoPriority"))

      assert priority.values == ["high", "low", "medium"]
    end

    test "an action's inputs, resource, and result_type match what the emitter would render" do
      doc = Contract.build(@domains)
      create = Enum.find(doc.actions, &(&1.name == "create_todo"))

      assert create.resource == "Todo"
      assert create.resource_module == "AshSwift.Test.Todo"
      assert create.domain == "AshSwift.Test.Domain"
      assert create.action_type == "create"
      assert create.result_type == "Todo"
      assert create.optional_pagination == nil

      title = Enum.find(create.inputs, &(&1.name == "title"))
      assert title == %{name: "title", type: "String", required: true}

      # A required-pagination offset list read reports the paginated wrapper
      # type outright, with no separate overload (the mutual-exclusivity guard
      # in Reader.optional_action_pagination_type/1).
      offset = Enum.find(doc.actions, &(&1.name == "list_todos_offset"))
      assert offset.result_type == "OffsetPage<Todo>"
      assert offset.optional_pagination == nil

      # A destroy action has no result.
      destroy = Enum.find(doc.actions, &(&1.name == "destroy_todo"))
      assert destroy.result_type == nil

      # not_found_error?: false get action returns an optional.
      find = Enum.find(doc.actions, &(&1.name == "find_todo"))
      assert find.result_type == "Todo?"
    end

    test "an action that supports but doesn't require pagination reports the second, overloaded function" do
      doc = Contract.build(@domains)

      # `list_todos_keyset_optional` supports (but doesn't require) keyset
      # pagination — Emitter.method_specs/2 emits it as TWO functions: the bare
      # `[Todo]` one plus a `page:`-required `KeysetPage<Todo>` overload. Both
      # must be visible in the contract (issue: optional-pagination overloads
      # were previously invisible here).
      keyset_optional = Enum.find(doc.actions, &(&1.name == "list_todos_keyset_optional"))
      assert keyset_optional.result_type == "[Todo]"

      assert keyset_optional.optional_pagination == %{
               type: "keyset",
               result_type: "KeysetPage<Todo>"
             }

      # The plain `:read` default action (offset?/keyset? both true,
      # required?: false) picks offset — same overload shape, different kind.
      list_todos = Enum.find(doc.actions, &(&1.name == "list_todos"))
      assert list_todos.result_type == "[Todo]"
      assert list_todos.optional_pagination == %{type: "offset", result_type: "OffsetPage<Todo>"}
    end

    test "sortable/filterable mirror the action's enable_sort?/enable_filter? gating" do
      doc = Contract.build(@domains)

      list_todos = Enum.find(doc.actions, &(&1.name == "list_todos"))
      assert list_todos.sortable == true
      assert list_todos.filterable == true

      no_sort = Enum.find(doc.actions, &(&1.name == "list_todos_no_sort"))
      assert no_sort.sortable == false
      assert no_sort.filterable == true

      no_filter = Enum.find(doc.actions, &(&1.name == "list_todos_no_filter"))
      assert no_filter.sortable == true
      assert no_filter.filterable == false

      # A get action offers neither, regardless of enable_sort?/enable_filter?.
      get_todo = Enum.find(doc.actions, &(&1.name == "get_todo"))
      assert get_todo.sortable == false
      assert get_todo.filterable == false
    end

    test "a resource's model fields are all Optional (field-selection safe)" do
      doc = Contract.build(@domains)
      todo = Enum.find(doc.types, &(&1.name == "Todo" and &1.kind == "resource"))

      title = Enum.find(todo.fields, &(&1.name == "title"))
      assert title == %{name: "title", type: "String", optional: true}
    end

    test "the generated TodoFilter is present with its operator-typed fields and and/or/not combinators" do
      doc = Contract.build(@domains)
      filter = Enum.find(doc.types, &(&1.name == "TodoFilter"))

      assert filter.kind == "filter"

      priority = Enum.find(filter.fields, &(&1.name == "priority"))

      assert priority == %{
               name: "priority",
               type: "NullableEnumOperators<TodoPriority>",
               optional: true
             }

      Enum.each(["and", "or", "not"], fn combinator ->
        assert Enum.find(filter.fields, &(&1.name == combinator)) ==
                 %{name: combinator, type: "[TodoFilter]", optional: true}
      end)
    end

    test "the generated TodoSortField enum lists the sortable attribute names as its values" do
      doc = Contract.build(@domains)
      sort_field = Enum.find(doc.enums, &(&1.name == "TodoSortField"))

      assert "priority" in sort_field.values
      assert "title" in sort_field.values
      refute "metadata" in sort_field.values
    end

    test "matches the committed snapshot fixture" do
      # Regenerate after an intentional contract change with:
      #
      #     MIX_ENV=test mix ash_swift.contract --output test/fixtures/contract/test_domain.json
      #
      # (never pipe the bare stdout form into the fixture — it interleaves
      # compile output and reader Logger warnings with the JSON; --output
      # writes the contract as the file's only content.)
      assert Contract.encode(@domains) <> "\n" == File.read!(@fixture_path)
    end
  end

  describe "golden cross-check against what Emitter actually renders" do
    setup do
      %{primary_resources: primary, all_resources: all} = Reader.read(@domains)
      doc = Contract.build(@domains)

      %{
        doc: doc,
        functions_text: Emitter.render_functions(primary),
        types_text: Emitter.render_types(all)
      }
    end

    # Every `/// Calls the `name` RPC action (...).` doc comment is immediately
    # followed by exactly the function signature render_spec/1 renders — this
    # walks both together per function, so it catches a mismatched name AND
    # return type in the same pass. A void function has no `-> Type` clause at
    # all (capture group 2 is then absent from the match).
    @function_regex ~r/\/\/\/ Calls the `([^`]+)` RPC action \([^\n]*\)\.\n\s*public func [^\n]*\) async throws(?: -> ([^{\n]+))? \{/

    test "the contract's {action name, overloads} set equals the functions Emitter.render_functions/1 emits",
         %{doc: doc, functions_text: functions_text} do
      emitted =
        @function_regex
        |> Regex.scan(functions_text, capture: :all_but_first)
        |> Enum.map(fn
          [name, return_type] -> {name, String.trim(return_type)}
          [name] -> {name, nil}
        end)
        |> Enum.sort()

      expected =
        doc.actions
        |> Enum.flat_map(fn action ->
          overloads =
            case action.optional_pagination do
              nil -> [action.result_type]
              %{result_type: paginated} -> [action.result_type, paginated]
            end

          Enum.map(overloads, &{action.name, &1})
        end)
        |> Enum.sort()

      assert emitted == expected
    end

    test "the contract's type/enum names equal the emitter's top-level declarations", %{
      doc: doc,
      types_text: types_text
    } do
      emitted_names =
        ~r/^public (?:struct|enum) (\w+)/m
        |> Regex.scan(types_text, capture: :all_but_first)
        |> List.flatten()
        |> MapSet.new()

      contract_names =
        MapSet.union(
          MapSet.new(doc.types, & &1.name),
          MapSet.new(doc.enums, & &1.name)
        )

      assert contract_names == emitted_names
    end
  end

  describe "build_from_ir/1 against hand-built IR fixtures" do
    # Mirrors the resource map shape AshSwift.Codegen.Reader.read/1 documents:
    # uniform keys, a related-only entry would fill in the function-side keys
    # with empty placeholders, but a primary resource carries all of them.
    #
    # `resource_module` and `domain` are real modules (an arbitrary compiled
    # one for `domain` — Contract only stringifies it, it no longer
    # introspects it via `Ash.Resource.Info.domain/1`, ADR-0009) rather than
    # made-up atoms, just so `inspect/1` output in a failed assertion reads
    # like a real module name. The hand-built `type_name` ("Widget") is what
    # these tests actually assert on, so the mismatch with the real resource's
    # own name is immaterial here.
    defp base_resource(overrides \\ %{}) do
      Map.merge(
        %{
          resource_module: AshSwift.Test.Todo,
          domain: AshSwift.Test.Domain,
          type_name: "Widget",
          fields: [%{name: "name", swift_type: "String"}],
          enums: [],
          actions: [
            %{
              rpc_name: :list_widgets,
              action: :read,
              action_type: :read,
              is_get?: false,
              get_by_params: [],
              get_by_location: nil,
              not_found_error?: false,
              input_struct_name: nil,
              primary_key_params: [],
              pagination_type: :none,
              optional_pagination_type: :none,
              sortable?: false,
              filterable?: false
            }
          ],
          input_structs: [],
          sort_field: nil,
          filter_struct: nil
        },
        overrides
      )
    end

    defp ir(resource), do: %{primary_resources: [resource], all_resources: [resource]}

    test "an optional field added to a fixture resource appears in the JSON" do
      before_fields = Contract.build_from_ir(ir(base_resource())).types |> fields_of("Widget")
      refute Enum.any?(before_fields, &(&1.name == "color"))

      widget_with_color =
        base_resource(%{
          fields: [
            %{name: "name", swift_type: "String"},
            %{name: "color", swift_type: "String"}
          ]
        })

      after_fields = Contract.build_from_ir(ir(widget_with_color)).types |> fields_of("Widget")

      assert Enum.find(after_fields, &(&1.name == "color")) ==
               %{name: "color", type: "String", optional: true}
    end

    test "removing an action makes it disappear from the JSON" do
      with_action = Contract.build_from_ir(ir(base_resource()))
      assert Enum.any?(with_action.actions, &(&1.name == "list_widgets"))

      without_action = Contract.build_from_ir(ir(base_resource(%{actions: []})))
      refute Enum.any?(without_action.actions, &(&1.name == "list_widgets"))
    end

    test "an enum on a hand-built resource lists its cases as sorted string values" do
      widget_with_enum =
        base_resource(%{
          fields: [%{name: "status", swift_type: "WidgetStatus"}],
          enums: [%{enum_name: "WidgetStatus", cases: [:archived, :active]}]
        })

      doc = Contract.build_from_ir(ir(widget_with_enum))

      assert Enum.find(doc.enums, &(&1.name == "WidgetStatus")) ==
               %{name: "WidgetStatus", values: ["active", "archived"]}
    end

    test "a required create input struct field is optional: false in the JSON" do
      resource =
        base_resource(%{
          actions: [
            %{
              rpc_name: :create_widget,
              action: :create,
              action_type: :create,
              is_get?: false,
              get_by_params: [],
              get_by_location: nil,
              not_found_error?: false,
              input_struct_name: "CreateWidgetInput",
              primary_key_params: [],
              pagination_type: :none,
              optional_pagination_type: :none,
              sortable?: false,
              filterable?: false
            }
          ],
          input_structs: [
            %{
              struct_name: "CreateWidgetInput",
              fields: [%{name: "name", swift_type: "String", required?: true}]
            }
          ]
        })

      doc = Contract.build_from_ir(ir(resource))

      create = Enum.find(doc.actions, &(&1.name == "create_widget"))
      assert create.inputs == [%{name: "name", type: "String", required: true}]
      assert create.result_type == "Widget"

      input_type = Enum.find(doc.types, &(&1.name == "CreateWidgetInput"))
      assert input_type.kind == "input"
      assert input_type.fields == [%{name: "name", type: "String", optional: false}]
    end

    test "a decodable?: true struct is classified as a result type, not an input" do
      resource =
        base_resource(%{
          input_structs: [
            %{
              struct_name: "PingResult",
              fields: [%{name: "message", swift_type: "String", required?: true}],
              decodable?: true
            }
          ]
        })

      doc = Contract.build_from_ir(ir(resource))
      result_type = Enum.find(doc.types, &(&1.name == "PingResult"))

      assert result_type.kind == "result"
    end

    test "an action with optional pagination reports it alongside the bare result_type" do
      resource =
        base_resource(%{
          actions: [
            %{
              rpc_name: :list_widgets,
              action: :read,
              action_type: :read,
              is_get?: false,
              get_by_params: [],
              get_by_location: nil,
              not_found_error?: false,
              input_struct_name: nil,
              primary_key_params: [],
              pagination_type: :none,
              optional_pagination_type: :offset,
              sortable?: false,
              filterable?: false
            }
          ]
        })

      doc = Contract.build_from_ir(ir(resource))
      action = Enum.find(doc.actions, &(&1.name == "list_widgets"))

      assert action.result_type == "[Widget]"
      assert action.optional_pagination == %{type: "offset", result_type: "OffsetPage<Widget>"}
    end

    test "a generated filter_struct becomes a kind: \"filter\" type with and/or/not combinators" do
      resource =
        base_resource(%{
          filter_struct: %{
            type_name: "WidgetFilter",
            fields: [%{name: "name", swift_type: "EnumOperators<String>"}]
          }
        })

      doc = Contract.build_from_ir(ir(resource))
      filter = Enum.find(doc.types, &(&1.name == "WidgetFilter"))

      assert filter.kind == "filter"

      assert Enum.find(filter.fields, &(&1.name == "name")) ==
               %{name: "name", type: "EnumOperators<String>", optional: true}

      assert Enum.find(filter.fields, &(&1.name == "and")) ==
               %{name: "and", type: "[WidgetFilter]", optional: true}
    end

    test "a resource with no filter_struct/sort_field emits no Filter/SortField entry" do
      doc = Contract.build_from_ir(ir(base_resource()))

      refute Enum.any?(doc.types, &(&1.kind == "filter"))
      refute Enum.any?(doc.enums, &(&1.name == "WidgetSortField"))
    end

    test "a generated sort_field becomes an enum entry whose values are the sortable field names" do
      resource =
        base_resource(%{sort_field: %{type_name: "WidgetSortField", fields: ["color", "name"]}})

      doc = Contract.build_from_ir(ir(resource))

      assert Enum.find(doc.enums, &(&1.name == "WidgetSortField")) ==
               %{name: "WidgetSortField", values: ["color", "name"]}
    end

    test "sortable/filterable on the action entry reflect the IR's sortable?/filterable? flags" do
      resource =
        base_resource(%{
          actions: [
            %{
              rpc_name: :list_widgets,
              action: :read,
              action_type: :read,
              is_get?: false,
              get_by_params: [],
              get_by_location: nil,
              not_found_error?: false,
              input_struct_name: nil,
              primary_key_params: [],
              pagination_type: :none,
              optional_pagination_type: :none,
              sortable?: true,
              filterable?: true
            }
          ]
        })

      doc = Contract.build_from_ir(ir(resource))
      action = Enum.find(doc.actions, &(&1.name == "list_widgets"))

      assert action.sortable == true
      assert action.filterable == true
    end

    defp fields_of(types, name) do
      types |> Enum.find(&(&1.name == name and &1.kind == "resource")) |> Map.fetch!(:fields)
    end
  end
end
