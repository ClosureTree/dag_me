.PHONY: up down restart ps test lint check erd

up:
	docker compose up -d --wait

down:
	docker compose down

restart: down up

ps:
	docker compose ps

test:
	bundle exec rake test

lint:
	bundle exec rubocop

check: lint test

erd:
	cd test/dummy && RAILS_ENV=test BUNDLE_GEMFILE=../../Gemfile bundle exec rails_lens erd --output tmp/erd
