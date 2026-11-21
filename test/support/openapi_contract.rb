# frozen_string_literal: true

require "yaml"
require "time"

# Conferência de respostas reais da API contra os schemas de docs/openapi.yaml. Validador mínimo, sem
# dependências: resolve `$ref` e confere `type` (inclusive união com "null"), `enum`, `const`, `format`
# (`uuid` e `date-time`), `required`, `properties`, `additionalProperties: false`, `items`, `oneOf`
# (exatamente uma opção), `anyOf`, `allOf` e `minimum`/`maximum`. As divergências são reunidas e a
# asserção falha com a lista completa.
module OpenApiContract
  PATH = File.expand_path("../../docs/openapi.yaml", __dir__)
  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  TYPES = {
    "null" => lambda(&:nil?), "string" => ->(v) { v.is_a?(String) }, "integer" => ->(v) { v.is_a?(Integer) },
    "number" => ->(v) { v.is_a?(Numeric) }, "boolean" => ->(v) { [true, false].include?(v) }, "object" => ->(v) { v.is_a?(Hash) },
    "array" => ->(v) { v.is_a?(Array) }
  }.freeze

  def self.spec = @spec ||= YAML.safe_load_file(PATH)

  def openapi = OpenApiContract.spec

  # `ref_or_schema`: nome de um schema de components ("Quote"), referência ("#/components/schemas/Quote")
  # ou o próprio schema (Hash).
  def assert_conforms(value, ref_or_schema, path = "$")
    errors = contract_errors(value, ref_or_schema, path)

    assert_empty errors, "resposta fora do contrato OpenAPI (#{ref_or_schema.is_a?(Hash) ? "schema" : ref_or_schema}):\n#{errors.join("\n")}"
  end

  def contract_errors(value, ref_or_schema, path = "$")
    [].tap { |errors| conform(value, schema_for(ref_or_schema), path, errors) }
  end

  private

  def schema_for(ref_or_schema)
    return ref_or_schema if ref_or_schema.is_a?(Hash)

    { "$ref" => ref_or_schema.start_with?("#/") ? ref_or_schema : "#/components/schemas/#{ref_or_schema}" }
  end

  def resolve(schema)
    return schema unless schema.key?("$ref")

    target = schema["$ref"].delete_prefix("#/").split("/").reduce(openapi) { |node, key| node.fetch(key) }
    resolve(target).merge(schema.except("$ref"))
  end

  def conform(value, raw, path, errors)
    schema = resolve(raw)
    Array(schema["allOf"]).each { |part| conform(value, part, path, errors) }
    combinations(value, schema, path, errors)
    return unless type_ok?(value, schema, path, errors)

    errors << "#{path}: valor #{value.inspect} fora de #{schema["enum"].inspect}" if schema.key?("enum") && !schema["enum"].include?(value)
    errors << "#{path}: valor #{value.inspect} diferente de #{schema["const"].inspect}" if schema.key?("const") && schema["const"] != value
    format_ok(value, schema["format"], path, errors)
    limits(value, schema, path, errors)
    object(value, schema, path, errors) if value.is_a?(Hash)
    value.each_with_index { |item, index| conform(item, schema["items"], "#{path}[#{index}]", errors) } if value.is_a?(Array) && schema["items"]
  end

  def combinations(value, schema, path, errors)
    if schema["oneOf"]
      matches = schema["oneOf"].count { |option| contract_errors(value, option, path).empty? }
      errors << "#{path}: corresponde a #{matches} opções de oneOf (esperada exatamente uma)" unless matches == 1
    end
    return unless schema["anyOf"]&.none? { |option| contract_errors(value, option, path).empty? }

    errors << "#{path}: não corresponde a nenhuma opção de anyOf"
  end

  def type_ok?(value, schema, path, errors)
    types = Array(schema["type"])
    return true if types.empty? || types.any? { |type| TYPES.fetch(type).call(value) }

    errors << "#{path}: tipo #{value.class} (#{value.inspect[0, 60]}) diferente de #{types.join(" | ")}"
    false
  end

  def format_ok(value, format, path, errors)
    return unless value.is_a?(String)

    case format
    when "uuid" then errors << "#{path}: #{value.inspect} não é uuid" unless value.match?(UUID)
    when "date-time" then date_time(value, path, errors)
    end
  end

  def date_time(value, path, errors)
    Time.iso8601(value)
  rescue ArgumentError
    errors << "#{path}: #{value.inspect} não é date-time ISO 8601"
  end

  def limits(value, schema, path, errors)
    return unless value.is_a?(Numeric)

    errors << "#{path}: #{value} abaixo do mínimo #{schema["minimum"]}" if schema["minimum"] && value < schema["minimum"]
    errors << "#{path}: #{value} acima do máximo #{schema["maximum"]}" if schema["maximum"] && value > schema["maximum"]
  end

  def object(value, schema, path, errors)
    properties = schema.fetch("properties", {})
    Array(schema["required"]).each { |key| errors << "#{path}: propriedade obrigatória ausente: #{key}" unless value.key?(key) }
    value.each do |key, item|
      if properties.key?(key)
        conform(item, properties[key], "#{path}.#{key}", errors)
      elsif schema["additionalProperties"] == false
        errors << "#{path}: propriedade não documentada: #{key}"
      elsif schema["additionalProperties"].is_a?(Hash)
        conform(item, schema["additionalProperties"], "#{path}.#{key}", errors)
      end
    end
  end
end
