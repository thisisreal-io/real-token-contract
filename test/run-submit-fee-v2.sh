#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
port="${REAL_SUBMIT_FEE_TEST_PORT:-18549}"
./node_modules/.bin/hardhat node --hostname 127.0.0.1 --port "$port" > test/submit-fee-v2-node.log 2>&1 &
node_pid=$!
trap 'kill "$node_pid" 2>/dev/null || true' EXIT
for attempt in {1..25}; do
  if curl -fsS --max-time 2 -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' "http://127.0.0.1:$port" >/dev/null 2>&1; then
    REAL_SUBMIT_FEE_TEST_RPC="http://127.0.0.1:$port" node test/submit-fee-v2.mjs
    exit 0
  fi
  sleep 1
done
cat test/submit-fee-v2-node.log
exit 1
