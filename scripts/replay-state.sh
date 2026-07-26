#!/usr/bin/env bash
# ScoutChain — replay persistent state from an OLD contract set onto a NEW one.
#
# This is step 4 ("replay events to seed initial state") of the "Address
# migration (new contract ID)" procedure in docs/DEPLOYMENT.md. It is normally
# invoked by scripts/migrate-contract.sh, but can also be run standalone.
#
# Usage:
#   ./scripts/replay-state.sh [network] [--dry-run] [--yes] [--export-dir DIR]
#
# Arguments / flags:
#   network        testnet | mainnet | local   (default: testnet)
#   --dry-run      Print the planned actions without executing any of them.
#   --yes, -y      Skip the interactive confirmation gate (for automation).
#   --export-dir   Directory for the player/scout export JSON
#                  (default: migration-export/).
#
# Contract IDs are resolved in this order:
#   OLD ids  — env OLD_<NAME>_CONTRACT_ID, else read from .env.contracts.snapshot
#   NEW ids  — env NEW_<NAME>_CONTRACT_ID, else read from .env.contracts
# where <NAME> is REGISTRATION / VERIFICATION / PROGRESS.
#
# Signing:
#   DEPLOYER_SECRET must be the admin secret key for the NEW contract set
#   (same key used by initialize.sh). ADMIN_ADDRESS is optional but, if set,
#   is verified against DEPLOYER_SECRET.
#
# ===========================================================================
# WHAT THIS TOOL CAN AND CANNOT REPLAY  (read this before relying on it)
# ===========================================================================
#
#   VALIDATORS — fully automated. verification.register_validator(wallet,
#   credentials) is admin-only (require_admin, no wallet self-auth), so an
#   operator holding the admin key CAN legitimately re-create every validator
#   on the NEW contract. This script reads get_validators() + get_validator()
#   from the OLD contract and calls register_validator() on the NEW one,
#   signed by DEPLOYER_SECRET.
#
#   PLAYERS and SCOUTS — can now be re-seeded via admin-only entrypoints.
#   registration.admin_seed_player() and registration.admin_seed_scout() are
#   admin-authenticated and accept the full exported payload needed to recreate
#   the persistent profile state without requiring the player's or scout's own
#   signature. This script exports the data to JSON and then replays it onto the
#   NEW contract using the admin key.
#
#   LEVELS — the registration contract does NOT store player level; the progress
#   contract is the source of truth (see resolve_level / set_player_level). The
#   exported PlayerProfile already carries the level field resolved from the
#   OLD progress contract via get_player(), so it is captured in the export.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
NETWORK=""
DRY_RUN=0
ASSUME_YES=0
EXPORT_DIR="migration-export"

usage() {
  sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)     DRY_RUN=1 ;;
    --yes|-y)      ASSUME_YES=1 ;;
    --export-dir)  shift; EXPORT_DIR="${1:?--export-dir needs a value}" ;;
    -h|--help)     usage; exit 0 ;;
    testnet|mainnet|local) NETWORK="$1" ;;
    *) echo "ERROR: unknown argument '$1'" >&2; echo "Run '$0 --help' for usage." >&2; exit 1 ;;
  esac
  shift
done
NETWORK="${NETWORK:-testnet}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# read_id <file> <key> — print the value of KEY=... from an env file, or "".
read_id() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  grep -E "^${key}=" "$file" | head -1 | cut -d= -f2- || true
}

# confirm <prompt> — interactive y/N gate, skippable with --yes.
confirm() {
  local prompt="$1" reply
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    echo "    [--yes] auto-confirming: $prompt"
    return 0
  fi
  read -r -p "    $prompt [y/N] " reply
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) echo "==> Aborted by operator — no changes made to the new contract." >&2; exit 1 ;;
  esac
}

# invoke_view <contract_id> <fn> [args...] — read-only invoke (no --source).
invoke_view() {
  local id="$1"; shift
  stellar contract invoke --id "$id" --network "$NETWORK" -- "$@"
}

# ---------------------------------------------------------------------------
# Resolve OLD and NEW contract IDs
# ---------------------------------------------------------------------------
OLD_REGISTRATION_CONTRACT_ID="${OLD_REGISTRATION_CONTRACT_ID:-$(read_id .env.contracts.snapshot REGISTRATION_CONTRACT_ID)}"
OLD_VERIFICATION_CONTRACT_ID="${OLD_VERIFICATION_CONTRACT_ID:-$(read_id .env.contracts.snapshot VERIFICATION_CONTRACT_ID)}"
OLD_PROGRESS_CONTRACT_ID="${OLD_PROGRESS_CONTRACT_ID:-$(read_id .env.contracts.snapshot PROGRESS_CONTRACT_ID)}"

