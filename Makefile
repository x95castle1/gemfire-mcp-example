# GemFire MCP lab: run `make` to see the targets.
# Each target echoes the command it runs, so you can see what's underneath.
.DEFAULT_GOAL := help
SHELL := /bin/bash

COMPOSE := docker compose
# --profile '*' = every profile, so stop/status/logs also see optional services
ALL := $(COMPOSE) --profile '*'

.PHONY: help start stop clean status logs tools call

help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-z]+:.*## / { printf "  \033[36m%-8s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

start: ## Start the cluster + MCP server (http://localhost:8085/mcp)
	@[ -f .env ] || { cp .env.example .env; echo "Created .env from .env.example"; }
	$(COMPOSE) up -d --wait locator server-1 server-2 server-3
	$(COMPOSE) run --rm gemfire-init 2>&1 | awk '/^Command-/ {sub(/^Command-[0-9]+ *: */, ""); cmd=$$0} /^Status/ {print "  " $$NF "  " cmd}'
	$(COMPOSE) --profile mcp up -d --build --wait mcp-server

stop: ## Stop and remove containers (keeps ./data)
	$(ALL) down --remove-orphans

clean: stop ## Stop + delete ./data (logs, stats, telemetry store)
	rm -rf data

status: ## Show containers and health
	$(ALL) ps -a --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}'

logs: ## Follow logs: make logs [S=mcp-server]
	$(ALL) logs -f --tail=50 $(S)

tools: ## List the MCP tools (raw JSON-RPC)
	scripts/mcp-curl.sh tools

call: ## Call a tool: make call T=list_members [A='{"role":"server"}']
	@[ -n "$(T)" ] || { echo "usage: make call T=<tool> [A='<json args>']"; exit 2; }
	scripts/mcp-curl.sh call $(T) '$(A)'
