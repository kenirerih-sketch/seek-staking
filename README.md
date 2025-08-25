# Seek Staking Single Pool

## Table of Contents

- [Getting Started](#getting-started)
- [Private Key Management](#private-key-management)
- [Environment Variables](#environment-variables)
- [Config File Overview](#config-file-overview)
- [Testing](#testing)

### Requirements

1. Install [foundry](https://getfoundry.sh/)

2. Install make:
   Check if make is installed.

```bash
make --version
```

If not, install with homebrew:

```bash
brew install make
```

3. Install libs:

```bash
make install
```

4. Compile the project:

```bash
make build
```

### Private Key Management

Add private key using [Foundry wallet import](https://book.getfoundry.sh/reference/cast/cast-wallet-import) & setup password:

```bash
cast wallet import defaultKey --interactive
```

### View wallet list:

```bash
cast wallet list
```

Add the private defaultKey address and the name of choice for that wallet to .env, `defaultKey` was used in the example above:

```bash
SENDER_ADDRESS=0xAbC123
ACCOUNT_NAME=defaultKey
```

The password will be used for sending transactions through forge.

For more about private key security view [ERC-2335](https://eips.ethereum.org/EIPS/eip-2335)

### Environment Variables

Example `.env` file to interact with Ethereum mainnet/testnet and Polygon mainnet:

```bash
SENDER_ADDRESS=<your_address>
ACCOUNT_NAME=<account_name_for_SENDER_ADDRESS>

RPC_URL_ETHEREUM=<your_rpc_url_ethereum>
RPC_URL_ETHEREUM_SEPOLIA=<your_rpc_url_ethereum_sepolia>

RPC_URL_POLYGON=<your_rpc_url_polygon>

ETHERSCAN_API_KEY=<your_etherscan_api_key>
POLYGONSCAN_API_KEY=<your_polygonscan_api_key>
```

Variables to configure:

- `SENDER_ADDRESS`: The address for the private key for your testnet wallet imported to keystore using Foundry. If you use MetaMask, you can follow this [guide](https://support.metamask.io/managing-my-wallet/secret-recovery-phrase-and-private-keys/how-to-export-an-accounts-private-key/) to export your private key. **Note**: This key is required for signing transactions like token transfers.
- `ACCOUNT_NAME` : The name of the wallet associated with `SENDER_ADDRESS`. To view configured wallet names:

```bash
cast wallet list
```

- `RPC_URL_ETHEREUM`: The RPC URL for the Ethereum mainnet. You can get this from the [Alchemy](https://www.alchemy.com/) or [Infura](https://infura.io/) website.
- `RPC_URL_ETHEREUM_SEPOLIA`: The RPC URL for the Ethereum Sepolia. You can get this from the [Alchemy](https://www.alchemy.com/) or [Infura](https://infura.io/) website.

- `RPC_URL_POLYGON`: The RPC URL for the Polygon mainnet. You can get this from the [Alchemy](https://www.alchemy.com/) or [Infura](https://infura.io/) website.

- `ETHERSCAN_API_KEY`: An API key from Etherscan to verify your contracts. You can obtain one from [Etherscan](https://docs.etherscan.io/getting-started/viewing-api-usage-statistics).
- `POLYGONSCAN_API_KEY`: An API key from Polygon to verify your contracts on Polygon. See [this guide](https://docs.polygonscan.com/getting-started/viewing-api-usage-statistics) to get one from Arbiscan.

**Load the environment variables** into the terminal session where you will run the commands:

```bash
source .env
```

### Config File Overview

The `config.json` file within the `script` directory defines the key parameters used by all scripts. You can customize the token name, symbol, maximum supply, and cross-chain settings, among other fields.

Example `config.json` file:

```json
{
  "owner": "0xAbC321",
  "staking": {
    "stakeToken": "0x6982508145454Ce325dDbE47a25d4ec3d2311933",
    "rewardToken": "0x6982508145454Ce325dDbE47a25d4ec3d2311933",
    "rewardRate": 2e18,
    "maxRewardRate": 1e18,
    "rateChangeDelay": 604800,
    "withdrawDelay": 604800,
    "minStakeAmount": 1e18
  }
}
```

The `config.json` file contains the following parameters:

| Field             | Description                                                                             |
| ----------------- | --------------------------------------------------------------------------------------- |
| `stakeToken`      | The address of the deployed stake token                                                 |
| `rewardToken`     | The address of the deployed reward token, same as stake token                           |
| `rewardRate`      | How many tokens are issued as rewards per second.                                       |
| `owner`           | The address to own the contract.                                                        |
| `maxRewardRate`   | Max token issued as rewards per second                                                  |
| `rateChangeDelay` | Delay in seconds between proposing a new reward rate and executing it                   |
| `withdrawDelay`   | The minimum wait time between a user’s withdrawal request and when they can complete it |
| `minStakeAmount`  | Minimum amount of tokens to stake                                                       |

### Testing

All local tests:

```bash
make test
```

To run specific test view available commands in Makefile

### Deployment

#### Testnet:

Get some testnet tokens, go to [Alchemy's faucet](https://www.alchemy.com/faucets) or your favorite faucet for the desired testnet network.

```bash
make deploy-staking ARGS="ethereumSepolia"
```

#### Mainnets:

```bash
make deploy-staking ARGS="ethereum"
```

```bash
make deploy-staking ARGS="polygon"
```
