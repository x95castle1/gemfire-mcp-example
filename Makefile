# GemFire MCP lab: run `make` to see the targets.
# Each target echoes the command it runs, so you can see what's underneath.
.DEFAULT_GOAL := help
SHELL := /bin/bash

COMPOSE := docker compose
# --profile '*' = every profile, so stop/status/logs also see optional services
ALL := $(COMPOSE) --profile '*'

.PHONY: help start stop clean status logs tools call seaweed

help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-z]+:.*## / { printf "  \033[36m%-8s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

start: ## Start cluster + S3 store + telemetry forwarder + MCP server (:8085/mcp)
	@[ -f .env ] || { cp .env.example .env; echo "Created .env from .env.example"; }
	$(COMPOSE) up -d --wait locator server-1 server-2 server-3
	$(COMPOSE) run --rm gemfire-init 2>&1 | awk '/^Command-/ {sub(/^Command-[0-9]+ *: */, ""); cmd=$$0} /^Status/ {print "  " $$NF "  " cmd}'
	$(COMPOSE) --profile telemetry up -d --build telemetry-forwarder
	$(COMPOSE) --profile mcp up -d --build --wait mcp-server

stop: ## Stop and remove containers (keeps ./data)
	$(ALL) down --remove-orphans

clean: stop ## Stop + delete ./data (logs, stats, telemetry store)
	rm -rf data

status: ## Show containers and health
	$(ALL) ps -a --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}'

logs: ## Follow logs: pick a container (fzf), or make logs S=mcp-server
	@s="$(S)"; \
	if [ -z "$$s" ]; then \
	  s=$$( { echo "(all)"; $(ALL) ps -a --services; } | fzf --height=40% --reverse --header "Follow logs for… (Ctrl-C to stop following)") || exit 0; \
	  [ "$$s" = "(all)" ] && s=""; \
	fi; \
	echo "$(ALL) logs -f --tail=50 $$s"; \
	$(ALL) logs -f --tail=50 $$s

tools: ## List the MCP tools (raw JSON-RPC)
	scripts/mcp-curl.sh tools

call: ## Call a tool: menu (fzf), or make call T=list_members [A='{"role":"servers"}']
	@if [ -z "$(T)" ]; then scripts/mcp-curl.sh pick; else scripts/mcp-curl.sh call $(T) '$(A)'; fi

seaweed: ## Open the SeaweedFS file browser on the telemetry bucket
	open http://localhost:8888/buckets/gemfire-telemetry/gfmcp/
