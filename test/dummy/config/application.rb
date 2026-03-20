# frozen_string_literal: true

require 'rails'
require 'active_record/railtie'

Bundler.require(*Rails.groups)

require 'dag_me'

module Dummy
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f
    config.root = File.expand_path('..', __dir__)
    config.eager_load = false
    config.logger = ActiveSupport::Logger.new(File::NULL)
    config.secret_key_base = 'dummy'
    config.active_record.schema_format = :sql
  end
end
