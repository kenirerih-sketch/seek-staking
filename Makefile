-include .env

.PHONY: all test clean deploy fund help install snapshot format anvil

help:
	@echo ""
	@echo "Usage:"
	@echo "  make <command> [ARGS=...]"
	@echo "Arguments:"
	@echo "  ARGS=ethereumSepolia       Use testnet configuration (Ethereum Sepolia)."
	@echo "  ARGS=ethereum|polygon      Use mainnet configuration (Ethereum, Polygon)."
	@echo "  [no ARGS]                  Defaults to local anvil setup."
	@echo ""
	@echo "Examples:"
	@echo "  make deploy-staking ARGS=\"ethereumSepolia\"    # Deploy token on Ethereum Sepolia."
	@echo ""

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

test-staking:
	@forge test --match-contract SinglePoolStakingTest -vvvv
