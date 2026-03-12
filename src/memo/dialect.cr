require "./dialect/base"
require "./dialect/sqlite"

module Memo
  module Dialect
    # Auto-detect dialect from connection string
    def self.for(connection_string : String) : Base
      if connection_string.starts_with?("postgres")
        raise ArgumentError.new(
          "PostgreSQL support requires: require \"memo/pg\""
        )
      else
        SQLite.new
      end
    end
  end
end
