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
  #   task_dag_validate_paths()   -- stored closure vs closure recomputed from edges
  #
  # rebuild and validate share truth_sql: a layered recomputation that is
  # polynomial in the graph size. Function bodies are stamped with REVISION;
  # refresh! upgrades an installed graph in place.
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
    # Bumped whenever generated function bodies change. Stamped onto the lock
    # function, so `dag_me:status` can spot installs that predate a fix.
    REVISION = 2

    # Free space left in every closure page. Writes update path_count and
    # min_depth, neither indexed, so with room on the page PostgreSQL can
    # update in place (HOT) and skip both index inserts: on a dense
    # 1,000-node graph that took HOT updates from 27% to 97% and halved
    # mid-graph edge writes.
    PATHS_FILLFACTOR = 70

    class << self
      # Installs / removes the SQL objects for every dag the model declares.
      def install!(model)
        model.dag_configs.each_value { |config| new(config).install! }
      end

      def uninstall!(model)
        model.dag_configs.each_value { |config| new(config).uninstall! }
      end

      # Replaces the function bodies of an installed graph with the current
      # revision. Tables, triggers, and data are left alone.
      def refresh!(model)
        model.dag_configs.each_value { |config| new(config).refresh! }
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

    # Function bodies plus the closure's storage settings. Tables, triggers,
    # and rows are left alone; existing pages gain free space as they are
    # rewritten (VACUUM FULL, or rows updated over time).
    def refresh!
      execute_all(function_sql + storage_sql)
    end

    def storage_sql
      return [] unless config.closure?

      ["ALTER TABLE #{config.paths_table} SET (fillfactor = #{PATHS_FILLFACTOR});"]
    end

    def install_sql
      statements = [edges_table_sql]
      statements << paths_table_sql if config.closure?
      statements.concat(function_sql)
      statements.concat(config.closure? ? closure_trigger_sql : cte_trigger_sql)
      statements << backfill_self_rows_sql if config.closure?
      statements
    end

    # Every function as CREATE OR REPLACE, plus the revision stamp. Re-running
    # it on an installed graph is how refresh! upgrades in place.
    def function_sql
      statements = if config.closure?
                     closure_function_sql + [rebuild_function_sql, validate_function_sql]
                   else
                     cte_function_sql
                   end
      statements << revision_comment_sql
    end

    def revision_comment_sql
      "COMMENT ON FUNCTION #{config.function_ref('lock')}(text) IS '#{self.class.revision_tag}';"
    end

    def self.revision_tag
      "dag_me ddl revision #{REVISION}"
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
        ) WITH (fillfactor = #{PATHS_FILLFACTOR});
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

    def x_cols
      pk_cols.map { |c| "x_#{c}" }
    end

    def y_cols
      pk_cols.map { |c| "y_#{c}" }
    end

    # Every pair (x, y) whose paths run through the edge `row` (NEW or OLD):
    # x reaches the edge's parent, the edge's child reaches y. `through` is
    # how many x -> y paths use the edge, `via_depth` the shortest of them.
    def through_edge_sql(row)
      x = anc_cols.zip(x_cols).map { |a, c| "a.#{a} AS #{c}" }.join(', ')
      y = desc_cols.zip(y_cols).map { |d, c| "d.#{d} AS #{c}" }.join(', ')
      <<~SQL.chomp
        SELECT #{x}, #{y},
                 a.path_count * d.path_count AS through,
                 a.min_depth + 1 + d.min_depth AS via_depth
          FROM #{config.paths_table} a
          JOIN #{config.paths_table} d ON #{eq(anc_cols, child_cols, left: 'd', right: row)}
          WHERE #{eq(desc_cols, parent_cols, left: 'a', right: row)}
      SQL
    end

    # "p.ancestor_id = r.x_id AND p.descendant_id = r.y_id"
    def pair_match(row = 'r', target: 'p')
      "#{eq(anc_cols, x_cols, left: target, right: row)} AND #{eq(desc_cols, y_cols, left: target, right: row)}"
    end

    # Shortest distance from w's x to w's y over x's remaining out-edges.
    def recomputed_depth_sql(row)
      <<~SQL.chomp
        SELECT MIN(1 + cp.min_depth) AS new_depth
              FROM #{config.edge_table} e
              JOIN #{config.paths_table} cp
                ON #{eq(anc_cols, child_cols, left: 'cp', right: 'e')}
               AND #{eq(desc_cols, y_cols, left: 'cp', right: row)}
              WHERE #{eq(parent_cols, x_cols, left: 'e', right: row)}
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
      paths = config.paths_table
      edges = config.edge_table
      work_defs = (col_defs(x_cols) + col_defs(y_cols)).map { |d| "    #{d}" }.join(",\n")
      <<~SQL
        CREATE OR REPLACE FUNCTION #{config.function_ref('edge_delete_apply')}() RETURNS trigger
        LANGUAGE plpgsql AS $$
        BEGIN
          PERFORM #{config.function_ref('lock')}(#{scope_key_expr('OLD')});

          -- Every pair through the deleted edge loses `through` paths: pairs
          -- left with none are dropped, the rest decremented. Multipliers
          -- cannot traverse the deleted edge (that would imply a cycle), so
          -- the closure rows they come from are untouched here.
          WITH r AS MATERIALIZED (
            #{through_edge_sql('OLD')}
          ),
          gone AS (
            DELETE FROM #{paths} p USING r
            WHERE #{pair_match} AND p.path_count <= r.through
          )
          UPDATE #{paths} p
          SET path_count = p.path_count - r.through
          FROM r
          WHERE #{pair_match} AND p.path_count > r.through;

          -- min_depth repair. Only a surviving pair whose shortest path ran
          -- through the edge (min_depth = via_depth) can get longer:
          --   min_depth(x, y) = min(1 + min_depth(c, y)) over edges x -> c
          -- Pairs that change go to a worklist; their parents' pairs are
          -- recomputed until nothing changes. Values only grow, from below.
          CREATE TEMP TABLE IF NOT EXISTS #{p}_depth_work (
        #{work_defs}
          ) ON COMMIT DROP;
          DELETE FROM #{p}_depth_work;

          WITH r AS MATERIALIZED (
            #{through_edge_sql('OLD')}
          ),
          raised AS (
            UPDATE #{paths} p
            SET min_depth = m.new_depth
            FROM r
            CROSS JOIN LATERAL (
              #{recomputed_depth_sql('r')}
            ) m
            WHERE #{pair_match}
              AND p.min_depth = r.via_depth
              AND m.new_depth > p.min_depth
            RETURNING #{list(anc_cols, 'p')}, #{list(desc_cols, 'p')}
          )
          INSERT INTO #{p}_depth_work SELECT * FROM raised;

          WHILE EXISTS (SELECT 1 FROM #{p}_depth_work) LOOP
            WITH done AS (
              DELETE FROM #{p}_depth_work RETURNING *
            ),
            w AS (
              SELECT DISTINCT #{parent_cols.zip(x_cols).map { |pc, x| "e.#{pc} AS #{x}" }.join(', ')}, #{list(y_cols, 'd')}
              FROM done d
              JOIN #{edges} e ON #{eq(child_cols, x_cols, left: 'e', right: 'd')}
            ),
            raised AS (
              UPDATE #{paths} p
              SET min_depth = m.new_depth
              FROM w
              CROSS JOIN LATERAL (
                #{recomputed_depth_sql('w')}
              ) m
              WHERE #{pair_match('w')}
                AND m.new_depth > p.min_depth
              RETURNING #{list(anc_cols, 'p')}, #{list(desc_cols, 'p')}
            )
            INSERT INTO #{p}_depth_work SELECT * FROM raised;
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

    # Scratch tables for truth_sql: one row per node with its layer, and the
    # closure being computed. Temp, dropped at commit.
    def truth_scratch_sql
      p = config.prefix
      layer_defs = col_defs(pk_cols).map { |d| "  #{d}," }.join("\n")
      truth_defs = (col_defs(anc_cols) + col_defs(desc_cols)).map { |d| "  #{d}," }.join("\n")
      <<~SQL.chomp
        CREATE TEMP TABLE IF NOT EXISTS #{p}_layer (
        #{layer_defs}
          layer integer NOT NULL,
          PRIMARY KEY (#{list(pk_cols)})
        ) ON COMMIT DROP;
        CREATE INDEX IF NOT EXISTS #{p}_layer_by_layer ON #{p}_layer (layer);
        DELETE FROM #{p}_layer;
        CREATE TEMP TABLE IF NOT EXISTS #{p}_truth (
        #{truth_defs}
          min_depth integer NOT NULL,
          path_count numeric NOT NULL,
          PRIMARY KEY (#{list(desc_cols)}, #{list(anc_cols)})
        ) ON COMMIT DROP;
        DELETE FROM #{p}_truth;
      SQL
    end

    # Computes the exact closure from the edges into <prefix>_truth, without
    # walking paths one by one (path counts grow exponentially with every
    # diamond, so an enumerating walk does too).
    #
    # Nodes are layered by their longest distance from a root, one set-based
    # INSERT per layer. Every parent of a layer-L node sits in a lower layer,
    # so one aggregate per layer extends the parents' finished rows:
    #
    #   path_count(a, v) = sum of path_count(a, u) over edges u -> v
    #   min_depth(a, v)  = 1 + min of min_depth(a, u) over edges u -> v
    #
    # Nodes left without a layer sit on or below a cycle, which only edges
    # written with triggers disabled can produce: raise DGME1.
    #
    # Expects `depth integer` declared by the enclosing function.
    def truth_sql
      p = config.prefix
      edges = config.edge_table
      node = config.node_table
      <<~SQL.chomp
        #{truth_scratch_sql}

        INSERT INTO #{p}_layer (#{list(pk_cols)}, layer)
        SELECT #{list(pk_cols, 'n')}, 0 FROM #{node} n
        WHERE NOT EXISTS (SELECT 1 FROM #{edges} e WHERE #{eq(child_cols, pk_cols, left: 'e', right: 'n')});

        depth := 0;
        LOOP
          depth := depth + 1;
          -- children of the previous layer whose parents all have a layer
          INSERT INTO #{p}_layer (#{list(pk_cols)}, layer)
          SELECT DISTINCT #{list(child_cols, 'e')}, depth
          FROM #{p}_layer f
          JOIN #{edges} e ON #{eq(parent_cols, pk_cols, left: 'e', right: 'f')}
          WHERE f.layer = depth - 1
            AND NOT EXISTS (
              SELECT 1 FROM #{edges} w
              WHERE #{eq(child_cols, child_cols, left: 'w', right: 'e')}
                AND NOT EXISTS (SELECT 1 FROM #{p}_layer q WHERE #{eq(pk_cols, parent_cols, left: 'q', right: 'w')})
            );
          EXIT WHEN NOT FOUND;
        END LOOP;

        IF (SELECT count(*) FROM #{p}_layer) < (SELECT count(*) FROM #{node}) THEN
          RAISE EXCEPTION 'dag_me: % contains a cycle (edges written with triggers disabled?)', '#{edges}'
            USING ERRCODE = '#{SQLSTATE_CYCLE}';
        END IF;

        INSERT INTO #{p}_truth (#{list(anc_cols)}, #{list(desc_cols)}, min_depth, path_count)
        SELECT #{list(pk_cols)}, #{list(pk_cols)}, 0, 1 FROM #{node};

        FOR step IN 1 .. depth - 1 LOOP
          INSERT INTO #{p}_truth (#{list(anc_cols)}, #{list(desc_cols)}, min_depth, path_count)
          SELECT #{list(anc_cols, 't')}, #{list(child_cols, 'e')}, MIN(t.min_depth) + 1, SUM(t.path_count)
          FROM #{p}_layer v
          JOIN #{edges} e ON #{eq(child_cols, pk_cols, left: 'e', right: 'v')}
          JOIN #{p}_truth t ON #{eq(desc_cols, parent_cols, left: 't', right: 'e')}
          WHERE v.layer = step
          GROUP BY #{list(anc_cols, 't')}, #{list(child_cols, 'e')};
        END LOOP;
      SQL
    end

    # ", n.account_id" (leading comma) or "" - scope taken from the ancestor
    # node, joined as `n` by truth_scope_join.
    def truth_scope_select
      config.scope_columns.map { |c| ", n.#{c}" }.join
    end

    def truth_scope_join
      return '' unless scoped?

      " JOIN #{config.node_table} n ON #{eq(pk_cols, anc_cols, left: 'n', right: 't')}"
    end

    def rebuild_function_sql
      <<~SQL
        CREATE OR REPLACE FUNCTION #{config.function_ref('rebuild_paths')}() RETURNS void
        LANGUAGE plpgsql AS $$
        DECLARE
          depth integer;
        BEGIN
          LOCK TABLE #{config.node_table}, #{config.edge_table} IN SHARE ROW EXCLUSIVE MODE;

        #{truth_sql.gsub(/^/, '  ')}

          DELETE FROM #{config.paths_table};
          INSERT INTO #{config.paths_table} (#{list(anc_cols)}, #{list(desc_cols)}, min_depth, path_count#{scope_column_list})
          SELECT #{list(anc_cols, 't')}, #{list(desc_cols, 't')}, t.min_depth, t.path_count#{truth_scope_select}
          FROM #{config.prefix}_truth t#{truth_scope_join};
        END;
        $$;
      SQL
    end

    # The truth is computed across several statements. Inside a REPEATABLE
    # READ (or stricter) transaction they share one snapshot; under READ
    # COMMITTED each statement would see fresh data, so writers are held off
    # with SHARE locks for the duration instead.
    def validate_function_sql
      scope_mismatch = scoped? ? "OR #{scope_distinct_expr('s', 't')}" : ''
      returns = (col_defs(anc_cols, not_null: false) + col_defs(desc_cols, not_null: false))
                .map { |d| "  #{d}," }.join("\n")
      coalesced = (anc_cols + desc_cols).map { |c| "COALESCE(t.#{c}, s.#{c})" }.join(",\n                 ")
      truth = if scoped?
                "(SELECT t.*#{truth_scope_select} FROM #{config.prefix}_truth t#{truth_scope_join})"
              else
                "#{config.prefix}_truth"
              end
      <<~SQL
        CREATE OR REPLACE FUNCTION #{config.function_ref('validate_paths')}()
        RETURNS TABLE(
        #{returns}
          stored_min_depth integer,
          stored_path_count numeric,
          true_min_depth integer,
          true_path_count numeric
        )
        LANGUAGE plpgsql AS $$
        #variable_conflict use_column
        DECLARE
          depth integer;
        BEGIN
          IF current_setting('transaction_isolation') IN ('read committed', 'read uncommitted') THEN
            LOCK TABLE #{config.node_table}, #{config.edge_table} IN SHARE MODE;
          END IF;

        #{truth_sql.gsub(/^/, '  ')}

          RETURN QUERY
          SELECT #{coalesced},
                 s.min_depth, s.path_count,
                 t.min_depth, t.path_count
          FROM #{truth} t
          FULL OUTER JOIN #{config.paths_table} s
            ON #{eq(anc_cols, anc_cols, left: 's', right: 't')}
           AND #{eq(desc_cols, desc_cols, left: 's', right: 't')}
          WHERE t.#{anc_cols.first} IS NULL
             OR s.#{anc_cols.first} IS NULL
             OR s.min_depth <> t.min_depth
             OR s.path_count <> t.path_count
             #{scope_mismatch};
        END;
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
