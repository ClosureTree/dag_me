# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

# 8.1.4's fixture foreign-key check casts unqualified table names to
# regclass, so it can't find tables outside search_path (orbital.*).
# Fixed in rails/rails#58875; drop this once 8.1.5 ships.
gem 'activerecord', '!= 8.1.4'
gem 'debug'
gem 'mermaid' # rails_lens erd backend
gem 'minitest'
gem 'minitest-reporters'
gem 'rails_lens', require: false
gem 'railties', '>= 8.1', '!= 8.1.4'
gem 'rake'
gem 'vial', '>= 0.2026.8.6.0'
