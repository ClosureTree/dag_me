# frozen_string_literal: true

module DagMe
  class Error < StandardError; end

  # Raised when inserting an edge would make the graph cyclic. The rejection
  # itself happens in the database trigger; this wraps the PG exception.
  class CycleError < Error; end

  # Raised when an edge would connect nodes in different scopes, or when a
  # connected node's scope columns are changed.
  class ScopeError < Error; end

  # Raised when a write runs above READ COMMITTED: lock-then-recheck needs a
  # fresh snapshot after the lock wait.
  class IsolationError < Error; end

  # Raised by Graph#validate! when the stored closure disagrees with the
  # recursive-CTE truth. Carries the offending rows.
  class CorruptionError < Error
    attr_reader :discrepancies

    def initialize(message, discrepancies = [])
      super(message)
      @discrepancies = discrepancies
    end
  end

  # The triggers raise with these custom SQLSTATEs, so translation does not
  # depend on message wording.
  SQLSTATE_CYCLE = 'DGME1'
  SQLSTATE_CROSS_SCOPE = 'DGME2'
  SQLSTATE_SCOPE_CHANGE = 'DGME3'
  SQLSTATE_ISOLATION = 'DGME4'

  SQLSTATE_ERRORS = {
    SQLSTATE_CYCLE => CycleError,
    SQLSTATE_CROSS_SCOPE => ScopeError,
    SQLSTATE_SCOPE_CHANGE => ScopeError,
    SQLSTATE_ISOLATION => IsolationError
  }.freeze

  module_function

  def translate_errors
    yield
  rescue ActiveRecord::StatementInvalid => e
    error_class = SQLSTATE_ERRORS[sqlstate(e)]
    raise error_class, e.message if error_class

    raise
  end

  def sqlstate(error)
    cause = error.cause
    return unless cause.respond_to?(:result) && cause.result

    cause.result.error_field(PG::PG_DIAG_SQLSTATE)
  end
end
