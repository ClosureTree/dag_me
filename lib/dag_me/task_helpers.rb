# frozen_string_literal: true

module DagMe
  # Backs the `dag_me:status` rake task: a doctor-style report of every
  # dag_me model's database objects and closure health.
  module TaskHelpers
    COLORS = {
      green: "\e[32m",
      red: "\e[31m",
      yellow: "\e[33m",
      cyan: "\e[36m",
      reset: "\e[0m"
    }.freeze

    module_function

    def colorize(text, color)
      "#{COLORS[color]}#{text}#{COLORS[:reset]}"
    end

    def ok(text)
      "#{colorize('✓', :green)} #{text}"
    end

    def bad(text)
      "#{colorize('✗', :red)} #{text}"
    end

    def status(models, io: $stdout)
      if models.empty?
        io.puts colorize('No dag_me models found.', :yellow)
        return
      end

      models.each { |model| io.puts model_report(model) }
    end

    def model_report(model)
      model.dag_configs.each_value.map { |config| config_report(model, config) }.join
    end

    def config_report(model, config)
      label = config.default? ? model.name : "#{model.name} [#{config.name}]"
      lines = ["#{colorize(label, :cyan)} (maintain: #{config.maintain}" \
               "#{", scope: #{config.scope_columns.join(', ')}" if config.scope_columns.any?})"]
      lines.concat(table_checks(model, config))
      lines.concat(trigger_checks(model, config))
      lines.concat(function_checks(model, config))
      lines << closure_check(model, config)
      "#{lines.compact.join("\n  ")}\n"
    end

    def table_checks(model, config)
      tables = [config.edge_table]
      tables << config.paths_table if config.closure?
      tables.map do |table|
        if model.connection.table_exists?(table)
          ok("table #{table}")
        else
          bad("table #{table} missing - run the dag_me migration")
        end
      end
    end

    def trigger_checks(model, config)
      expected = ["#{config.prefix}_edge_insert_check"]
      if config.closure?
        expected.push("#{config.prefix}_edge_insert_apply", "#{config.prefix}_edge_delete_apply",
                      "#{config.prefix}_node_insert", "#{config.prefix}_node_delete")
      end
      expected << "#{config.prefix}_node_update" if config.scope_columns.any?

      conn = model.connection
      installed = conn.select_values(<<~SQL)
        SELECT t.tgname FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE NOT t.tgisinternal
          AND #{namespace_filter(conn, config)}
          AND t.tgname LIKE #{conn.quote("#{config.prefix}\\_%")}
      SQL
      (expected - installed).map { |name| bad("trigger #{name} missing") }
                            .presence || [ok("triggers (#{expected.length})")]
    end

    def function_checks(model, config)
      expected = ["#{config.prefix}_lock", "#{config.prefix}_edge_insert_check"]
      if config.closure?
        expected.push("#{config.prefix}_edge_insert_apply", "#{config.prefix}_edge_delete_apply",
                      "#{config.prefix}_node_insert", "#{config.prefix}_node_delete",
                      "#{config.prefix}_rebuild_paths", "#{config.prefix}_validate_paths")
      end
      expected << "#{config.prefix}_node_update" if config.scope_columns.any?

      conn = model.connection
      installed = conn.select_values(<<~SQL)
        SELECT p.proname FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE #{namespace_filter(conn, config)}
          AND p.proname LIKE #{conn.quote("#{config.prefix}\\_%")}
      SQL
      (expected - installed).map { |name| bad("function #{name} missing") }
                            .presence || [ok("functions (#{expected.length})")]
    end

    # Objects for schema-qualified node tables live in that schema regardless
    # of search_path; unqualified ones resolve through it.
    def namespace_filter(conn, config)
      return "n.nspname = #{conn.quote(config.schema)}" if config.schema

      'n.nspname = ANY (current_schemas(false))'
    end

    def closure_check(model, config)
      return ok('closure: not materialized (recursive_cte)') unless config.closure?
      return nil unless model.connection.table_exists?(config.paths_table)

      graph = model.dag(config.name)
      discrepancies = graph.validate
      if discrepancies.empty?
        ok("closure valid (#{graph.edges.count} edges)")
      else
        facade = config.default? ? 'Model.dag' : "Model.dag(:#{config.name})"
        bad("closure diverged: #{discrepancies.length} rows - run #{facade}.rebuild!")
      end
    end
  end
end
