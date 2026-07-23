#!/usr/bin/env bash
set -euo pipefail

: "${CHAIN_ID:?CHAIN_ID is required}"
: "${VAULT_IMPLEMENTATION:?VAULT_IMPLEMENTATION is required}"
: "${VAULT_PROXY:?VAULT_PROXY is required}"

VERIFIER="${VERIFIER:-sourcify}"
VERIFIER_URL="${VERIFIER_URL:-}"

verify_args=(
  --chain-id "$CHAIN_ID"
  --verifier "$VERIFIER"
)

if [[ -n "$VERIFIER_URL" ]]; then
  verify_args+=(--verifier-url "$VERIFIER_URL")
fi

forge verify-contract \
  "${verify_args[@]}" \
  "$VAULT_IMPLEMENTATION" \
  src/vault/LPVault.sol:LPVault \
  --watch

forge verify-contract \
  "${verify_args[@]}" \
  "$VAULT_PROXY" \
  lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
  --watch

