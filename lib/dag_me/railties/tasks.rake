# frozen_string_literal: true

namespace :dag_me do
  desc 'Report the health of every dag_me model (tables, triggers, functions, closure)'
  task status: :environment do
    Rails.application.eager_load!
    models = ActiveRecord::Base.descendants.select { |klass| klass.include?(DagMe::Model) }
    DagMe::TaskHelpers.status(models)
  end

  desc 'Rebuild the closure table for every dag_me model (or MODEL=Task for one)'
  task rebuild: :environment do
    Rails.application.eager_load!
    models = if ENV['MODEL']
               model = ENV['MODEL'].constantize
               abort "#{model.name} is not a dag_me model (no dag_me call)" unless model.include?(DagMe::Model)
               [model]
             else
               ActiveRecord::Base.descendants.select { |klass| klass.include?(DagMe::Model) }
             end
    models.each do |model|
      print "Rebuilding #{model.name}... "
      model.dag_configs.each_value { |config| model.dag(config.name).rebuild! }
      puts 'done'
    end
  end
end
