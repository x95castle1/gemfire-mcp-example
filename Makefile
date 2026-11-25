# GemFire MCP lab: run `make` to see the targets.
# Each target echoes the command it runs, so you can see what's underneath.
.DEFAULT_GOAL := help
SHELL := /bin/bash

COMPOSE := docker compose
# --profile '*' = every profile, so stop/status/logs also see optional services
ALL := $(COMPOSE) --profile '*'

.PHONY: help start stop clean status logs tools call seaweed inspector load chaos heal grafana-ui sre

help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-z-]+:.*## / { printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

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
	  s=$$( . scripts/ui.sh; { echo "(all)"; $(ALL) ps -a --services; } \
	    | ui_fzf "make logs" --height=70% --header "Follow logs for… (Ctrl-C to stop following)" \
	        --preview 'scripts/preview.sh logs {1}') || exit 0; \
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

inspector: ## Open MCP Inspector (web UI), already connected to the GemFire MCP server
	$(COMPOSE) --profile inspector up -d inspector
	@# Inspector makes a new auth token on every start and prints the URL (with token) in its log
	@url=""; for i in $$(seq 1 30); do \
	  url=$$($(COMPOSE) --profile inspector logs --no-log-prefix inspector 2>/dev/null | grep -oE 'http://localhost:6274\?MCP_INSPECTOR_API_TOKEN=[0-9a-f]+' | tail -1); \
	  [ -n "$$url" ] && break; sleep 1; done; \
	[ -n "$$url" ] || { echo "Inspector didn't print its URL yet: make logs S=inspector"; exit 1; }; \
	echo "open $$url"; open "$$url"

load: ## Drive GemFire traffic: pick a scenario (fzf), or make load P=burst
	@curl -fs -o /dev/null http://localhost:18090/actuator/health || { \
	  echo "Starting the workload app (first build downloads dependencies, ~1-3 min)..."; \
	  echo "$(COMPOSE) --profile workload up -d --build --wait workload"; \
	  $(COMPOSE) --profile workload up -d --build --wait workload || exit 1; }
	@p="$(P)"; \
	if [ -z "$$p" ]; then \
	  p=$$( . scripts/ui.sh; \
	    curl -fs http://localhost:18090/scenarios \
	    | jq -r --arg grn "$$ui_grn" --arg yel "$$ui_yel" --arg d "$$ui_d" --arg r "$$ui_r" \
	        'to_entries[] | (if (.key | test("burst|hot-key|heap-hog")) then $$yel else $$grn end) as $$c | "\($$c)\(.key)\($$r)\t\($$d)\(.value)\($$r)"' \
	    | ui_fzf "make load" --height=70% --delimiter='\t' --with-nth=1 \
	        --header "Workload scenario (now: $$(curl -fs http://localhost:18090/status | jq -r .scenario))" \
	        --preview 'scripts/preview.sh load {1}' \
	    | cut -f1) || exit 0; \
	fi; \
	[ -n "$$p" ] || exit 0; \
	echo "curl -X POST http://localhost:18090/scenario/$$p"; \
	curl -sS -X POST http://localhost:18090/scenario/$$p | jq .

chaos: ## Break something: pick a failure (fzf), or make chaos C=kill M=server-2
	@if [ -z "$(C)" ]; then scripts/chaos.sh pick; else scripts/chaos.sh $(C) $(M); fi

heal: ## Undo all chaos: unpause, reconnect, start stopped members, wait for healthy
	@scripts/chaos.sh heal

grafana-ui: ## Start Prometheus + Loki + Alloy + Grafana and open the lab dashboard (no login)
	$(COMPOSE) --profile observability up -d --wait prometheus loki alloy grafana
	open http://localhost:13000/d/gfmcp-lab

sre: ## Start the SRE assistant, our own MCP client (Claude or Qwen), and open it (:18080)
	$(COMPOSE) --profile mcp --profile assistant up -d --build --wait sre-assistant
	open http://localhost:18080
