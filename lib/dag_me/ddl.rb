# frozen_string_literal: true

module DagMe
  # Generates and executes the SQL objects for a dag_me model.
  #
  # Everything is derived from the model's Configuration. For a `tasks` table
  # with prefix `task_dag`, installs:
  #
  #   task_dag_edges              -- source of truth (parent_*, child_* [, scope cols])
  #   task_dag_paths              -- transitive closure incl. self-rows
  #                                  (ancestor_*, descendant_*, min_depth, path_count [, scope cols])
  #   task_dag_lock(text)         -- isolation guard + per-scope pg_advisory_xact_lock
  #   task_dag_edge_insert_check  -- BEFORE INSERT: scope stamp + lock + cycle rejection
  #   task_dag_edge_insert_apply  -- AFTER INSERT: incremental closure expansion
  #   task_dag_edge_delete_apply  -- AFTER DELETE: path_count decrement + min_depth repair
  #   task_dag_node_insert        -- AFTER INSERT on tasks: self-row
  #   task_dag_node_update        -- BEFORE UPDATE on tasks: scope-change guard (scoped only)
  #   task_dag_node_delete        -- BEFORE DELETE on tasks: drop edges through triggers
  #   task_dag_rebuild_paths()    -- full closure rebuild from edges
  #   task_dag_validate_paths()   -- closure vs recursive-CTE truth diff
  #
  # Node identity is an ordered column list (Configuration#node_pk_columns):
  # single-key models get the classic parent_id / child_id / ancestor_id /
  # descendant_id columns, composite keys get one column per key column
  # (parent_org_id, parent_serial, ...). All joins and comparisons are
  # generated as per-column AND lists, so both shapes share one code path.
  #
  # Integrity violations RAISE with the DagMe::SQLSTATE_* codes, so the Ruby
  # layer translates them without depending on message wording.
  #
  # With scope columns, edges may only connect nodes whose scope values match;
  # the trigger stamps the node's scope onto edge and closure rows, so raw SQL
  # writers cannot cross tenants either.
  #
  # The paths table and its triggers are skipped for maintain: :recursive_cte;
  # cycle rejection then uses a recursive CTE in the BEFORE INSERT trigger.
  class DDL
    class << self
      # Installs / removes the SQL objects for every dag the model declares.
      def install!(model)
        model.dag_configs.each_value { |config| new(config).install! }
      end

      def uninstall!(model)
        model.dag_configs.each_value { |config| new(config).uninstall! }
      end
    end

    attr_reader :config

    def initialize(config)
      @config = config
    end

    def install!
      execute_all(install_sql)
    end

    def uninstall!
      execute_all(uninstall_sql)
    end

    def install_sql
      statements = [edges_table_sql]
      if config.closure?
        statements << paths_table_sql
        statements.concat(closure_function_sql)
        statements.concat(closure_trigger_sql)
        statements << backfill_self_rows_sql
        statements << rebuild_function_sql
        statements << validate_function_sql
      else
        statements.concat(cte_function_sql)
        statements.concat(cte_trigger_sql)
      end
      statements
    end

    # Graph#backfill_self_rows! reuses this to repair nodes inserted with
    # triggers disabled (e.g. Rails fixture loading).
    def backfill_self_rows_sql
      <<~SQL
        INSERT INTO #{config.paths_table} (#{list(anc_cols)}, #{list(desc_cols)}, min_depth, path_count#{scope_column_list})
        SELECT #{list(pk_cols)}, #{list(pk_cols)}, 0, 1#{scope_column_list} FROM #{config.node_table}
        ON CONFLICT DO NOTHING;
      SQL
    end

    def uninstall_sql
      [
        "DROP TRIGGER IF EXISTS #{config.trigger_name('node_insert')} ON #{config.node_table};",
        "DROP TRIGGER IF EXISTS #{config.trigger_name('node_update')} ON #{config.node_table};",
        "DROP TRIGGER IF EXISTS #{config.trigger_name('node_delete')} ON #{config.node_table};",
        "DROP TABLE IF EXISTS #{config.paths_table};",
        "DROP TABLE IF EXISTS #{config.edge_table};",
        "DROP FUNCTION IF EXISTS #{config.function_ref('lock')}(text);",
        "DROP FUNCTION IF EXISTS #{config.function_ref('edge_insert_check')}();",
        "DROP FUNCTION IF EXISTS #{config.function_ref('edge_insert_apply')}();",
        "DROP FUNCTION IF EXISTS #{config.function_ref('edge_delete_apply')}();",
        "DROP FUNCTION IF EXISTS #{config.function_ref('node_insert')}();",
        "DROP FUNCTION IF EXISTS #{config.function_ref('node_update')}();",
        "DROP FUNCTION IF EXISTS #{config.function_ref('node_delete')}();",
        "DROP FUNCTION IF EXISTS #{config.function_ref('rebuild_paths')}();",
        "DROP FUNCTION IF EXISTS #{config.function_ref('validate_paths')}();"
      ]
    end

    private

    def execute_all(statements)
      config.model.connection_pool.with_connection do |conn|
        statements.each { |sql| conn.execute(sql) }
      end
    end

    def pk_cols
      config.node_pk_columns
    end

    def parent_cols
      config.edge_parent_columns
    end

    def child_cols
      config.edge_child_columns
    end

    def anc_cols
      config.paths_ancestor_columns
    end

    def desc_cols
      config.paths_descendant_columns
    end

    # "a, b" or "q.a, q.b"
    def list(cols, qualifier = nil)
      cols.map { |c| qualifier ? "#{qualifier}.#{c}" : c.to_s }.join(', ')
    end

    # "(a, b)" - row constructor; parenthesized scalar for a single column.
    def tuple(cols, qualifier = nil)
      "(#{list(cols, qualifier)})"
    end

    # "l.a = r.x AND l.b = r.y" (qualifiers optional on either side)
    def eq(left_cols, right_cols, left: nil, right: nil)
      left_cols.zip(right_cols).map do |l, r|
        "#{"#{left}." if left}#{l} = #{"#{right}." if right}#{r}"
      end.join(' AND ')
    end

    # Column definitions typed after the node's pk columns.
    def col_defs(cols, not_null: true)
      cols.zip(pk_cols).map { |c, pk| "#{c} #{config.node_pk_type(pk)}#{' NOT NULL' if not_null}" }
    end

    # RAISE format for a node reference: '%' or '(%, %)'.
    def node_fmt
      pk_cols.length == 1 ? '%' : "(#{pk_cols.map { '%' }.join(', ')})"
    end

    def scoped?
      config.scope_columns.any?
    end

    # ", account_id bigint, region text" (leading comma) or ""
    def scope_column_defs
      config.scope_columns.map { |c| ",\n  #{c} #{config.scope_column_type(c)}" }.join
    end

    # ", account_id" / ", NEW.account_id" (leading comma) or ""
    def scope_column_list(qualifier = nil)
      config.scope_columns.map { |c| ", #{"#{qualifier}." if qualifier}#{c}" }.join
    end

    # Advisory-lock key for a row reference: COALESCE(row.account_id::text, '') || ':' || ...
    def scope_key_expr(row)
      return "''" unless scoped?

      config.scope_columns.map { |c| "COALESCE(#{row}.#{c}::text, '')" }.join(" || ':' || ")
    end

    def scope_distinct_expr(left, right)
      config.scope_columns.map { |c| "#{left}.#{c} IS DISTINCT FROM #{right}.#{c}" }.join(' OR ')
    end

    # Honors PostgreSQLAdapter.create_unlogged_tables (Rails test-env speed
    # setting): a logged table cannot FK-reference an unlogged node table.
    def create_table_clause
      if ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.create_unlogged_tables
        'CREATE UNLOGGED TABLE'
      else
        'CREATE TABLE'
      end
    end

    def edges_table_sql
      defs = (col_defs(parent_cols) + col_defs(child_cols)).map { |d| "  #{d}," }.join("\n")
      <<~SQL
        #{create_table_clause} #{config.edge_table} (
          id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
        #{defs}
          created_at timestamptz NOT NULL DEFAULT now()#{scope_column_defs},
          FOREIGN KEY #{tuple(parent_cols)} REFERENCES #{config.node_table} #{tuple(pk_cols)} ON DELETE CASCADE,
          FOREIGN KEY #{tuple(child_cols)} REFERENCES #{config.node_table} #{tuple(pk_cols)} ON DELETE CASCADE,
          UNIQUE (#{list(parent_cols)}, #{list(child_cols)}),
          CHECK (#{tuple(parent_cols)} <> #{tuple(child_cols)})
        );
        CREATE INDEX ON #{config.edge_table} (#{list(child_cols)}, #{list(parent_cols)});
      SQL
    end

    def paths_table_sql
      defs = (col_defs(anc_cols) + col_defs(desc_cols)).map { |d| "  #{d}," }.join("\n")
      <<~SQL
        #{create_table_clause} #{config.paths_table} (
        #{defs}
          min_depth integer NOT NULL,
          path_count numeric NOT NULL#{scope_column_defs},
          FOREIGN KEY #{tuple(anc_cols)} REFERENCES #{config.node_table} #{tuple(pk_cols)} ON DELETE CASCADE,
          FOREIGN KEY #{tuple(desc_cols)} REFERENCES #{config.node_table} #{tuple(pk_cols)} ON DELETE CASCADE,
          PRIMARY KEY (#{list(anc_cols)}, #{list(desc_cols)})
        );
        CREATE INDEX ON #{config.paths_table} (#{list(desc_cols)}, #{list(anc_cols)});
      SQL
    end

    # Every write path funnels through this. Lock-then-recheck needs a fresh
    # snapshot after the lock wait, so anything above READ COMMITTED is refused.
    def lock_function_sql
      <<~SQL
        CREATE OR REPLACE FUNCTION #{config.function_ref('lock')}(scope_key text) RETURNS void
        LANGUAGE plpgsql AS $$
        BEGIN
          IF current_setting('transaction_isolation') NOT IN ('read committed', 'read uncommitted') THEN
            RAISE EXCEPTION 'dag_me: writes require READ COMMITTED isolation, got %',
              current_setting('transaction_isolation')
              USING ERRCODE = '#{SQLSTATE_ISOLATION}';
          END IF;
          PERFORM pg_advisory_xact_lock(hashtextextended('dag_me:#{config.edge_table}:' || scope_key, 0));
        END;
        $$;
      SQL
    end

    # Scope preamble for the BEFORE INSERT edge check: fetch both node rows,
    # reject cross-scope edges, stamp NEW, and lock the scope. Unscoped graphs
    # just lock the single '' key.
    def edge_check_preamble
      return "  PERFORM #{config.function_ref('lock')}('');" unless scoped?

      stamps = config.scope_columns.map { |c| "  NEW.#{c} := parent_row.#{c};" }.join("\n")
      # FOR SHARE pins both node rows so a concurrent scope UPDATE cannot race
      # this edge into a cross-tenant graph.
      <<~SQL.chomp
          SELECT * INTO parent_row FROM #{config.node_table} WHERE #{eq(pk_cols, parent_cols, right: 'NEW')} FOR SHARE;
          SELECT * INTO child_row FROM #{config.node_table} WHERE #{eq(pk_cols, child_cols, right: 'NEW')} FOR SHARE;
          IF #{scope_distinct_expr('parent_row', 'child_row')} THEN
            RAISE EXCEPTION 'dag_me: edge #{node_fmt} -> #{node_fmt} crosses scope', #{list(parent_cols, 'NEW')}, #{list(child_cols, 'NEW')}
              USING ERRCODE = '#{SQLSTATE_CROSS_SCOPE}';
          END IF;
        #{stamps}
          PERFORM #{config.function_ref('lock')}(#{scope_key_expr('parent_row')});
      SQL
    end

    def edge_check_declarations
      return '' unless scoped?

      <<~SQL.chomp
        DECLARE
          parent_row #{config.node_table}%ROWTYPE;
          child_row #{config.node_table}%ROWTYPE;
      SQL
    end

    def cycle_raise_sql
      <<~SQL.chomp
        RAISE EXCEPTION 'dag_me: edge #{node_fmt} -> #{node_fmt} would create a cycle', #{list(parent_cols, 'NEW')}, #{list(child_cols, 'NEW')}
                USING ERRCODE = '#{SQLSTATE_CYCLE}';
      SQL
    end

    def closure_function_sql
      functions = [
        lock_function_sql,
        closure_edge_insert_check_sql,
        edge_insert_apply_sql,
        edge_delete_apply_sql,
        node_insert_function_sql,
        node_delete_function_sql
      ]
      functions << node_update_function_sql if scoped?
      functions
    end

    def closure_edge_insert_check_sql
      <<~SQL
        CREATE OR REPLACE FUNCTION #{config.function_ref('edge_insert_check')}() RETURNS trigger
        LANGUAGE plpgsql AS $$
        #{edge_check_declarations}
        BEGIN
        #{edge_check_preamble}
          IF EXISTS (
            SELECT 1 FROM #{config.paths_table}
            WHERE #{eq(anc_cols, child_cols, right: 'NEW')}
              AND #{eq(desc_cols, parent_cols, right: 'NEW')}
          ) THEN
            #{cycle_raise_sql}
          END IF;
          RETURN NEW;
        END;
        $$;
      SQL
    end

    def edge_insert_apply_sql
      paths = config.paths_table
      <<~SQL
        CREATE OR REPLACE FUNCTION #{config.function_ref('edge_insert_apply')}() RETURNS trigger
        LANGUAGE plpgsql AS $$
        BEGIN
          -- ancestors-incl-self of parent x descendants-incl-self of child
          INSERT INTO #{paths} (#{list(anc_cols)}, #{list(desc_cols)}, min_depth, path_count#{scope_column_list})
          SELECT #{list(anc_cols, 'a')}, #{list(desc_cols, 'd')},
                 a.min_depth + 1 + d.min_depth,
                 a.path_count * d.path_count#{scope_column_list('NEW')}
          FROM #{paths} a
          JOIN #{paths} d ON #{eq(anc_cols, child_cols, left: 'd', right: 'NEW')}
          WHERE #{eq(desc_cols, parent_cols, left: 'a', right: 'NEW')}
          ON CONFLICT (#{list(anc_cols)}, #{list(desc_cols)}) DO UPDATE
            SET path_count = #{paths}.path_count + EXCLUDED.path_count,
                min_depth = LEAST(#{paths}.min_depth, EXCLUDED.min_depth);
          RETURN NULL;
        END;
        $$;
      SQL
    end

    def edge_delete_apply_sql
      p = config.prefix
      edges = config.edge_table
      paths = config.paths_table
      x_cols = pk_cols.map { |c| "x_#{c}" }
      y_cols = pk_cols.map { |c| "y_#{c}" }
      rect_defs = (col_defs(x_cols) + col_defs(y_cols)).map { |d| "    #{d}," }.join("\n")
      <<~SQL
        CREATE OR REPLACE FUNCTION #{config.function_ref('edge_delete_apply')}() RETURNS trigger
        LANGUAGE plpgsql AS $$
        BEGIN
          PERFORM #{config.function_ref('lock')}(#{scope_key_expr('OLD')});

          -- The affected rectangle: every pair (x, y) with x reaching OLD's parent
          -- and OLD's child reaching y lost `removed` paths through this edge.
          -- Multipliers cannot themselves traverse the deleted edge (that would
          -- imply a cycle), so pre-decrement closure values are exact here.
          CREATE TEMP TABLE IF NOT EXISTS #{p}_delete_rect (
        #{rect_defs}
            removed numeric NOT NULL,
            via_depth integer NOT NULL,
            PRIMARY KEY (#{list(x_cols)}, #{list(y_cols)})
          ) ON COMMIT DROP;
          DELETE FROM #{p}_delete_rect;

          INSERT INTO #{p}_delete_rect (#{list(x_cols)}, #{list(y_cols)}, removed, via_depth)
          SELECT #{list(anc_cols, 'a')}, #{list(desc_cols, 'd')},
                 a.path_count * d.path_count,
                 a.min_depth + 1 + d.min_depth
          FROM #{paths} a
          JOIN #{paths} d ON #{eq(anc_cols, child_cols, left: 'd', right: 'OLD')}
          WHERE #{eq(desc_cols, parent_cols, left: 'a', right: 'OLD')};

          UPDATE #{paths} p
          SET path_count = p.path_count - r.removed
          FROM #{p}_delete_rect r
          WHERE #{eq(anc_cols, x_cols, left: 'p', right: 'r')}
            AND #{eq(desc_cols, y_cols, left: 'p', right: 'r')};

          DELETE FROM #{paths} p
          USING #{p}_delete_rect r
          WHERE #{eq(anc_cols, x_cols, left: 'p', right: 'r')}
            AND #{eq(desc_cols, y_cols, left: 'p', right: 'r')}
            AND p.path_count <= 0;

          -- min_depth repair: surviving rectangle pairs may have lost their
          -- shortest path. Iterate the recurrence
          --   min_depth(x, y) = min(1 + min_depth(c, y)) over edges x -> c reaching y
          -- until fixpoint; converges in at most longest-affected-chain steps.
          LOOP
            UPDATE #{paths} p
            SET min_depth = fix.new_md
            FROM (
              SELECT #{list(anc_cols, 's')}, #{list(desc_cols, 's')},
                     (SELECT MIN(1 + cp.min_depth)
                      FROM #{edges} e
                      JOIN #{paths} cp
                        ON #{eq(anc_cols, child_cols, left: 'cp', right: 'e')}
                       AND #{eq(desc_cols, desc_cols, left: 'cp', right: 's')}
                      WHERE #{eq(parent_cols, anc_cols, left: 'e', right: 's')}) AS new_md
              FROM #{paths} s
              JOIN #{p}_delete_rect r
                ON #{eq(x_cols, anc_cols, left: 'r', right: 's')}
               AND #{eq(y_cols, desc_cols, left: 'r', right: 's')}
              WHERE #{tuple(anc_cols, 's')} <> #{tuple(desc_cols, 's')}
            ) fix
            WHERE #{eq(anc_cols, anc_cols, left: 'p', right: 'fix')}
              AND #{eq(desc_cols, desc_cols, left: 'p', right: 'fix')}
              AND fix.new_md IS NOT NULL
              AND fix.new_md <> p.min_depth;
            EXIT WHEN NOT FOUND;
          END LOOP;

          RETURN NULL;
        END;
        $$;
      SQL
    end

    def node_insert_function_sql
      <<~SQL
        CREATE OR REPLACE FUNCTION #{config.function_ref('node_insert')}() RETURNS trigger
        LANGUAGE plpgsql AS $$
        BEGIN
          INSERT INTO #{config.paths_table} (#{list(anc_cols)}, #{list(desc_cols)}, min_depth, path_count#{scope_column_list})
          VALUES (#{list(pk_cols, 'NEW')}, #{list(pk_cols, 'NEW')}, 0, 1#{scope_column_list('NEW')});
          RETURN NULL;
        END;
        $$;
      SQL
    end

    def node_delete_function_sql
      <<~SQL
        CREATE OR REPLACE FUNCTION #{config.function_ref('node_delete')}() RETURNS trigger
        LANGUAGE plpgsql AS $$
        BEGIN
          PERFORM #{config.function_ref('lock')}(#{scope_key_expr('OLD')});
          -- Remove edges through their triggers so the closure shrinks
          -- incrementally instead of relying on FK-cascade ordering.
          DELETE FROM #{config.edge_table}
          WHERE (#{eq(parent_cols, pk_cols, right: 'OLD')}) OR (#{eq(child_cols, pk_cols, right: 'OLD')});
          DELETE FROM #{config.paths_table}
          WHERE #{eq(anc_cols, pk_cols, right: 'OLD')} AND #{eq(desc_cols, pk_cols, right: 'OLD')};
          RETURN OLD;
        END;
        $$;
      SQL
    end

    # Guards against re-tenanting a connected node: the closure never spans
    # scopes, so a scope change is only legal on an isolated node.
    def node_update_function_sql
      restamp = if config.closure?
                  updates = config.scope_columns.map { |c| "#{c} = NEW.#{c}" }.join(', ')
                  "UPDATE #{config.paths_table} SET #{updates} " \
                    "WHERE #{eq(anc_cols, pk_cols, right: 'OLD')} AND #{eq(desc_cols, pk_cols, right: 'OLD')};"
                else
                  '-- edges only: nothing materialized to restamp'
                end
      <<~SQL
        CREATE OR REPLACE FUNCTION #{config.function_ref('node_update')}() RETURNS trigger
        LANGUAGE plpgsql AS $$
        BEGIN
          IF #{scope_distinct_expr('NEW', 'OLD')} THEN
            IF EXISTS (
              SELECT 1 FROM #{config.edge_table}
              WHERE (#{eq(parent_cols, pk_cols, right: 'OLD')}) OR (#{eq(child_cols, pk_cols, right: 'OLD')})
            ) THEN
              RAISE EXCEPTION 'dag_me: cannot change scope of node #{node_fmt} while it has edges', #{list(pk_cols, 'OLD')}
                USING ERRCODE = '#{SQLSTATE_SCOPE_CHANGE}';
            END IF;
            #{restamp}
          END IF;
          RETURN NEW;
        END;
        $$;
      SQL
    end

    def closure_trigger_sql
      triggers = [
        trigger_sql('edge_insert_check', 'BEFORE INSERT', config.edge_table),
        trigger_sql('edge_insert_apply', 'AFTER INSERT', config.edge_table),
        trigger_sql('edge_delete_apply', 'AFTER DELETE', config.edge_table),
        trigger_sql('node_insert', 'AFTER INSERT', config.node_table),
        trigger_sql('node_delete', 'BEFORE DELETE', config.node_table)
      ]
      triggers << trigger_sql('node_update', 'BEFORE UPDATE', config.node_table) if scoped?
      triggers
    end

    # Trigger names are plain identifiers; the executed function carries the
    # schema qualification.
    def trigger_sql(suffix, timing, table)
      <<~SQL
        CREATE TRIGGER #{config.trigger_name(suffix)} #{timing} ON #{table}
          FOR EACH ROW EXECUTE FUNCTION #{config.function_ref(suffix)}();
      SQL
    end

    def truth_walk_sql
      <<~SQL.chomp
        WITH RECURSIVE walk(#{list(anc_cols)}, #{list(desc_cols)}, depth) AS (
          SELECT #{list(parent_cols)}, #{list(child_cols)}, 1 FROM #{config.edge_table}
          UNION ALL
          SELECT #{list(anc_cols, 'w')}, #{list(child_cols, 'e')}, w.depth + 1
          FROM walk w
          JOIN #{config.edge_table} e ON #{eq(parent_cols, desc_cols, left: 'e', right: 'w')}
        )
      SQL
    end

    def rebuild_function_sql
      scope_join = scoped? ? "JOIN #{config.node_table} n ON #{eq(pk_cols, anc_cols, left: 'n', right: 'walk')}" : ''
      scope_group = config.scope_columns.map { |c| ", n.#{c}" }.join
      <<~SQL
        CREATE OR REPLACE FUNCTION #{config.function_ref('rebuild_paths')}() RETURNS void
        LANGUAGE plpgsql AS $$
        BEGIN
          LOCK TABLE #{config.node_table}, #{config.edge_table} IN SHARE ROW EXCLUSIVE MODE;
          DELETE FROM #{config.paths_table};

          INSERT INTO #{config.paths_table} (#{list(anc_cols)}, #{list(desc_cols)}, min_depth, path_count#{scope_column_list})
          SELECT #{list(pk_cols)}, #{list(pk_cols)}, 0, 1#{scope_column_list} FROM #{config.node_table};

          #{truth_walk_sql}
          INSERT INTO #{config.paths_table} (#{list(anc_cols)}, #{list(desc_cols)}, min_depth, path_count#{scope_column_list})
          SELECT #{list(anc_cols, 'walk')}, #{list(desc_cols, 'walk')}, MIN(depth), COUNT(*)::numeric#{scope_group}
          FROM walk #{scope_join}
          GROUP BY #{list(anc_cols, 'walk')}, #{list(desc_cols, 'walk')}#{scope_group};
        END;
        $$;
      SQL
    end

    def validate_function_sql
      scope_join = scoped? ? "JOIN #{config.node_table} n ON #{eq(pk_cols, anc_cols, left: 'n', right: 'walk')}" : ''
      scope_group = config.scope_columns.map { |c| ", n.#{c}" }.join
      scope_mismatch = scoped? ? "OR #{scope_distinct_expr('s', 't')}" : ''
      returns = (col_defs(anc_cols, not_null: false) + col_defs(desc_cols, not_null: false))
                .map { |d| "  #{d}," }.join("\n")
      coalesced = (anc_cols + desc_cols).map { |c| "COALESCE(t.#{c}, s.#{c})" }.join(",\n                 ")
      <<~SQL
        CREATE OR REPLACE FUNCTION #{config.function_ref('validate_paths')}()
        RETURNS TABLE(
        #{returns}
          stored_min_depth integer,
          stored_path_count numeric,
          true_min_depth integer,
          true_path_count numeric
        )
        LANGUAGE sql AS $$
          #{truth_walk_sql}, truth AS (
            SELECT #{list(anc_cols, 'walk')}, #{list(desc_cols, 'walk')}, MIN(depth) AS min_depth, COUNT(*)::numeric AS path_count#{scope_group}
            FROM walk #{scope_join}
            GROUP BY #{list(anc_cols, 'walk')}, #{list(desc_cols, 'walk')}#{scope_group}
            UNION ALL
            SELECT #{list(pk_cols)}, #{list(pk_cols)}, 0, 1::numeric#{scope_column_list} FROM #{config.node_table}
          )
          SELECT #{coalesced},
                 s.min_depth, s.path_count,
                 t.min_depth, t.path_count
          FROM truth t
          FULL OUTER JOIN #{config.paths_table} s
            ON #{eq(anc_cols, anc_cols, left: 's', right: 't')}
           AND #{eq(desc_cols, desc_cols, left: 's', right: 't')}
          WHERE t.#{anc_cols.first} IS NULL
             OR s.#{anc_cols.first} IS NULL
             OR s.min_depth <> t.min_depth
             OR s.path_count <> t.path_count
             #{scope_mismatch};
        $$;
      SQL
    end

    def cte_function_sql
      functions = [lock_function_sql, cte_edge_insert_check_sql]
      functions << node_update_function_sql if scoped?
      functions
    end

    def cte_edge_insert_check_sql
      <<~SQL
        CREATE OR REPLACE FUNCTION #{config.function_ref('edge_insert_check')}() RETURNS trigger
        LANGUAGE plpgsql AS $$
        #{edge_check_declarations}
        BEGIN
        #{edge_check_preamble}
          IF EXISTS (
            WITH RECURSIVE walk(#{list(pk_cols)}) AS (
              SELECT #{list(child_cols)} FROM #{config.edge_table} WHERE #{eq(parent_cols, child_cols, right: 'NEW')}
              UNION
              SELECT #{list(child_cols, 'e')} FROM #{config.edge_table} e JOIN walk w ON #{eq(parent_cols, pk_cols, left: 'e', right: 'w')}
            )
            SELECT 1 FROM walk WHERE #{eq(pk_cols, parent_cols, right: 'NEW')}
          ) THEN
            #{cycle_raise_sql}
          END IF;
          RETURN NEW;
        END;
        $$;
      SQL
    end

    def cte_trigger_sql
      triggers = [trigger_sql('edge_insert_check', 'BEFORE INSERT', config.edge_table)]
      triggers << trigger_sql('node_update', 'BEFORE UPDATE', config.node_table) if scoped?
      triggers
    end
  end
end
