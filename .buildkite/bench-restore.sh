#! /usr/bin/env nix-shell
#! nix-shell -i bash -p nix coreutils gnugrep gawk time haskellPackages.hp2pretty buildkite-agent

set -euo pipefail

target=byron
artifact_name=restore-$target-$NETWORK
log=restore.log
results=restore-$target-$NETWORK.txt
total_time=restore-time.txt
export NODE_DB=$HOME/node-db-$NETWORK

echo "--- Build"

echo "pwd=$(pwd)"
echo "NODE_DB=$NODE_DB"

nix-build -A benchmarks.cardano-wallet-$target.restore -o bench-$target-restore

bench="./bench-$target-restore/bin/restore --$NETWORK"

echo "--- Run benchmarks - $target - $NETWORK"

if [ -n "${SCRATCH_DIR:-}" ]; then
  mkdir -p "$SCRATCH_DIR"
  export HOME="$SCRATCH_DIR"
fi

command time -o $total_time -v $bench +RTS -N2 -qg -A1m -I0 -T -M8G -h -RTS 2>&1 | tee $log

grep -v INFO $log | awk '/All results/,EOF { print $0 }' > $results

echo "+++ Results - $target - $NETWORK"

cat $results

mv restore.hp $artifact_name.hp
hp2pretty $artifact_name.hp

if [ -n "${BUILDKITE:-}" ]; then
  echo "--- Upload"
  buildkite-agent artifact upload $artifact_name.svg
  buildkite-agent artifact upload $results

  for file in *.timelog; do
     buildkite-agent artifact upload $file;
  done;

  echo "+++ Heap profile"
  printf '\033]1338;url='"artifact://$artifact_name.svg"';alt='"Heap profile"'\a\n'
fi
