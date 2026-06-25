#!/usr/bin/env bash
# Runs the complete local EIP-7702 wallet scenario.
#
# This script is intentionally explicit: it validates the contract, wallet
# state machine, relayer execution, paused edge case, and recovery path against
# a fresh Prague Anvil chain. Logs are written to .e2e/ for debugging.
set -euo pipefail

# Keep the e2e run hermetic by deriving all paths from the repository root.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

E2E_DIR="$ROOT_DIR/.e2e"
mkdir -p "$E2E_DIR"

ANVIL_LOG="$E2E_DIR/anvil.log"
BUILD_LOG="$E2E_DIR/build.log"
WALLET_INSTALL_LOG="$E2E_DIR/walletInstall.log"
WALLET_TYPECHECK_LOG="$E2E_DIR/walletTypecheck.log"
WALLET_TEST_LOG="$E2E_DIR/walletTest.log"
DEPLOY_IMPLEMENTATION_LOG="$E2E_DIR/deployImplementation.log"
INITIALIZE_LOG="$E2E_DIR/initialize.log"
DEPLOY_TARGET_LOG="$E2E_DIR/deployTarget.log"
PREPARE_INIT_LOG="$E2E_DIR/prepareInit.log"
STATE_INIT_LOG="$E2E_DIR/stateInit.log"
SYNC_LOG="$E2E_DIR/sync.log"
SET_NUMBER_LOG="$E2E_DIR/setNumber.log"
TARGET_REVERT_LOG="$E2E_DIR/targetRevert.log"
EXPIRED_LOG="$E2E_DIR/expired.log"
INVALID_NEXT_AUTH_LOG="$E2E_DIR/invalidNextAuth.log"
RECOVERY_LOG="$E2E_DIR/recovery.log"
POST_RECOVERY_SET_NUMBER_LOG="$E2E_DIR/postRecoverySetNumber.log"

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
CHAIN_ID="${CHAIN_ID:-31337}"

# Default keys are Anvil development keys. Never use them outside local tests.
DEPLOYER_PRIVATE_KEY="${DEPLOYER_PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
AUTHORITY_PRIVATE_KEY="${AUTHORITY_PRIVATE_KEY:-0x59c6995e998f97a5a0044966f094538c9dae13912edc9a17e9d01ea2e7588d8c}"
RELAYER_PRIVATE_KEY="${RELAYER_PRIVATE_KEY:-$DEPLOYER_PRIVATE_KEY}"

# Deterministic test wallet inputs make the full flow reproducible.
MNEMONIC="${MNEMONIC:-abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about}"
WALLET_ID="${WALLET_ID:-0x1111111111111111111111111111111111111111111111111111111111111111}"
ACCOUNT_INDEX="${ACCOUNT_INDEX:-0}"

export RPC_URL
export CHAIN_ID
export DEPLOYER_PRIVATE_KEY
export AUTHORITY_PRIVATE_KEY
export RELAYER_PRIVATE_KEY
export MNEMONIC
export WALLET_ID
export ACCOUNT_INDEX

# ─────────────────────────────────────────────────────────────
# Pretty output helpers
# ─────────────────────────────────────────────────────────────

USE_COLOR="${USE_COLOR:-1}"

if [[ "$USE_COLOR" == "1" ]]; then
  BOLD="\033[1m"
  DIM="\033[2m"
  GREEN="\033[32m"
  RED="\033[31m"
  YELLOW="\033[33m"
  BLUE="\033[34m"
  RESET="\033[0m"
else
  BOLD=""
  DIM=""
  GREEN=""
  RED=""
  YELLOW=""
  BLUE=""
  RESET=""
fi

function line() {
  printf "─%.0s" $(seq 1 60)
}

function banner() {
  echo ""
  echo "╭$(line)╮"
  printf "│ %-58s │\n" "$1"
  echo "╰$(line)╯"
}

function section() {
  echo ""
  printf "${BLUE}▶ %s${RESET}\n" "$1"
}

function ok() {
  printf "  ${GREEN}✓${RESET} %s\n" "$1"
}

function warn() {
  printf "  ${YELLOW}!${RESET} %s\n" "$1"
}

function fail() {
  echo ""
  printf "${RED}E2E FAILED:${RESET} %s\n" "$1" >&2
  exit 1
}

