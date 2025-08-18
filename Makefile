-include .env

.PHONY: slither slither-json slither-sarif slither-html slither-summary slither-install slither-docker remappings all test clean deploy fund help install snapshot format anvil

help:
	@echo ""
	@echo "Usage:"
	@echo "  make <command> [ARGS=...]"
	@echo "Arguments:"
	@echo "  ARGS=ethereumSepolia       Use testnet configuration (Ethereum Sepolia)."
	@echo "  ARGS=ethereum|polygon      Use mainnet configuration (Ethereum, Polygon)."
	@echo "  [no ARGS]                  Defaults to local anvil setup."
	@echo ""
	@echo "Static Analysis (Slither):"
	@echo "  slither                    Run Slither analysis on SinglePoolStaking (default target)."
	@echo "  slither-json               Run Slither and write JSON report to slither.report.json."
	@echo "  slither-sarif              Run Slither and write SARIF report to slither.report.sarif."
	@echo "  slither-html               Run Slither and write HTML report to slither-report.html."
	@echo "  slither-summary            Run Slither with a human-readable summary."
	@echo "  slither-docker             Run Slither via Docker (no local install needed)."
	@echo "  slither-install            Install Slither locally via pipx/pip."
	@echo "  remappings                 Generate remappings.txt for Slither/Foundry."
	@echo ""
	@echo "Arguments:"
	@echo "  ARGS=ethereumSepolia       Use testnet configuration (Ethereum Sepolia)."
	@echo "  ARGS=ethereum|polygon      Use mainnet configuration (Ethereum, Polygon)."
	@echo "  [no ARGS]                  Defaults to local anvil setup."
	@echo ""
	@echo "Examples:"
	@echo "  make deploy-staking ARGS=\"ethereumSepolia\"    # Deploy token on Ethereum Sepolia."
	@echo "  make slither"
	@echo "  make slither-json"
	@echo "  make slither-html"
	@echo "  make slither-docker"
	@echo ""

# Deploy & Test Configuration

DEFAULT_ANVIL_KEY := 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# Default RPC URLs
RPC_URL_LOCAL := http://localhost:8545
RPC_URL := $(RPC_URL_ETHEREUM_SEPOLIA)

# General network args (default to anvil setup)
NETWORK_ARGS := --rpc-url $(RPC_URL_LOCAL) --private-key $(DEFAULT_ANVIL_KEY) --broadcast

ifeq ($(findstring ethereumSepolia,$(ARGS)),ethereumSepolia)
	RPC_URL := $(RPC_URL_ETHEREUM_SEPOLIA)
	NETWORK_ARGS := --rpc-url $(RPC_URL_ETHEREUM_SEPOLIA) --account $(ACCOUNT_NAME) --sender $(SENDER_ADDRESS) $(PRIVATE_KEY) --broadcast
else ifeq ($(findstring ethereum,$(ARGS)),ethereum)
	RPC_URL := $(RPC_URL_ETHEREUM)
	NETWORK_ARGS := --rpc-url $(RPC_URL_ETHEREUM) --account $(ACCOUNT_NAME) --sender $(SENDER_ADDRESS) $(PRIVATE_KEY) --broadcast
 else ifeq ($(findstring polygon,$(ARGS)),polygon)
	RPC_URL := $(RPC_URL_POLYGON)
	NETWORK_ARGS := --rpc-url $(RPC_URL_POLYGON) --account $(ACCOUNT_NAME) --sender $(SENDER_ADDRESS) $(PRIVATE_KEY) --broadcast
endif

install:
	forge install

test:
	forge test -vvv

coverage:
	forge coverage

build:
	forge build

clean:
	forge clean

# Deploy Staking
deploy-staking:
	@forge script script/DeploySinglePoolStaking.s.sol --sig "run(bool)" false $(NETWORK_ARGS) --verify

# Local test for staking deploy
test-deploy-staking:
	@forge test --match-contract DeploySinglePoolStaking -vvvv

test-staking-unit:
	@forge test --match-contract SinglePoolStaking_Unit -vvvv

test-staking-fuzz:
	@forge test --match-contract SinglePoolStaking_Fuzz -vvvv


test-staking-scenarios:
	@forge test --match-contract SinglePoolStaking_Scenarios -vvvv

# -------- Slither (Static Analysis) --------
# Target contract (limit analysis scope for speed/signal)
SLITHER_TARGET ?= src/SinglePoolStaking.sol:SinglePoolStaking

# Generate remappings.txt from Foundry for Slither
remappings:
	@forge remappings > remappings.txt

# Common Slither flags (Foundry-aware)
SLITHER_FLAGS ?= --foundry-out-directory out --foundry-remappings remappings.txt --disable-color

# Install Slither locally (pipx recommended)
slither-install:
	@which slither >/dev/null 2>&1 || pipx install slither-analyzer || pip install slither-analyzer

# Run Slither (local)
slither: remappings
	@forge build
	@slither $(SLITHER_TARGET) $(SLITHER_FLAGS)

# Slither JSON report
slither-json: remappings
	@forge build
	@slither $(SLITHER_TARGET) $(SLITHER_FLAGS) --json slither.report.json

# Slither SARIF report (for GitHub code scanning)
slither-sarif: remappings
	@forge build
	@slither $(SLITHER_TARGET) $(SLITHER_FLAGS) --sarif slither.report.sarif

# Slither HTML report
slither-html: remappings
	@forge build
	@slither $(SLITHER_TARGET) $(SLITHER_FLAGS) --html slither-report.html --exclude-informational

# Human-readable summary
slither-summary: remappings
	@forge build
	@slither $(SLITHER_TARGET) $(SLITHER_FLAGS) --print human-summary

# Run Slither via Docker (no local install needed)
# Requires Docker installed; mounts current repo and runs the same flags
slither-docker: remappings
	@forge build
	@docker run --rm -v "$$(pwd)":/src -w /src crytic/slither:latest \
		slither $(SLITHER_TARGET) $(SLITHER_FLAGS)
