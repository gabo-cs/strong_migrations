module StrongMigrations
  class Checker
    include Checks
    include SafeMethods

    attr_accessor :direction, :transaction_disabled

    def initialize(migration)
      @migration = migration
      @new_tables = []
      @safe = false
    end

    def safety_assured
      previous_value = @safe
      begin
        @safe = true
        yield
      ensure
        @safe = previous_value
      end
    end

    def perform(method, *args)
      check_version_supported
      set_timeouts
      check_lock_timeout

      if !safe? || safe_by_default_method?(method)
        # TODO better pattern
        case method
        when :remove_column, :remove_columns, :remove_timestamps, :remove_reference, :remove_belongs_to
          check_remove_column(method, args)
        when :change_table
          check_change_table
        when :rename_table
          check_rename_table
        when :rename_column
          check_rename_column
        when :add_index
          check_add_index(args)
        when :remove_index
          check_remove_index(args)
        when :add_column
          check_add_column(args)
        when :change_column
          check_change_column(args)
        when :create_table
          check_create_table(args)
        when :add_reference, :add_belongs_to
          check_add_reference(method, args)
        when :execute
          check_execute
        when :change_column_null
          check_change_column_null(args)
        when :add_foreign_key
          check_add_foreign_key(args)
        when :validate_foreign_key
          check_validate_foreign_key
        when :add_check_constraint
          check_add_check_constraint(args)
        when :validate_check_constraint
          check_validate_check_constraint
        end

        # custom checks
        StrongMigrations.checks.each do |check|
          @migration.instance_exec(method, args, &check)
        end
      end

      result = yield

      # outdated statistics + a new index can hurt performance of existing queries
      if StrongMigrations.auto_analyze && direction == :up && method == :add_index
        adapter.analyze_table(args[0])
      end

      result
    end

    private

    # TODO raise error in 0.9.0
    def check_version_supported
      return if defined?(@version_checked)

      min_version = adapter.min_version
      if min_version
        version = adapter.server_version
        if version < Gem::Version.new(min_version)
          warn "[strong_migrations] #{adapter.name} version (#{version}) not supported in this version of Strong Migrations (#{StrongMigrations::VERSION})"
        end
      end

      @version_checked = true
    end

    def set_timeouts
      return if defined?(@timeouts_set)

      if StrongMigrations.statement_timeout
        adapter.set_statement_timeout(StrongMigrations.statement_timeout)
      end
      if StrongMigrations.lock_timeout
        adapter.set_lock_timeout(StrongMigrations.lock_timeout)
      end

      @timeouts_set = true
    end

    def check_lock_timeout
      return if defined?(@lock_timeout_checked)

      if StrongMigrations.lock_timeout_limit
        adapter.check_lock_timeout(StrongMigrations.lock_timeout_limit)
      end

      @lock_timeout_checked = true
    end

    def safe?
      @safe || ENV["SAFETY_ASSURED"] || (direction == :down && !StrongMigrations.check_down) || version_safe?
    end

    def version_safe?
      version && version <= StrongMigrations.start_after
    end

    def version
      @migration.version
    end

    def adapter
      @adapter ||= begin
        cls =
          case connection.adapter_name
          when /postg/i # PostgreSQL, PostGIS
            Adapters::PostgreSQLAdapter
          when /mysql/i
            if connection.try(:mariadb?)
              Adapters::MariaDBAdapter
            else
              Adapters::MySQLAdapter
            end
          else
            Adapters::AbstractAdapter
          end

        cls.new(self)
      end
    end

    def connection
      @migration.connection
    end
  end
end
