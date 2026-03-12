require "./dialect/base"
require "./dialect/sqlite"

module Memo
  module Dialect
    # Class variable to hold the PG dialect constructor.
    # Set by requiring "memo/pg" which loads the Postgres dialect.
    @@pg_factory : (-> Base)? = nil

    # Register the PostgreSQL dialect factory (called by memo/pg.cr)
    def self.register_pg(&factory : -> Base)
      @@pg_factory = factory
    end

    # Auto-detect dialect from connection string
    def self.for(connection_string : String) : Base
      if connection_string.starts_with?("postgres")
        factory = @@pg_factory
        if factory
          factory.call
        else
          raise ArgumentError.new(
            "PostgreSQL support requires: require \"memo/pg\""
          )
        end
      else
        SQLite.new
      end
    end
  end
end
