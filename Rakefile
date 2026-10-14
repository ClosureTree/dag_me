# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'shellwords'

# padded_cell: test classes in parallel workers, every test in its own
# forked cell. Arguments in ARGS:
#   rake test ARGS="-j 4 test/dag_me/basic_test.rb:12"
desc 'Run the test suite with padded_cell (arguments in ARGS)'
task :test do
  sh 'bundle', 'exec', 'padded_cell', '--isolation', 'test', *Shellwords.split(ENV.fetch('ARGS', ''))
end

task default: :test
