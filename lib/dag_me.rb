# frozen_string_literal: true

require 'active_support'
require 'active_record'

require_relative 'dag_me/version'
require_relative 'dag_me/errors'
require 'dag_me/railtie' if defined?(Rails)

module DagMe
  extend ActiveSupport::Autoload

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
