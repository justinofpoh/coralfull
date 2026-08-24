SERVICE_NAME := coralfull-backend
BINARY_NAME  := bin/$(SERVICE_NAME)
MAIN_PACKAGE := ./cmd/apiserver

SHELL := /bin/bash

.PHONY: help
help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

.PHONY: build
build: ## Build the application binary
	go build -o $(BINARY_NAME) $(MAIN_PACKAGE)

.PHONY: run
run: ## Run the application server
	go run $(MAIN_PACKAGE) server

.PHONY: config
config: ## Show resolved configuration
	go run $(MAIN_PACKAGE) config

.PHONY: test
test: ## Run tests
	go test -race ./...

.PHONY: lint
lint: ## Run gofmt check and go vet
	@test -z "$$(gofmt -l . | tee /dev/stderr)" || (echo "gofmt needed"; exit 1)
	go vet ./...

.PHONY: tidy
tidy: ## Run go mod tidy
	go mod tidy

.PHONY: db-up
db-up: ## Start Postgres and wait for it to be healthy
	docker compose up -d --wait db

.PHONY: db-down
db-down: ## Stop Postgres
	docker compose down

.PHONY: clean
clean: ## Clean build artifacts
	@rm -rf bin/
	@go clean

.PHONY: migration-up
migration-up: ## Run database migrations up
	go run $(MAIN_PACKAGE) migrate up

.PHONY: migration-down
migration-down: ## Run database migrations down
	go run $(MAIN_PACKAGE) migrate down

.PHONY: migration-force
migration-force: ## Force migration version (usage: make migration-force V=1)
	go run $(MAIN_PACKAGE) migrate force $(V)

.PHONY: migration-version
migration-version: ## Print current migration version
	go run $(MAIN_PACKAGE) migrate version

.PHONY: migration-create
migration-create: ## Create a migration (usage: make migration-create NAME=add_thing)
	@if [ -z "$(NAME)" ]; then echo "Error: NAME is required"; exit 1; fi
	migrate create -ext sql -dir cmd/apiserver/app/migrations -seq $(NAME)
