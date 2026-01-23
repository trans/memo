require "json"

module Memo::CLI::Input
  extend self

  def string(data : Hash(String, JSON::Any), key : String) : String?
    return nil unless value = data[key]?
    value.as_s? || raise ArgumentError.new("Expected string for '#{key}', got #{type_name(value)}")
  end

  def int(data : Hash(String, JSON::Any), key : String) : Int32?
    return nil unless value = data[key]?
    value.as_i? || raise ArgumentError.new("Expected integer for '#{key}', got #{type_name(value)}")
  end

  def int64(data : Hash(String, JSON::Any), key : String) : Int64?
    return nil unless value = data[key]?
    value.as_i64? || raise ArgumentError.new("Expected integer for '#{key}', got #{type_name(value)}")
  end

  def float(data : Hash(String, JSON::Any), key : String) : Float64?
    return nil unless value = data[key]?
    value.as_f? || raise ArgumentError.new("Expected number for '#{key}', got #{type_name(value)}")
  end

  def bool(data : Hash(String, JSON::Any), key : String, default : Bool = false) : Bool
    return default unless value = data[key]?
    value.as_bool? || raise ArgumentError.new("Expected boolean for '#{key}', got #{type_name(value)}")
  end

  # Parse external ID (Int64 or String)
  #
  # Accepts either an integer or string value and returns the appropriate type.
  # Used for source_id, pair_id, parent_id which support both types.
  def external_id(data : Hash(String, JSON::Any), key : String) : Memo::ExternalId?
    return nil unless value = data[key]?

    # Try integer first, then string
    if int_val = value.as_i64?
      int_val
    elsif str_val = value.as_s?
      str_val
    else
      raise ArgumentError.new("Expected integer or string for '#{key}', got #{type_name(value)}")
    end
  end

  # Parse required external ID (Int64 or String)
  def external_id!(data : Hash(String, JSON::Any), key : String) : Memo::ExternalId
    external_id(data, key) || raise ArgumentError.new("Missing required field '#{key}'")
  end

  private def type_name(value : JSON::Any) : String
    case value.raw
    when String then "string"
    when Int64 then "integer"
    when Float64 then "number"
    when Bool then "boolean"
    when Array then "array"
    when Hash then "object"
    when Nil then "null"
    else value.raw.class.to_s
    end
  end
end