NEW_REGISTRATION_CONTRACT_ID="${NEW_REGISTRATION_CONTRACT_ID:-$(read_id .env.contracts REGISTRATION_CONTRACT_ID)}"
NEW_VERIFICATION_CONTRACT_ID="${NEW_VERIFICATION_CONTRACT_ID:-$(read_id .env.contracts VERIFICATION_CONTRACT_ID)}"

DEPLOYER="${DEPLOYER_SECRET:-}"

echo "=========================================================================="
echo "  ScoutChain state replay — network: $NETWORK"
echo "=========================================================================="
echo "  OLD registration : ${OLD_REGISTRATION_CONTRACT_ID:-<unset>}"
echo "  OLD verification : ${OLD_VERIFICATION_CONTRACT_ID:-<unset>}"
echo "  OLD progress     : ${OLD_PROGRESS_CONTRACT_ID:-<unset>}"
echo "  NEW registration : ${NEW_REGISTRATION_CONTRACT_ID:-<unset>}"
echo "  NEW verification : ${NEW_VERIFICATION_CONTRACT_ID:-<unset>}"
echo "  Export directory : $EXPORT_DIR"
[[ "$DRY_RUN" -eq 1 ]] && echo "  Mode             : DRY RUN (no state will be changed)"
echo ""

if [[ -z "$OLD_VERIFICATION_CONTRACT_ID" || -z "$OLD_REGISTRATION_CONTRACT_ID" ]]; then
  echo "ERROR: could not resolve OLD contract IDs." >&2
  echo "       Set OLD_*_CONTRACT_ID env vars or provide .env.contracts.snapshot." >&2
  exit 1
fi
if [[ -z "$NEW_VERIFICATION_CONTRACT_ID" || -z "$NEW_REGISTRATION_CONTRACT_ID" ]]; then
  echo "ERROR: could not resolve NEW contract IDs." >&2
  echo "       Set NEW_*_CONTRACT_ID env vars or provide .env.contracts." >&2
  exit 1
fi
if [[ -z "$DEPLOYER" ]]; then
  echo "ERROR: DEPLOYER_SECRET is not set (required to sign register_validator on the new contract)." >&2
  exit 1
fi

# Optional admin-key sanity check (same shape as initialize.sh).
if [[ -n "${ADMIN_ADDRESS:-}" && "$DRY_RUN" -eq 0 ]]; then
  DERIVED_ADMIN=$(stellar keys address "$DEPLOYER" 2>/dev/null || true)
  if [[ -n "$DERIVED_ADMIN" && "$DERIVED_ADMIN" != "$ADMIN_ADDRESS" ]]; then
    echo "ERROR: DEPLOYER_SECRET ($DERIVED_ADMIN) does not match ADMIN_ADDRESS ($ADMIN_ADDRESS)." >&2
    echo "       register_validator on the new contract would fail auth. Aborting." >&2
    exit 1
  fi
fi

mkdir -p "$EXPORT_DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"

# ===========================================================================
# PART 1 — VALIDATORS  (read OLD, register on NEW — fully automated)
# ===========================================================================
echo "==> [1/3] Replaying validators (verification contract)..."
echo "    Reading active validators from OLD verification contract..."

VALIDATORS_JSON="$(invoke_view "$OLD_VERIFICATION_CONTRACT_ID" get_validators 2>/dev/null || echo '[]')"
# get_validators returns a JSON array of G-addresses, e.g. ["G...","G..."].
mapfile -t VALIDATOR_WALLETS < <(echo "$VALIDATORS_JSON" | jq -r '.[]?' 2>/dev/null || true)

VALIDATOR_COUNT="${#VALIDATOR_WALLETS[@]}"
echo "    Found $VALIDATOR_COUNT active validator(s) on the old contract."

VALIDATORS_EXPORT="$EXPORT_DIR/validators-$TS.json"
echo "[]" > "$VALIDATORS_EXPORT"

