defmodule AshSwift.Codegen.ContractTest do
  @moduledoc """
  Tests the RPC contract export (issue #85): `AshSwift.Codegen.Contract`
  builds the same intermediate model `AshSwift.Codegen.Reader` hands the
  emitter, described independently of Swift syntax, as a JSON-encodable
  document.

  Two layers, mirroring `AshSwift.Codegen.ReaderTest`'s split of "assert on
  the real fixture domain" vs "assert on hand-built IR": the `encode/1` /
  `build/1` tests run against `AshSwift.Test.Domain` end to end (determinism,
  round-tripping, real enum/action shapes); the `build_from_ir/1` tests feed
  small hand-built IR maps so a field-add or action-removal is one map edit
  rather than a second compiled Ash resource.
  """
  use ExUnit.Case, async: true

  alias AshSwift.Codegen.Contract

  @domains [AshSwift.Test.Domain]

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

    test "carries the ash_swift Hex version and a stable contract_version" do
      doc = Contract.build(@domains)

      assert doc.contract_version == 1
      assert doc.ash_swift_version == Mix.Project.config()[:version]
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

      title = Enum.find(create.inputs, &(&1.name == "title"))
      assert title == %{name: "title", type: "String", required: true}

      # An offset-paginated list read reports the paginated wrapper type, not
      # the bare array — exactly the type Emitter.method_spec would return.
      offset = Enum.find(doc.actions, &(&1.name == "list_todos_offset"))
      assert offset.result_type == "OffsetPage<Todo>"

      # A destroy action has no result.
      destroy = Enum.find(doc.actions, &(&1.name == "destroy_todo"))
      assert destroy.result_type == nil

      # not_found_error?: false get action returns an optional.
      find = Enum.find(doc.actions, &(&1.name == "find_todo"))
      assert find.result_type == "Todo?"
    end

    test "a resource's model fields are all Optional (field-selection safe)" do
      doc = Contract.build(@domains)
      todo = Enum.find(doc.types, &(&1.name == "Todo" and &1.kind == "resource"))

      title = Enum.find(todo.fields, &(&1.name == "title"))
      assert title == %{name: "title", type: "String", optional: true}
    end
  end

  describe "build_from_ir/1 against hand-built IR fixtures" do
    # Mirrors the resource map shape AshSwift.Codegen.Reader.read/1 documents:
    # uniform keys, a related-only entry would fill in the function-side keys
    # with empty placeholders, but a primary resource carries all of them.
    #
    # `resource_module` is a real compiled fixture resource (AshSwift.Test.Todo)
    # rather than a made-up module name: Contract looks its domain up via
    # `Ash.Resource.Info.domain/1`, which requires a real Spark DSL module to
    # introspect. The hand-built `type_name` ("Widget") is what these tests
    # actually assert on, so the mismatch with the real resource's own name is
    # immaterial here.
    defp base_resource(overrides \\ %{}) do
      Map.merge(
        %{
          resource_module: AshSwift.Test.Todo,
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

      assert doc.enums == [%{name: "WidgetStatus", values: ["active", "archived"]}]
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

    defp fields_of(types, name) do
      types |> Enum.find(&(&1.name == name and &1.kind == "resource")) |> Map.fetch!(:fields)
    end
  end
end
