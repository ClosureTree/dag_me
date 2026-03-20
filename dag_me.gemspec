# frozen_string_literal: true

require_relative 'lib/dag_me/version'

Gem::Specification.new do |spec|
  spec.name = 'dag_me'
  spec.version = DagMe::VERSION
  spec.authors = ['Abdelkader Boudih']
  spec.email = ['foss@seuros.com']

  spec.summary = 'Multi-parent DAGs for ActiveRecord, powered by PostgreSQL 18+'
  spec.description = 'Directed Acyclic Graph Management Engine for ActiveRecord. Edges as source of truth, ' \
                     'transitive closure maintained by PL/pgSQL triggers. Cycle rejection, ' \
                     'ancestors/descendants, topological ordering. PostgreSQL 18+ only.'
  spec.homepage = 'https://github.com/ClosureTree/dag_me'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.4'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/master/CHANGELOG.md"
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir['lib/**/*', 'MIT-LICENSE', 'README.md', 'CHANGELOG.md'].select { |f| File.file?(f) }
  spec.require_paths = ['lib']

  spec.add_dependency 'activerecord', '>= 8.1'
  spec.add_dependency 'pg', '>= 1.6'
end