if [[ "$VALIDATOR_COUNT" -gt 0 ]]; then
  if [[ "$DRY_RUN" -eq 0 ]]; then
    confirm "Register $VALIDATOR_COUNT validator(s) on the NEW verification contract ($NEW_VERIFICATION_CONTRACT_ID)?"
  fi

  for wallet in "${VALIDATOR_WALLETS[@]}"; do
    [[ -z "$wallet" ]] && continue
    validator_struct="$(invoke_view "$OLD_VERIFICATION_CONTRACT_ID" get_validator --wallet "$wallet" 2>/dev/null || echo '{}')"
    credentials="$(echo "$validator_struct" | jq -r '.credentials // empty' 2>/dev/null || true)"

    if [[ -z "$credentials" ]]; then
      echo "    WARN: could not read credentials for $wallet — skipping." >&2
      continue
    fi

    # Append to the validators export file for the before/after comparison.
    tmp="$(mktemp)"
    jq --arg w "$wallet" --arg c "$credentials" \
      '. += [{"wallet":$w,"credentials":$c}]' "$VALIDATORS_EXPORT" > "$tmp" && mv "$tmp" "$VALIDATORS_EXPORT"

    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "    [dry-run] would register_validator wallet=$wallet on $NEW_VERIFICATION_CONTRACT_ID"
      continue
    fi

    echo "    Registering validator $wallet on new contract..."
    set +e
    out="$(stellar contract invoke \
      --id "$NEW_VERIFICATION_CONTRACT_ID" \
      --source "$DEPLOYER" \
      --network "$NETWORK" \
      -- register_validator \
      --wallet "$wallet" \
      --credentials "$credentials" 2>&1)"
    status=$?
    set -e
    if [[ $status -ne 0 ]]; then
      # Error 7 == ValidatorAlreadyRegistered — treat as idempotent success.
      if echo "$out" | grep -qE "Error\(Contract, #7\)"; then
        echo "      already registered on new contract — skipping."
      else
        echo "$out" >&2
        echo "ERROR: register_validator failed for $wallet." >&2
        exit 1
      fi
    else
      echo "      OK"
    fi
  done
fi
echo "    Validators exported to $VALIDATORS_EXPORT"

# ===========================================================================
# PART 2 — PLAYERS  (EXPORT + RE-SEED)
# ===========================================================================
echo ""
echo "==> [2/3] Exporting and replaying players (registration contract)..."
PLAYER_COUNT_RAW="$(invoke_view "$OLD_REGISTRATION_CONTRACT_ID" get_player_count 2>/dev/null || echo 0)"
PLAYER_COUNT="$(echo "$PLAYER_COUNT_RAW" | tr -dc '0-9')"
PLAYER_COUNT="${PLAYER_COUNT:-0}"
echo "    Old registration contract reports get_player_count = $PLAYER_COUNT"

PLAYERS_EXPORT="$EXPORT_DIR/players-$TS.json"
echo "[]" > "$PLAYERS_EXPORT"

if [[ "$PLAYER_COUNT" -gt 0 ]]; then
  for ((id=1; id<=PLAYER_COUNT; id++)); do
    set +e
    player="$(stellar contract invoke --id "$OLD_REGISTRATION_CONTRACT_ID" --network "$NETWORK" \
      -- get_player --player_id "$id" 2>/dev/null)"
    status=$?
    set -e
    if [[ $status -ne 0 || -z "$player" ]]; then
      echo "    (player_id $id not found — likely deregistered; skipping)"
      continue
    fi
    tmp="$(mktemp)"
    jq --argjson p "$player" '. += [$p]' "$PLAYERS_EXPORT" > "$tmp" && mv "$tmp" "$PLAYERS_EXPORT"

    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "    [dry-run] would admin_seed_player player_id=$id on $NEW_REGISTRATION_CONTRACT_ID"
      continue
    fi

    wallet="$(echo "$player" | jq -r '.wallet // empty' 2>/dev/null || true)"
    vitals="$(echo "$player" | jq -c '{age: (.vitals.age // 0), position: (.vitals.position // ""), region: (.vitals.region // ""), nationality: (.vitals.nationality // "")}' 2>/dev/null || true)"
    ipfs_hashes="$(echo "$player" | jq -c '.ipfs_hashes // []' 2>/dev/null || true)"
    level="$(echo "$player" | jq -r '.level // "Unverified"' 2>/dev/null || true)"
    registered_at="$(echo "$player" | jq -r '.registered_at // 0' 2>/dev/null || true)"
    updated_at="$(echo "$player" | jq -r '.updated_at // 0' 2>/dev/null || true)"

    if [[ -z "$wallet" || -z "$vitals" || -z "$ipfs_hashes" ]]; then
      echo "    WARN: incomplete player payload for id $id — skipping." >&2
      continue
    fi

    echo "    Re-seeding player $id on new contract..."
    set +e
    out="$(stellar contract invoke \
      --id "$NEW_REGISTRATION_CONTRACT_ID" \
      --source "$DEPLOYER" \
      --network "$NETWORK" \
      -- admin_seed_player \
      --wallet "$wallet" \
      --vitals "$vitals" \
      --ipfs_hashes "$ipfs_hashes" \
      --level "$level" \
      --player_id "$id" \
      --registered_at "$registered_at" \
      --updated_at "$updated_at" 2>&1)"
    status=$?
    set -e
    if [[ $status -ne 0 ]]; then
      echo "$out" >&2
      echo "ERROR: admin_seed_player failed for player_id $id." >&2
      exit 1
    fi
    echo "      OK"
  done
