require "json"

module Memo::CLI::Input
  extend self

  def string(data : Hash(String, JSON::Any), key : String) : String?
    data[key]?.try(&.as_s)
  end

  def int(data : Hash(String, JSON::Any), key : String) : Int32?
    data[key]?.try(&.as_i)
  end

  def int64(data : Hash(String, JSON::Any), key : String) : Int64?
    data[key]?.try(&.as_i64)
  end

  def float(data : Hash(String, JSON::Any), key : String) : Float64?
    data[key]?.try(&.as_f)
  end

  def bool(data : Hash(String, JSON::Any), key : String, default : Bool = false) : Bool
    data[key]?.try(&.as_bool?) || default
  end
end
