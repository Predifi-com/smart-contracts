#!/usr/bin/env bash
# deploy.sh — Deploy Predifi contracts to Hedera testnet or mainnet
#
# Usage:
#   PRIVATE_KEY=0x... BACKEND_WALLET=0x... ./deploy.sh --network testnet --mode mock
#   PRIVATE_KEY=0x... BACKEND_WALLET=0x... USDC_ADDRESS=0x... ./deploy.sh --network mainnet --mode hts
#
# Env vars:
#   PRIVATE_KEY        (required) deployer ECDSA private key
#   BACKEND_WALLET     (required) backend hot-wallet address
#   USDC_ADDRESS       real USDC address — omit to deploy MockUSDC
#   STORK_ADDRESS      Stork oracle — omit to use deployer as placeholder
#   MULTISIG_ADDRESS   Safe address — if set, transfers DEFAULT_ADMIN_ROLE post-deploy
set -euo pipefail

NETWORK="testnet"
MODE="mock"

while [[ $# -gt 0 ]]; do
  case $1 in
    --network=*) NETWORK="${1#*=}" ;;
    --network)   shift; NETWORK="$1" ;;
    --mode=*)    MODE="${1#*=}" ;;
    --mode)      shift; MODE="$1" ;;
  esac
  shift
done

if [[ -z "${PRIVATE_KEY:-}" ]]; then
  echo "ERROR: PRIVATE_KEY is required"
  exit 1
fi
if [[ -z "${BACKEND_WALLET:-}" ]]; then
  echo "ERROR: BACKEND_WALLET is required"
  exit 1
fi

case "$NETWORK" in
  testnet) RPC_URL="https://testnet.hashio.io/api" ;;
  mainnet) RPC_URL="https://mainnet.hashio.io/api" ;;
  *)       echo "ERROR: unknown network '$NETWORK' (use testnet or mainnet)"; exit 1 ;;
esac

if [[ "$MODE" == "hts" && -z "${USDC_ADDRESS:-}" ]]; then
  echo "ERROR: --mode hts requires USDC_ADDRESS to be set"
  exit 1
fi

echo "========================================"
echo "Predifi Deploy"
echo "  Network : $NETWORK"
echo "  Mode    : $MODE"
echo "  RPC     : $RPC_URL"
echo "  Deployer: $(cast wallet address "$PRIVATE_KEY" 2>/dev/null || echo '?')"
echo "  Backend : $BACKEND_WALLET"
[[ -n "${USDC_ADDRESS:-}" ]]   && echo "  USDC    : $USDC_ADDRESS"
[[ -n "${STORK_ADDRESS:-}" ]]  && echo "  Stork   : $STORK_ADDRESS"
[[ -n "${MULTISIG_ADDRESS:-}" ]] && echo "  Multisig: $MULTISIG_ADDRESS"
echo "========================================"
echo

FOUNDRY_PROFILE=script forge script script/DeployPredifi.s.sol:DeployPredifi \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --slow \
  --gas-estimate-multiplier 130 \
  --skip-simulation \
  -vvv