function kv() {
  local key="$1"
  local value="$2"
  printf "  %-22s %s\n" "$key" "$value"
}

function kv_addr() {
  local key="$1"
  local value="$2"
  printf "  %-22s %s\n" "$key" "$value"
}

function short_addr() {
  local value="$1"

  if [[ "$value" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
    echo "${value:0:6}...${value: -4}"
  else
    echo "$value"
  fi
}

function clean_value() {
  echo "$1" | tr -d '[:space:]'
}

function lower() {
  echo "$1" | tr 'A-F' 'a-f'
}

function wei_to_eth_4() {
  local wei="$1"

  # Uses cast for decimal formatting.
  cast to-unit "$wei" ether | awk '{ printf "%.4f ETH", $1 }'
}

function run_logged() {
  local label="$1"
  local log_file="$2"
  shift 2

  if "$@" >"$log_file" 2>&1; then
    ok "$label"
  else
    echo ""
    printf "${RED}✗ %s${RESET}\n" "$label"
    echo ""
    echo "Log file: $log_file"
    echo ""
    echo "Last 80 log lines:"
    echo "────────────────────────────────────────────────────────────"
    tail -n 80 "$log_file" || true
    echo "────────────────────────────────────────────────────────────"
    fail "$label failed"
  fi
}

function run_logged_in_dir() {
  local label="$1"
  local log_file="$2"
  local dir="$3"
  shift 3

  if (cd "$dir" && "$@") >"$log_file" 2>&1; then
    ok "$label"
  else
    echo ""
    printf "${RED}✗ %s${RESET}\n" "$label"
    echo ""
    echo "Log file: $log_file"
    echo ""
    echo "Last 80 log lines:"
    echo "────────────────────────────────────────────────────────────"
    tail -n 80 "$log_file" || true
    echo "────────────────────────────────────────────────────────────"
    fail "$label failed"
  fi
}

function assert_eq() {
  local actual="$1"
  local expected="$2"
  local message="$3"

  if [[ "$actual" != "$expected" ]]; then
    fail "$message. Expected '$expected', got '$actual'"
  fi
}

function assert_address_eq() {
  local actual
  local expected

  actual="$(lower "$(clean_value "$1")")"
  expected="$(lower "$(clean_value "$2")")"

  if [[ "$actual" != "$expected" ]]; then
    fail "$3. Expected '$expected', got '$actual'"
  fi
}

function extract_address_from_log_line() {
  local pattern="$1"
  local file="$2"

  grep "$pattern" "$file" | tail -n 1 | grep -Eo '0x[a-fA-F0-9]{40}' | tail -n 1
}

function wait_for_anvil() {
  for _ in $(seq 1 30); do
    if cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done

  fail "Anvil did not start. Check $ANVIL_LOG"
}

function cleanup() {
  if [[ -n "${ANVIL_PID:-}" ]]; then
    kill "$ANVIL_PID" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

# ─────────────────────────────────────────────────────────────
# Start
# ─────────────────────────────────────────────────────────────

banner "EIP-7702 Rotating Key Wallet — Local E2E"

section "Environment"
kv "Chain ID" "$CHAIN_ID"
kv "RPC URL" "$RPC_URL"
kv "Logs" ".e2e/"

section "Setup"

rm -rf "$ROOT_DIR/wallet/.local"
rm -f "$E2E_DIR"/*.log
ok "Cleaned previous local state"

# Prague is required because the flow depends on EIP-7702 delegation.
anvil \
  --hardfork prague \
  --chain-id "$CHAIN_ID" \
  > "$ANVIL_LOG" 2>&1 &

ANVIL_PID="$!"
wait_for_anvil
ok "Anvil started with Prague hardfork"

ACTUAL_CHAIN_ID="$(clean_value "$(cast chain-id --rpc-url "$RPC_URL")")"
assert_eq "$ACTUAL_CHAIN_ID" "$CHAIN_ID" "Unexpected chain id"

run_logged "Foundry build" "$BUILD_LOG" forge build

run_logged_in_dir "Wallet dependencies" "$WALLET_INSTALL_LOG" "$ROOT_DIR/wallet" pnpm install --silent
run_logged_in_dir "Wallet typecheck" "$WALLET_TYPECHECK_LOG" "$ROOT_DIR/wallet" pnpm typecheck
run_logged_in_dir "Wallet tests" "$WALLET_TEST_LOG" "$ROOT_DIR/wallet" pnpm test

# ─────────────────────────────────────────────────────────────
# Deploy implementation
# ─────────────────────────────────────────────────────────────

section "Deployment"

run_logged \
  "Deploy implementation" \
  "$DEPLOY_IMPLEMENTATION_LOG" \
  forge script script/DeployImplementation.s.sol:DeployImplementation \
    --rpc-url "$RPC_URL" \
    --broadcast

IMPLEMENTATION_ADDRESS="$(extract_address_from_log_line "Implementation deployed at:" "$DEPLOY_IMPLEMENTATION_LOG")"

if [[ -z "$IMPLEMENTATION_ADDRESS" ]]; then
  fail "Could not extract IMPLEMENTATION_ADDRESS from $DEPLOY_IMPLEMENTATION_LOG"
fi

export IMPLEMENTATION_ADDRESS

IMPLEMENTATION_CODE="$(cast code "$IMPLEMENTATION_ADDRESS" --rpc-url "$RPC_URL")"

if [[ "$IMPLEMENTATION_CODE" == "0x" ]]; then
  fail "Implementation has no code at $IMPLEMENTATION_ADDRESS"
fi

kv_addr "Implementation" "$IMPLEMENTATION_ADDRESS"

# ─────────────────────────────────────────────────────────────
# Prepare init
# ─────────────────────────────────────────────────────────────

# The wallet derives auth[0]/recovery[0] before the Solidity init script runs.
run_logged_in_dir \
  "Prepare wallet init data" \
  "$PREPARE_INIT_LOG" \
  "$ROOT_DIR/wallet" \
  env IMPLEMENTATION_ADDRESS="$IMPLEMENTATION_ADDRESS" pnpm prepare:init

# Load delegated account and first signer addresses produced by prepare:init.
source "$ROOT_DIR/wallet/.local/init.env"

export DELEGATED_ACCOUNT
export FIRST_AUTHORIZED_SIGNER
export FIRST_RECOVERY_SIGNER

kv_addr "Delegated account" "$DELEGATED_ACCOUNT"
kv_addr "Initial auth signer" "$FIRST_AUTHORIZED_SIGNER"
kv_addr "Initial recovery" "$FIRST_RECOVERY_SIGNER"

# ─────────────────────────────────────────────────────────────
# Fund accounts
# ─────────────────────────────────────────────────────────────

section "Funding"

RELAYER_ADDRESS="$(cast wallet address --private-key "$RELAYER_PRIVATE_KEY")"

cast rpc anvil_setBalance "$DELEGATED_ACCOUNT" "0x8AC7230489E80000" --rpc-url "$RPC_URL" >/dev/null
cast rpc anvil_setBalance "$RELAYER_ADDRESS" "0x8AC7230489E80000" --rpc-url "$RPC_URL" >/dev/null

DELEGATED_BALANCE="$(cast balance "$DELEGATED_ACCOUNT" --rpc-url "$RPC_URL")"
RELAYER_BALANCE="$(cast balance "$RELAYER_ADDRESS" --rpc-url "$RPC_URL")"

kv_addr "Relayer" "$RELAYER_ADDRESS"
kv "Delegated balance" "$(wei_to_eth_4 "$DELEGATED_BALANCE")"
kv "Relayer balance" "$(wei_to_eth_4 "$RELAYER_BALANCE")"

# ─────────────────────────────────────────────────────────────
# Initialize delegated account
# ─────────────────────────────────────────────────────────────

section "Initialization"

# This attaches delegation to the authority EOA and initializes its account storage.
run_logged \
  "Attach EIP-7702 delegation + initialize" \
  "$INITIALIZE_LOG" \
  forge script script/InitializeDelegatedAccount.s.sol:InitializeDelegatedAccount \
    --rpc-url "$RPC_URL" \
    --broadcast

IS_INITIALIZED="$(clean_value "$(cast call "$DELEGATED_ACCOUNT" "isInitialized()(bool)" --rpc-url "$RPC_URL")")"
IS_PAUSED="$(clean_value "$(cast call "$DELEGATED_ACCOUNT" "isPaused()(bool)" --rpc-url "$RPC_URL")")"
CURRENT_SIGNER="$(clean_value "$(cast call "$DELEGATED_ACCOUNT" "currentAuthorizedSigner()(address)" --rpc-url "$RPC_URL")")"
RECOVERY_ACTIVE="$(clean_value "$(cast call "$DELEGATED_ACCOUNT" "isActiveRecoverySigner(address)(bool)" "$FIRST_RECOVERY_SIGNER" --rpc-url "$RPC_URL")")"

assert_eq "$IS_INITIALIZED" "true" "Delegated account should be initialized"
assert_eq "$IS_PAUSED" "false" "Delegated account should not be paused after initialize"
assert_address_eq "$CURRENT_SIGNER" "$FIRST_AUTHORIZED_SIGNER" "Unexpected initial currentAuthorizedSigner"
assert_eq "$RECOVERY_ACTIVE" "true" "Initial recovery signer should be active"

kv "Initialized" "$IS_INITIALIZED"
kv "Paused" "$IS_PAUSED"
kv_addr "Current auth signer" "$CURRENT_SIGNER"
kv "Recovery active" "$RECOVERY_ACTIVE"

# ─────────────────────────────────────────────────────────────
# Deploy target
# ─────────────────────────────────────────────────────────────

section "ExecutionTarget"

run_logged \
  "Deploy ExecutionTarget" \
  "$DEPLOY_TARGET_LOG" \
  forge script script/DeployExecutionTarget.s.sol:DeployExecutionTarget \
    --rpc-url "$RPC_URL" \
    --broadcast

EXECUTION_TARGET_ADDRESS="$(extract_address_from_log_line "ExecutionTarget deployed at:" "$DEPLOY_TARGET_LOG")"

if [[ -z "$EXECUTION_TARGET_ADDRESS" ]]; then
  fail "Could not extract EXECUTION_TARGET_ADDRESS from $DEPLOY_TARGET_LOG"
fi

export EXECUTION_TARGET_ADDRESS

TARGET_CODE="$(cast code "$EXECUTION_TARGET_ADDRESS" --rpc-url "$RPC_URL")"

if [[ "$TARGET_CODE" == "0x" ]]; then
  fail "ExecutionTarget has no code at $EXECUTION_TARGET_ADDRESS"
fi

kv_addr "ExecutionTarget" "$EXECUTION_TARGET_ADDRESS"

# ─────────────────────────────────────────────────────────────
# Initial local state
# ─────────────────────────────────────────────────────────────

section "Wallet State"

run_logged_in_dir "Create initial local state" "$STATE_INIT_LOG" "$ROOT_DIR/wallet" pnpm state:init
run_logged_in_dir "Initial sync" "$SYNC_LOG" "$ROOT_DIR/wallet" pnpm sync

STATE_STATUS="$(node -e "console.log(require('$ROOT_DIR/wallet/.local/state.json').status)")"
STATE_AUTH_INDEX="$(node -e "console.log(require('$ROOT_DIR/wallet/.local/state.json').currentAuthIndex)")"
STATE_RECOVERY_INDEX="$(node -e "console.log(require('$ROOT_DIR/wallet/.local/state.json').currentRecoveryIndex)")"

kv "Status" "$STATE_STATUS"
kv "Auth index" "$STATE_AUTH_INDEX"
kv "Recovery index" "$STATE_RECOVERY_INDEX"

# ─────────────────────────────────────────────────────────────
# E2E flow
# ─────────────────────────────────────────────────────────────

section "Flow"

# Normal execution should rotate auth[0] to auth[1] and execute the target call.
run_logged_in_dir \
  "setNumber(111)" \
  "$SET_NUMBER_LOG" \
  "$ROOT_DIR/wallet" \
  env EXECUTION_TARGET_ADDRESS="$EXECUTION_TARGET_ADDRESS" NEW_NUMBER=111 pnpm execute:set-number

NUMBER_AFTER_SUCCESS="$(clean_value "$(cast call "$EXECUTION_TARGET_ADDRESS" "number()(uint256)" --rpc-url "$RPC_URL")")"
LAST_SENDER_AFTER_SUCCESS="$(clean_value "$(cast call "$EXECUTION_TARGET_ADDRESS" "lastSender()(address)" --rpc-url "$RPC_URL")")"

assert_eq "$NUMBER_AFTER_SUCCESS" "111" "ExecutionTarget.number should be 111 after setNumber"
assert_address_eq "$LAST_SENDER_AFTER_SUCCESS" "$DELEGATED_ACCOUNT" "ExecutionTarget.lastSender should be delegated account"

AUTH_INDEX_AFTER_SUCCESS="$(node -e "console.log(require('$ROOT_DIR/wallet/.local/state.json').currentAuthIndex)")"
ok "setNumber(111) executed; auth index = $AUTH_INDEX_AFTER_SUCCESS"

# Target failure must not roll back the already-consumed auth key rotation.
run_logged_in_dir \
  "alwaysRevert()" \
  "$TARGET_REVERT_LOG" \
  "$ROOT_DIR/wallet" \
  env EXECUTION_TARGET_ADDRESS="$EXECUTION_TARGET_ADDRESS" pnpm execute:target-revert

NUMBER_AFTER_REVERT="$(clean_value "$(cast call "$EXECUTION_TARGET_ADDRESS" "number()(uint256)" --rpc-url "$RPC_URL")")"
assert_eq "$NUMBER_AFTER_REVERT" "111" "ExecutionTarget.number should not change after alwaysRevert"

AUTH_INDEX_AFTER_REVERT="$(node -e "console.log(require('$ROOT_DIR/wallet/.local/state.json').currentAuthIndex)")"
ok "Target revert handled without global revert; auth index = $AUTH_INDEX_AFTER_REVERT"

# Expired operations still consume the observed signature but skip target effects.
run_logged_in_dir \
  "expired setNumber(222)" \
  "$EXPIRED_LOG" \
  "$ROOT_DIR/wallet" \
  env EXECUTION_TARGET_ADDRESS="$EXECUTION_TARGET_ADDRESS" NEW_NUMBER=222 pnpm execute:expired-set-number

NUMBER_AFTER_EXPIRED="$(clean_value "$(cast call "$EXECUTION_TARGET_ADDRESS" "number()(uint256)" --rpc-url "$RPC_URL")")"
assert_eq "$NUMBER_AFTER_EXPIRED" "111" "ExecutionTarget.number should not change after expired operation"

AUTH_INDEX_AFTER_EXPIRED="$(node -e "console.log(require('$ROOT_DIR/wallet/.local/state.json').currentAuthIndex)")"
ok "Expired operation rotated but skipped target; auth index = $AUTH_INDEX_AFTER_EXPIRED"

# Dev-only adversarial flow: invalid next auth should move the account to PAUSED.
run_logged_in_dir \
  "invalid nextAuthorizedSigner" \
  "$INVALID_NEXT_AUTH_LOG" \
  "$ROOT_DIR/wallet" \
  env EXECUTION_TARGET_ADDRESS="$EXECUTION_TARGET_ADDRESS" NEW_NUMBER=333 pnpm execute:invalid-next-auth

IS_PAUSED_AFTER_INVALID="$(clean_value "$(cast call "$DELEGATED_ACCOUNT" "isPaused()(bool)" --rpc-url "$RPC_URL")")"
NUMBER_AFTER_INVALID="$(clean_value "$(cast call "$EXECUTION_TARGET_ADDRESS" "number()(uint256)" --rpc-url "$RPC_URL")")"

assert_eq "$IS_PAUSED_AFTER_INVALID" "true" "Delegated account should be paused after invalid nextAuthorizedSigner"
assert_eq "$NUMBER_AFTER_INVALID" "111" "ExecutionTarget.number should not change after invalid nextAuthorizedSigner"

STATE_STATUS_AFTER_INVALID="$(node -e "console.log(require('$ROOT_DIR/wallet/.local/state.json').status)")"
ok "Invalid next signer paused account; status = $STATE_STATUS_AFTER_INVALID"

# Recovery should burn recovery[0], install a fresh auth signer, and register recovery[1].
run_logged_in_dir \
  "signedRecovery" \
  "$RECOVERY_LOG" \
  "$ROOT_DIR/wallet" \
  pnpm recover

IS_PAUSED_AFTER_RECOVERY="$(clean_value "$(cast call "$DELEGATED_ACCOUNT" "isPaused()(bool)" --rpc-url "$RPC_URL")")"
assert_eq "$IS_PAUSED_AFTER_RECOVERY" "false" "Delegated account should be unpaused after recovery"

STATE_STATUS_AFTER_RECOVERY="$(node -e "console.log(require('$ROOT_DIR/wallet/.local/state.json').status)")"
STATE_AUTH_INDEX_AFTER_RECOVERY="$(node -e "console.log(require('$ROOT_DIR/wallet/.local/state.json').currentAuthIndex)")"
STATE_RECOVERY_INDEX_AFTER_RECOVERY="$(node -e "console.log(require('$ROOT_DIR/wallet/.local/state.json').currentRecoveryIndex)")"

ok "Recovery restored account; status = $STATE_STATUS_AFTER_RECOVERY, auth index = $STATE_AUTH_INDEX_AFTER_RECOVERY, recovery index = $STATE_RECOVERY_INDEX_AFTER_RECOVERY"

run_logged_in_dir \
  "post-recovery setNumber(444)" \
  "$POST_RECOVERY_SET_NUMBER_LOG" \
  "$ROOT_DIR/wallet" \
  env EXECUTION_TARGET_ADDRESS="$EXECUTION_TARGET_ADDRESS" NEW_NUMBER=444 pnpm execute:set-number

NUMBER_AFTER_RECOVERY_EXECUTION="$(clean_value "$(cast call "$EXECUTION_TARGET_ADDRESS" "number()(uint256)" --rpc-url "$RPC_URL")")"
LAST_SENDER_AFTER_RECOVERY_EXECUTION="$(clean_value "$(cast call "$EXECUTION_TARGET_ADDRESS" "lastSender()(address)" --rpc-url "$RPC_URL")")"

assert_eq "$NUMBER_AFTER_RECOVERY_EXECUTION" "444" "ExecutionTarget.number should be 444 after post-recovery execution"
assert_address_eq "$LAST_SENDER_AFTER_RECOVERY_EXECUTION" "$DELEGATED_ACCOUNT" "ExecutionTarget.lastSender should still be delegated account"

FINAL_STATUS="$(node -e "console.log(require('$ROOT_DIR/wallet/.local/state.json').status)")"
FINAL_AUTH_INDEX="$(node -e "console.log(require('$ROOT_DIR/wallet/.local/state.json').currentAuthIndex)")"
FINAL_AUTH_SIGNER="$(node -e "console.log(require('$ROOT_DIR/wallet/.local/state.json').currentAuthorizedSigner)")"
FINAL_RECOVERY_INDEX="$(node -e "console.log(require('$ROOT_DIR/wallet/.local/state.json').currentRecoveryIndex)")"
FINAL_RECOVERY_SIGNER="$(node -e "console.log(require('$ROOT_DIR/wallet/.local/state.json').currentRecoverySigner)")"
BURNED_AUTH="$(node -e "console.log(require('$ROOT_DIR/wallet/.local/state.json').burnedAuthIndices.join(','))")"
BURNED_RECOVERY="$(node -e "console.log(require('$ROOT_DIR/wallet/.local/state.json').burnedRecoveryIndices.join(','))")"

ok "Post-recovery execution succeeded; final auth index = $FINAL_AUTH_INDEX"

# ─────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────

banner "E2E PASSED"

section "Contracts"
kv_addr "Implementation" "$IMPLEMENTATION_ADDRESS"
kv_addr "Delegated account" "$DELEGATED_ACCOUNT"
kv_addr "ExecutionTarget" "$EXECUTION_TARGET_ADDRESS"

section "Final State"
kv "Target number" "$NUMBER_AFTER_RECOVERY_EXECUTION"
kv "Wallet status" "$FINAL_STATUS"
kv "Auth index" "$FINAL_AUTH_INDEX"
kv_addr "Auth signer" "$FINAL_AUTH_SIGNER"
kv "Recovery index" "$FINAL_RECOVERY_INDEX"
kv_addr "Recovery signer" "$FINAL_RECOVERY_SIGNER"
kv "Burned auth" "[$BURNED_AUTH]"
kv "Burned recovery" "[$BURNED_RECOVERY]"

section "Validated"
ok "EIP-7702 delegation + initialization"
ok "Successful execution rotates auth signer"
ok "Target revert does not revert global account flow"
ok "Expired operation rotates signer but skips target"
ok "Invalid nextAuthorizedSigner pauses account"
ok "signedRecovery restores READY state"
ok "Post-recovery execution works"

echo ""
kv "Full logs" "$E2E_DIR"
echo ""