fi
echo "    Players exported to $PLAYERS_EXPORT"

# ===========================================================================
# PART 3 — SCOUTS  (EXPORT + RE-SEED)
# ===========================================================================
echo ""
echo "==> [3/3] Exporting and replaying scouts (registration contract)..."
SCOUT_COUNT_RAW="$(invoke_view "$OLD_REGISTRATION_CONTRACT_ID" get_scout_count 2>/dev/null || echo 0)"
SCOUT_COUNT="$(echo "$SCOUT_COUNT_RAW" | tr -dc '0-9')"
SCOUT_COUNT="${SCOUT_COUNT:-0}"
echo "    Old registration contract reports get_scout_count = $SCOUT_COUNT"

SCOUTS_EXPORT="$EXPORT_DIR/scouts-$TS.json"
echo "[]" > "$SCOUTS_EXPORT"

if [[ "$SCOUT_COUNT" -gt 0 ]]; then
  for ((id=1; id<=SCOUT_COUNT; id++)); do
    set +e
    scout="$(stellar contract invoke --id "$OLD_REGISTRATION_CONTRACT_ID" --network "$NETWORK" \
      -- get_scout --scout_id "$id" 2>/dev/null)"
    status=$?
    set -e
    if [[ $status -ne 0 || -z "$scout" ]]; then
      echo "    (scout_id $id not found — skipping)"
      continue
    fi
    tmp="$(mktemp)"
    jq --argjson s "$scout" '. += [$s]' "$SCOUTS_EXPORT" > "$tmp" && mv "$tmp" "$SCOUTS_EXPORT"

    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "    [dry-run] would admin_seed_scout scout_id=$id on $NEW_REGISTRATION_CONTRACT_ID"
      continue
    fi

    wallet="$(echo "$scout" | jq -r '.wallet // empty' 2>/dev/null || true)"
    region="$(echo "$scout" | jq -r '.region // empty' 2>/dev/null || true)"
    registered_at="$(echo "$scout" | jq -r '.registered_at // 0' 2>/dev/null || true)"
    verified="$(echo "$scout" | jq -r '.verified // false' 2>/dev/null || true)"

    if [[ -z "$wallet" || -z "$region" ]]; then
      echo "    WARN: incomplete scout payload for id $id — skipping." >&2
      continue
    fi

    echo "    Re-seeding scout $id on new contract..."
    set +e
    out="$(stellar contract invoke \
      --id "$NEW_REGISTRATION_CONTRACT_ID" \
      --source "$DEPLOYER" \
      --network "$NETWORK" \
      -- admin_seed_scout \
      --wallet "$wallet" \
      --region "$region" \
      --scout_id "$id" \
      --registered_at "$registered_at" \
      --verified "$verified" 2>&1)"
    status=$?
    set -e
    if [[ $status -ne 0 ]]; then
      echo "$out" >&2
      echo "ERROR: admin_seed_scout failed for scout_id $id." >&2
      exit 1
    fi
    echo "      OK"
  done
fi
echo "    Scouts exported to $SCOUTS_EXPORT"

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "=========================================================================="
echo "  State replay summary"
echo "=========================================================================="
echo "  Validators : $VALIDATOR_COUNT read from old contract"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "               (dry-run — none actually registered on the new contract)"
else
  echo "               registered on the NEW verification contract (admin-signed)"
fi
echo "  Players    : $PLAYER_COUNT exported to $PLAYERS_EXPORT"
echo "  Scouts     : $SCOUT_COUNT exported to $SCOUTS_EXPORT"
echo ""
echo "  Players and scouts were re-seeded on the new contract via"
echo "  admin-only registration entrypoints (admin_seed_player /"
echo "  admin_seed_scout)."
echo ""
echo "  The exported JSON files above contain the full replay payloads"
echo "  (wallet, vitals, ipfs_hashes, level, region) for auditing and"
echo "  future reconciliation."
echo "=========================================================================="
