defmodule AshSwift.Codegen.InjectionTest do
  @moduledoc """
  Pins the #142 hardening: Swift string literals are escaped, and names spliced
  into identifier positions must be plain Swift identifiers.
  """
  use ExUnit.Case, async: true

  alias AshSwift.Codegen.Emitter
  alias AshSwift.Codegen
  alias AshSwift.Codegen.Reader

  describe "Emitter.swift_string/1" do
    test "wraps plain text in quotes unchanged" do
      assert Emitter.swift_string("list_todos") == ~s("list_todos")
    end

    test "escapes quotes, backslashes, interpolation and control characters" do
      assert Emitter.swift_string(~S|a"b|) == ~S|"a\"b"|
      assert Emitter.swift_string(~S|a\b|) == ~S|"a\\b"|
      assert Emitter.swift_string(~S|\(x)|) == ~S|"\\(x)"|
      assert Emitter.swift_string("a\nb\rc\td\0e") == ~S|"a\nb\rc\td\0e"|
      assert Emitter.swift_string(<<1, ?a, 0x7F>>) == ~S|"\u{1}a\u{7F}"|
    end

    test "a literal-terminating payload stays inside one literal" do
      assert Emitter.swift_string(~S|x") + evil("y|) == ~S|"x\") + evil(\"y"|
    end

    test "accepts atoms" do
      assert Emitter.swift_string(:list_todos) == ~s("list_todos")
    end
  end

  describe "identifier validation in the Reader" do
    test "rejects a resource type_name that is not a Swift identifier" do
      assert_raise Mix.Error, ~r/type_name .* is not a valid Swift identifier/s, fn ->
        Reader.read([AshSwift.Test.BadTypeNameDomain])
      end
    end

    test "rejects an rpc_action name that is not a Swift identifier" do
      assert_raise Mix.Error, ~r/rpc_action name .* is not a valid Swift identifier/s, fn ->
        Reader.read([AshSwift.Test.BadActionNameDomain])
      end
    end

    test "rejects an rpc_action name that passes the raw identifier check but lower-camels to a non-identifier (:_1st)" do
      # `_1st` is a valid raw identifier, but Swift sees the lower-camelled `1st`, so this
      # fails only if the Reader validates the lower-camelled form.
      assert_raise Mix.Error, ~r/rpc_action name "1st" .* is not a valid Swift identifier/s, fn ->
        Reader.read([underscore_digit_domain()])
      end
    end

    test "rejects a field name that is not a Swift identifier" do
      assert_raise Mix.Error, ~r/field name .* is not a valid Swift identifier/s, fn ->
        Reader.read([AshSwift.Test.BadFieldNameDomain])
      end
    end

    test "rejects an enum value whose case name is not a Swift identifier" do
      assert_raise Mix.Error, ~r/enum value .* is not a valid Swift identifier/s, fn ->
        Reader.read([AshSwift.Test.BadEnumValueDomain])
      end
    end

    test "rejects an enum value on a calculation (derived field) that is not a Swift identifier" do
      assert_raise Mix.Error, ~r/enum value .* is not a valid Swift identifier/s, fn ->
        Reader.read([AshSwift.Test.BadCalcEnumValueDomain])
      end
    end

    test "rejects a nested struct name derived from a hostile raw typed-map return field (array-of-map arguments share the helper)" do
      assert_raise Mix.Error, ~r/struct name .* is not a valid Swift identifier/s, fn ->
        Reader.read([AshSwift.Test.BadStructNameReturnDomain])
      end
    end
  end

  describe "snake_case enum values (raw wire value pin)" do
    test "the Reader keeps the raw wire value when the Swift case name is lower-camelled" do
      resource =
        [AshSwift.Test.SnakeEnumValueDomain]
        |> Reader.read()
        |> Map.fetch!(:all_resources)
        |> Enum.find(&(&1.type_name == "SnakeEnumValue"))

      enum = Enum.find(resource.enums, &(&1.enum_name == "SnakeEnumValueStage"))

      assert %{name: "inProgress", raw: "in_progress"} in enum.cases
      assert %{name: "done", raw: nil} in enum.cases
    end

    test "the Emitter renders the raw wire value on the case" do
      files = Codegen.build_files([AshSwift.Test.SnakeEnumValueDomain])
      types = files |> Map.values() |> Enum.join("\n")

      assert types =~ ~s(case inProgress = "in_progress")
    end
  end

  describe "Swift keyword escaping" do
    test "a get_by lookup field named like a Swift keyword is backtick-escaped in the input dictionary" do
      files = Codegen.build_files([AshSwift.Test.KeywordGetByDomain])
      assert files["AshRpcFunctions.swift"] =~ ~S|"default": `default`|
    end
  end

  # The `:_1st` fixture is compiled here at test time rather than living in test/support:
  # ash_typescript's verifier warns on `_<digit>` rpc names, which would fail CI's
  # `mix compile --warnings-as-errors`. The warning is captured, not printed.
  defp underscore_digit_domain do
    domain = AshSwift.Test.UnderscoreDigitActionNameDomain

    unless Code.ensure_loaded?(domain) do
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule AshSwift.Test.UnderscoreDigitActionName do
          use Ash.Resource,
            domain: AshSwift.Test.UnderscoreDigitActionNameDomain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshTypescript.Resource]

          typescript do
            type_name "UnderscoreDigitActionName"
          end

          ets do
            private? true
          end

          attributes do
            uuid_primary_key :id, public?: true
          end

          actions do
            defaults [:read]
          end
        end

        defmodule AshSwift.Test.UnderscoreDigitActionNameDomain do
          use Ash.Domain,
            otp_app: :ash_swift,
            extensions: [AshTypescript.Rpc],
            validate_config_inclusion?: false

          typescript_rpc do
            resource AshSwift.Test.UnderscoreDigitActionName do
              rpc_action :_1st, :read
            end
          end

          resources do
            resource AshSwift.Test.UnderscoreDigitActionName
          end
        end
        """)
      end)
    end

    domain
  end
end
