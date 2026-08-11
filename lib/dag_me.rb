# frozen_string_literal: true

require 'active_support'
require 'active_record'

require_relative 'dag_me/version'
require_relative 'dag_me/errors'
require 'dag_me/railtie' if defined?(Rails)

module DagMe
  extend ActiveSupport::Autoload

  # Rails main (8.2) made Arel::Table.new keyword-only.
  KEYWORD_AREL_TABLE = Arel::Table.instance_method(:initialize).parameters.none? do |type, _name|
    %i[req opt].include?(type)
  end

  def self.arel_table(name)
    KEYWORD_AREL_TABLE ? Arel::Table.new(name: name) : Arel::Table.new(name)
  end

  autoload :Configuration
  autoload :DDL
  autoload :Graph
  autoload :Macro
  autoload :Model
  autoload :TaskHelpers
  autoload :TestHelper

  module Adapters
    extend ActiveSupport::Autoload

    autoload :Base
    autoload :PostgresqlClosure
    autoload :RecursiveCte
  end
end

ActiveSupport.on_load(:active_record) do
  extend DagMe::Macro
end
