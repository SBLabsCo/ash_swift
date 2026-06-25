import Config

# AshSwift reuses AshTypescript's RPC runtime and DSL (ADR-0003). Its verifier
# requires the field formatters to be set; camelCase matches the Swift idiom we
# emit for output field/function names (ADR-0002).
config :ash_typescript,
  output_field_formatter: :camel_case,
  input_field_formatter: :camel_case

if File.exists?(Path.expand("#{config_env()}.exs", __DIR__)) do
  import_config "#{config_env()}.exs"
end
