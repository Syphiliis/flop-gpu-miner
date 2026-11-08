#!/usr/bin/env bash
# Test bench of flop-miner, on fakes: no GPU, no FLOP, no network, nothing signed. It runs as root in a throwaway
# Ubuntu container (tests/run.sh starts one), because flop-miner writes to /opt/flop-miner, /etc/systemd and
# /usr/local/bin. Fake tools (docker, nvidia-smi, curl, systemctl...) come first in PATH; a fake FLOP pack mimics
# the real pack's scripts (their arguments, their output, their refusals).
#   bash tests/test.sh <path of flop-miner>        exit 0 when every check passes
set -uo pipefail
SCRIPT=$(readlink -f "${1:?usage: test.sh <path of flop-miner>}")
if [ "$(id -u)" != 0 ] || [ ! -f /.dockerenv ]; then
  echo "run it as root in a throwaway container: tests/run.sh"
  exit 2
fi
if ! command -v jq > /dev/null || ! command -v openssl > /dev/null || ! command -v ss > /dev/null; then
  apt-get update -qq > /dev/null && apt-get install -y -qq jq openssl iproute2 > /dev/null
fi

W=$(mktemp -d)
FAKES=$W/bin F=$W/state
export FAKE_ADDR=5FakeMinerAddressForTestsXyz11111111111111111111
export FAKE_PHRASE="fake test words that are not a real phrase"
mkdir -p "$FAKES" "$F"

# --- fake tools ---------------------------------------------------------------------------------------------------
fake() { cat > "$FAKES/$1" && chmod 755 "$FAKES/$1"; }

fake docker << 'EOF'
#!/bin/bash
echo "docker $*" >> "$FAKE_CALLS"
a=" $* "
case $1 in
  info)
    if [ -f "$FAKE_STATE/no-nvidia" ]; then echo '{"runc":{"path":"runc"}}'
    else echo '{"nvidia":{"path":"nvidia-container-runtime"},"runc":{"path":"runc"}}'; fi ;;
  compose)
    case $a in
      *" version "*) echo "Docker Compose version v2.40.3" ;;
      *" ps "*) [ ! -f "$FAKE_STATE/up" ] || printf 'backend running \ngpu-inventory exited \nworker running \n' ;;
      *" up "*) touch "$FAKE_STATE/up"; echo "$a" > "$FAKE_STATE/last-up" ;;
      *" down "* | *" stop "*) rm -f "$FAKE_STATE/up" ;;
      *" logs "*) [ ! -f "$FAKE_STATE/tls-error" ] || echo 'tls-1  | {"level":"error","msg":"could not get certificate from issuer","error":"urn:ietf:params:acme:error:connection"}' ;;
    esac ;;
  run)
    case $a in
      *" key generate "*) echo x >> "$FAKE_STATE/keygen"; printf '{"secretPhrase":"%s","ss58Address":"%s"}\n' "$FAKE_PHRASE" "$FAKE_ADDR" ;;
      *" key inspect "*) printf '{"ss58Address":"%s"}\n' "$(cat "$FAKE_STATE/inspect-addr" 2> /dev/null || echo "$FAKE_ADDR")" ;;
    esac ;;
  image) [ "$2" != inspect ] || echo sha256:fakecli ;;
  ps) [[ $a != *" ancestor=sha256:fakecli "* ]] || echo fakecid ;; # a container left behind by a script past its limit
esac
exit 0
EOF

fake timeout << 'EOF'
#!/bin/bash
# like timeout -k 10 LIMIT COMMAND...: code 124 for the script named in $FAKE_STATE/timeout-<script>
[ "$1" != -k ] || shift 2
shift
[ ! -f "$FAKE_STATE/timeout-$(basename "$1")" ] || exit 124
exec "$@"
EOF

fake nvidia-smi << 'EOF'
#!/bin/bash
# $FAKE_STATE/gpu: "NAME, MEMORY MiB, DRIVER, COMPUTE CAPABILITY"
IFS=',' read -r name mem driver cc < <(cat "$FAKE_STATE/gpu" 2> /dev/null || echo "NVIDIA GeForce RTX 4090, 24564, 580.95.05, 8.9")
case " $* " in
  *" -L "*) echo "GPU 0: $name (UUID: GPU-fake)" ;;
  *"--query-gpu=driver_version "*) echo "${driver# }" ;;
  *compute_cap*) echo "$name,$mem,$cc" ;;
  *utilization*) echo "$name, 2 %, 1100 MiB, $mem MiB" ;;
esac
EOF

fake curl << 'EOF'
#!/bin/bash
out='' fmt='' url='' resolve=''
while [ $# -gt 0 ]; do
  case $1 in
    -o) out=$2; shift ;;
    -w) fmt=$2; shift ;;
    --resolve) resolve=$2; shift ;;
    --max-time | --retry | --proto) shift ;;
    http://* | https://*) url=$1 ;;
  esac
  shift
done
echo "curl $url${resolve:+ (resolve $resolve)}" >> "$FAKE_CALLS"
reply() { # reply CODE [BODY]: like curl without -f
  if [ -n "${2:-}" ]; then if [ -n "$out" ]; then printf '%s' "$2" > "$out"; else printf '%s' "$2"; fi; fi
  [ -z "$fmt" ] || printf "${fmt//'%{http_code}'/$1}"
  [ "$1" != 000 ] || exit 7
  exit 0
}
code() { cat "$FAKE_STATE/$1" 2> /dev/null || echo 401; }
case $url in
  *flop-miner-pack*) cp "$FAKE_PACK" "$out" ;;
  *api.ipify.org* | *checkip.amazonaws.com* | *icanhazip.com*) [ -f "$FAKE_STATE/no-ip" ] && exit 6; echo "${FAKE_IP:-203.0.113.10}" ;;
  http://127.0.0.1:8645/session/info) reply "$(code worker-code)" ;;
  *.trycloudflare.com/session/info) reply 401 ;;
  */session/info) if [ -n "$resolve" ]; then reply "$(code local-code)"; else reply "$(code public-code)"; fi ;;
  https://faucet.flop.network/limits) # $FAKE_STATE/limits: open (default), automatic_full, unknown, or down
    s=$(cat "$FAKE_STATE/limits" 2> /dev/null || echo open)
    case $s in
      down) exit 22 ;;
      unknown) printf '{"sponsor":{"miner":{"status":"unknown","reason":"sponsor_read_timeout"}}}' ;;
      *) printf '{"sponsor":{"miner":{"status":"%s"}}}' "$s" ;;
    esac ;;
  */api/transactions?section=minerStaking*) # the sponsor's last registrations; all failed with $FAKE_STATE/chain-failing
    ok=true
    [ ! -f "$FAKE_STATE/chain-failing" ] || ok=false
    printf '{"data":['
    for i in 1 2 3 4 5; do
      [ "$i" = 1 ] || printf ','
      printf '{"method":"sponsorRegisterMiner","success":%s,"timestamp":%s}' "$ok" "$((1794120000000 + i))"
    done
    printf ',{"method":"deregisterMiner","success":true,"timestamp":1794120000009}]}' ;;
  */api/miners/*)
    if [ -f "$FAKE_STATE/registered" ]; then
      reply 200 '{"registeredBlock":42,"sponsoredStake":"1000000000000000000000000","strikes":0,"calibration":null,"calibrationReport":{"verifiedJobs":3}}'
    else reply 404 '{"error":"miner not found"}'; fi ;;
  *) [ -z "$out" ] || : > "$out" ;; # signing keys and repository lists
esac
exit 0
EOF

fake systemctl << 'EOF'
#!/bin/bash
echo "systemctl $*" >> "$FAKE_CALLS"
a=" $* "
case $a in
  *" is-active "*)
    on=0
    [[ $a != *" flop-miner-sponsor.timer "* ]] || [ ! -f "$FAKE_STATE/sponsor-timer" ] || on=1
    [[ $a != *" flop-miner-tunnel.service "* ]] || [ ! -f "$FAKE_STATE/tunnel-on" ] || on=1
    if [ $on = 1 ]; then [[ $a == *" --quiet "* ]] || echo active; exit 0; fi
    [[ $a == *" --quiet "* ]] || echo inactive
    exit 3 ;;
  *" enable --now flop-miner-sponsor.timer "*) touch "$FAKE_STATE/sponsor-timer" ;;
  *" disable --now "*)
    [[ $a != *" flop-miner-sponsor.timer "* ]] || rm -f "$FAKE_STATE/sponsor-timer"
    [[ $a != *" flop-miner-tunnel.service "* ]] || rm -f "$FAKE_STATE/tunnel-on" ;;
  *" start flop-miner-tunnel.service "*)
    touch "$FAKE_STATE/tunnel-on"
    n=$(( $(cat "$FAKE_STATE/tunnel-n" 2> /dev/null || echo 0) + 1 )); echo $n > "$FAKE_STATE/tunnel-n"
    echo "INF |  https://fake-tunnel-$n.trycloudflare.com  |" >> /opt/flop-miner/.flop-miner/tunnel.log ;;
esac
exit 0
EOF

fake dpkg << 'EOF'
#!/bin/bash
case $1 in
  --print-architecture) echo amd64 ;;
  -s) ! grep -qxF "$2" "$FAKE_STATE/missing-pkgs" 2> /dev/null ;;
esac
EOF

fake getent << 'EOF'
#!/bin/bash
# ahostsv4 NAME: <ip>.sslip.io resolves to its IP; another name to the IP written in $FAKE_STATE/dns
[ "$1" = ahostsv4 ] || exit 2
case $2 in
  *.sslip.io) ip=${2%.sslip.io}; ip=${ip//-/.} ;;
  *) ip=$(cat "$FAKE_STATE/dns" 2> /dev/null) || exit 2 ;;
esac
echo "$ip  STREAM $2"
EOF

fake ip << 'EOF'
#!/bin/bash
echo "2: eth0    inet 10.0.0.5/24 brd 10.0.0.255 scope global eth0\       valid_lft forever preferred_lft forever"
EOF

fake ss << 'EOF'
#!/bin/bash
echo "ss $*" >> "$FAKE_CALLS"
[ ! -f "$FAKE_STATE/port-used" ] || echo 'LISTEN 0 511 0.0.0.0:80 0.0.0.0:* users:(("nginx",pid=999,fd=6))'
EOF

fake df << 'EOF'
#!/bin/bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/fake 300000000 1000000 $(( $(cat "$FAKE_STATE/disk-gb" 2> /dev/null || echo 200) * 1048576 )) 1% /"
EOF

fake uname << 'EOF'
#!/bin/bash
case $1 in -m) echo x86_64 ;; -r) echo 6.8.0-fake ;; *) echo Linux ;; esac
EOF

fake apt-get << 'EOF'
#!/bin/bash
echo "apt-get $*" >> "$FAKE_CALLS"
EOF
printf '#!/bin/bash\nexit 0\n' | fake gpg
fake sleep << 'EOF'
#!/bin/bash
echo "sleep $*" >> "$FAKE_CALLS"
EOF
fake nvidia-ctk << 'EOF'
#!/bin/bash
echo "nvidia-ctk $*" >> "$FAKE_CALLS"
rm -f "$FAKE_STATE/no-nvidia"
EOF

# --- fake FLOP packs: the real pack's file names; its scripts mimic the real ones -------------------------------
make_pack() { # make_pack OUTPUT MODEL_HASH
  local p=$W/pack-src/flop-miner-pack-test f
  rm -rf "$W/pack-src" && mkdir -p "$p"
  for f in README.md docker-compose.miner.yml docker-compose.backend.yml docker-compose.tls.yml \
    fetch-model.requirements.txt decode-policy.mjs sponsor-request.mjs retire.mjs releases.json sponsor-grant.sh \
    sponsor-grant.mjs; do
    echo "fake $f" > "$p/$f"
  done
  cat > "$p/miner.env.example" << EOF2
FLOP_CLI=ghcr.io/flop-labs/flop-core/cli:stable
COMPOSE_PROJECT_NAME=flop-miner-01
FLOP_WORKER_IMAGE=ghcr.io/flop-labs/flop-core/miner-worker:stable
FLOP_BACKEND_IMAGE=ghcr.io/flop-labs/flop-core/miner-vllm-toploc:stable
FLOP_RPC=wss://rpc.devnet.flop.network
MINER_SIGNER_FILE=/opt/flop-miner/signer
MINER_ENCLAVE_KEY_FILE=/opt/flop-miner/session-keys/enclave.seed
MODEL_NAME=Qwen/Qwen2.5-0.5B-Instruct
MODEL_HASH=$2
MODEL_CHECKPOINT_DIR=/opt/flop-miner/models/qwen2.5-0.5b-instruct
# TENSOR_PARALLEL_SIZE=4
DECODE_POLICY=
DECODE_POLICY_HASH=
INFERENCE_API_KEY=
SESSION_BIND_IP=127.0.0.1
SESSION_PUBLIC_HOST=
SESSION_AUTH_TOKEN=
EOF2
  cat > "$p/decode-policy.sh" << 'EOF2'
#!/usr/bin/env bash
# like the real one: exactly one line of each key; a policy already written is only checked
set -euo pipefail
[ "$#" = 1 ] && [ -f "$1" ] || exit 2
for key in DECODE_POLICY DECODE_POLICY_HASH; do [ "$(grep -c "^$key=" "$1")" = 1 ] || exit 2; done
echo "decode-policy FLOP_CLI=${FLOP_CLI:-} FLOP_RPC=${FLOP_RPC:-}" >> "$FAKE_CALLS"
[ ! -f "$FAKE_STATE/policy-fail" ] || { echo "policy not allowlisted" >&2; exit 1; }
if [ -f "$FAKE_STATE/policy-dropped" ] && grep -q "^DECODE_POLICY='" "$1"; then
  echo "the chain no longer allowlists this decode policy" >&2
  exit 1
fi
sed -i -e "s|^DECODE_POLICY=.*|DECODE_POLICY='{\"version\":1}'|" -e "s|^DECODE_POLICY_HASH=.*|DECODE_POLICY_HASH=0xfeed|" "$1"
echo "$1: DECODE_POLICY_HASH=0xfeed"
EOF2
  cat > "$p/fetch-model.sh" << 'EOF2'
#!/usr/bin/env bash
# like the real one: an absolute directory, refused when not empty unless --resume
set -euo pipefail
[ $# -eq 3 ] || { [ $# -eq 4 ] && [ "$4" = --resume ]; } || exit 2
[[ $2 =~ ^[0-9a-f]{40}$ ]] && [[ $3 = /* ]] || exit 2
if [ "${4:-}" != --resume ] && [ -n "$(ls -A "$3" 2> /dev/null)" ]; then echo "$3 is not empty" >&2; exit 2; fi
mkdir -p "$3" && echo '{}' > "$3/config.json"
echo "fetch-model $*" >> "$FAKE_CALLS"
EOF2
  cat > "$p/sponsor.sh" << 'EOF2'
#!/usr/bin/env bash
# like the real one: "<address> <HTTP code> {" then FLOP's JSON answer; a sequence of codes in sponsor-seq
[ -f "${MINER_SIGNER_FILE:-/opt/flop-miner/signer}" ] || exit 2
env | grep -E '^(MINER_SIGNER_FILE|GRANT_FILE|FLOP_CLI|FLOP_RPC)=' | sort > "$FAKE_STATE/sponsor-env"
echo x >> "$FAKE_STATE/sponsor-calls"
if [ -s "$FAKE_STATE/sponsor-seq" ]; then
  code=$(sed -n 1p "$FAKE_STATE/sponsor-seq"); sed -i 1d "$FAKE_STATE/sponsor-seq"
else
  code=$(cat "$FAKE_STATE/sponsor-code" 2> /dev/null || echo 201)
fi
[ "$code" != none ] || { echo "Error: getaddrinfo EAI_AGAIN rpc.devnet.flop.network" >&2; exit 1; }
if [ "$code" = 502raw ]; then # a gateway's own page: the real script prints {} and its default action on stderr
  echo "$FAKE_ADDR 502 {}"
  echo "sponsor refused: 502 (report_to_operator): no detail. https://faucet.flop.network/limits shows the current limits." >&2
  exit 1
fi
echo "$FAKE_ADDR ${code:0:3} {"
case $code in
  409reg) printf '  "error": "already sponsored",\n  "reason": "already_sponsored"\n'; touch "$FAKE_STATE/registered" ;;
  409) printf '  "error": "already sponsored",\n  "reason": "already_sponsored"\n' ;;
  409op) printf '  "error": "already sponsored",\n  "reason": "already_sponsored",\n  "action": "report_to_operator"\n' ;;
  422) printf '  "error": "operator review needed",\n  "reason": "operator_review"\n' ;;
  400fix) printf '  "error": "issuedAt is too old",\n  "reason": "stale_request",\n  "action": "fix_request"\n' ;;
  503w) printf '  "error": "sponsor busy",\n  "reason": "sponsor_busy",\n  "action": "retry_later",\n  "retryAfterSeconds": 600\n' ;;
  429) printf '  "error": "automatic miner sponsorship is full: at most 40 automatically sponsored miners may be uncalibrated at once",\n  "reason": "auto_miner_cap_full",\n  "action": "retry_later",\n  "retryAfterSeconds": 3600\n' ;;
  429op) printf '  "error": "operator quota used up",\n  "reason": "operator_quota",\n  "action": "report_to_operator"\n' ;;
  503) printf '  "error": "sponsor temporarily unavailable",\n  "reason": "sponsor_unavailable",\n  "action": "retry_later"\n' ;;
  201) echo '  "ok": true'; [ -f "$FAKE_STATE/no-register" ] || touch "$FAKE_STATE/registered" ;;
esac
echo "}"
# the 20261106 pack's sponsor-request.mjs adds this line on stderr after a refusal
[ "$code" = 201 ] || { echo "sponsor refused: see the JSON above. https://faucet.flop.network/limits shows the current limits." >&2; exit 1; }
EOF2
  cat > "$p/retire.sh" << 'EOF2'
#!/usr/bin/env bash
echo "retire MINER_SIGNER_FILE=${MINER_SIGNER_FILE:-}" >> "$FAKE_CALLS"
[ ! -f "$FAKE_STATE/retire-fail" ] || { echo "$FAKE_ADDR not retired: an open session"; exit 1; }
if [ ! -f "$FAKE_STATE/registered" ]; then echo "$FAKE_ADDR is not a registered miner; nothing to retire"; exit 0; fi
echo "$FAKE_ADDR deregistered in finalized block 0x01; sponsored stake unbonds over 7 days"
rm -f "$FAKE_STATE/registered"
EOF2
  chmod 755 "$p"/*.sh
  tar -czf "$1" -C "$W/pack-src" flop-miner-pack-test
}
make_pack "$W/pack.tar.gz" 0x1111
make_pack "$W/pack2.tar.gz" 0x2222
SUM=$(sha256sum "$W/pack.tar.gz" | cut -d' ' -f1)
SUM2=$(sha256sum "$W/pack2.tar.gz" | cut -d' ' -f1)
PACK=$W/pack.tar.gz

# --- bench ------------------------------------------------------------------------------------------------------
PASS=0 FAIL=0 CASE=''
check() { # check DESCRIPTION COMMAND...
  if "${@:2}" > /dev/null 2>&1; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL [%s] %s\n' "$CASE" "$1"
    sed 's/^/      | /' "$W/out" | tail -n 25
  fi
}
has() { grep -qF -- "$1" "$W/out"; }
hasnt() { ! grep -qF -- "$1" "$W/out"; }
called() { grep -qF -- "$1" "$W/calls"; }
mode_of() { [ "$(stat -c %a "$1")" = "$2" ]; }
count() { [ "$(grep -c . "$1" 2> /dev/null || echo 0)" = "$2" ]; }
fake_cloudflared() {
  printf '#!/bin/bash\necho "cloudflared version 2026.10.7 (built 2026-10-30)"\n' > /usr/local/bin/cloudflared
  chmod 755 /usr/local/bin/cloudflared
}
fresh() { # a machine where nothing was installed
  CASE=$1
  rm -rf /opt/flop-miner /opt/flop-miner.retired /usr/local/bin/flop-miner /usr/local/bin/cloudflared \
    /var/log/flop-miner.log "$F"
  rm -f /etc/systemd/system/flop-miner-*
  mkdir -p "$F" /etc/systemd/system
  : > "$W/calls"
  SUM_RUN=$SUM PACK=$W/pack.tar.gz
}
fm() { # fm ARGS...: flop-miner with the fakes; output in $W/out, exit code in RC
  env PATH="$FAKES:$PATH" FAKE_STATE="$F" FAKE_CALLS="$W/calls" FAKE_PACK="$PACK" \
    FLOP_MINER_ALLOW_CONTAINER=1 FLOP_MINER_WAIT=200 \
    FLOP_MINER_PACK_URL=https://flop.network/releases/test/flop-miner-pack-test.tar.gz FLOP_MINER_PACK_SHA256="$SUM_RUN" \
    bash "${FM:-$SCRIPT}" "$@" > "$W/out" 2>&1 < /dev/null
  RC=$?
}

fresh "install, public address"
fm install --yes
check "exit 0" [ "$RC" = 0 ]
check "says installed" has "Your FLOP miner is installed and running."
check "says no airdrop" has "no earnings and no airdrop"
check "miner-key.json root-only" mode_of /opt/flop-miner/miner-key.json 600
check "signer root-only" mode_of /opt/flop-miner/signer 600
check "signer holds the phrase" grep -qxF "$FAKE_PHRASE" /opt/flop-miner/signer
check "address written" grep -qxF "$FAKE_ADDR" /opt/flop-miner/address
check "session seed root-only" mode_of /opt/flop-miner/session-keys/enclave.seed 600
check "session seed is 32 random bytes" grep -qE '^[0-9a-f]{64}$' /opt/flop-miner/session-keys/enclave.seed
check "miner.env root-only" mode_of /opt/flop-miner/miner.env 600
check "public name from the IP" grep -qxF SESSION_PUBLIC_HOST=203-0-113-10.sslip.io /opt/flop-miner/miner.env
check "inference key drawn" grep -qE '^INFERENCE_API_KEY=[0-9a-f]{64}$' /opt/flop-miner/miner.env
check "session token drawn" grep -qE '^SESSION_AUTH_TOKEN=[0-9a-f]{64}$' /opt/flop-miner/miner.env
check "decode policy written by the pack" grep -qxF DECODE_POLICY_HASH=0xfeed /opt/flop-miner/miner.env
CLI_PIN='ghcr\.io/flop-labs/flop-core/cli:v0\.1\.220@sha256:[0-9a-f]{64}'
check "CLI image pulled, pinned, before the time limit" grep -qE "^docker pull -q $CLI_PIN\$" "$W/calls"
check "decode-policy gets the settings' CLI and RPC" grep -qE "^decode-policy FLOP_CLI=$CLI_PIN FLOP_RPC=wss://rpc\.devnet\.flop\.network\$" "$W/calls"
check "CLI pinned by version and digest" grep -qE "^FLOP_CLI=$CLI_PIN\$" /opt/flop-miner/miner.env
check "worker pinned by version and digest" grep -qE '^FLOP_WORKER_IMAGE=ghcr\.io/flop-labs/flop-core/miner-worker:v0\.1\.286@sha256:[0-9a-f]{64}$' /opt/flop-miner/miner.env
check "backend pinned by version and digest" grep -qE '^FLOP_BACKEND_IMAGE=ghcr\.io/flop-labs/flop-core/miner-vllm-toploc:v0\.1\.239@sha256:[0-9a-f]{64}$' /opt/flop-miner/miner.env
check "no floating tag left" bash -c "! grep -q ':stable' /opt/flop-miner/miner.env"
check "FLOP's limits read before the request" called "curl https://faucet.flop.network/limits"
check "the sponsor's last registrations read" called "curl https://explorer.devnet.flop.network/api/transactions?section=minerStaking"
check "says the block of the registration" has "Sponsored: FLOP registered your miner at block 42"
check "account created once" count "$F/keygen" 1
check "keygen pinned by digest, offline" called "docker run --rm --network none --log-driver none --user 0:0 --entrypoint zkv-relay ghcr.io/flop-labs/flop-core/node-devnet:sha-eea56e7@sha256:61f1eebdc5ba2e58"
check "model fetched" called "fetch-model Qwen/Qwen2.5-0.5B-Instruct 7ae557604adf67be50417f59c2c2f167def9a775 /opt/flop-miner/models/qwen2.5-0.5b-instruct"
check "no stamp inside the model directory" [ "$(ls -A /opt/flop-miner/models/qwen2.5-0.5b-instruct)" = config.json ]
check "compose with the TLS sidecar" grep -qF "docker-compose.tls.yml" "$F/last-up"
check "sponsor signs with the miner file" grep -qxF MINER_SIGNER_FILE=/opt/flop-miner/signer "$F/sponsor-env"
check "sponsored, flag holds the address" grep -qxF "$FAKE_ADDR" /opt/flop-miner/.flop-miner/sponsored
check "only the worker restarted after the sponsorship" called "docker-compose.tls.yml restart worker"
check "no retry timer once sponsored" [ ! -f "$F/sponsor-timer" ]
check "command installed" [ -x /usr/local/bin/flop-miner ]
check "log root-only" mode_of /var/log/flop-miner.log 600
check "no temporary key file left" bash -c "! ls /opt/flop-miner/.miner-key.* /opt/flop-miner/.signer.tmp 2> /dev/null"
check "no secret in the output" hasnt "$FAKE_PHRASE"
check "no secret in the log" bash -c "! grep -qF '$FAKE_PHRASE' /var/log/flop-miner.log"
SEED=$(cat /opt/flop-miner/session-keys/enclave.seed)
KEY=$(grep '^INFERENCE_API_KEY=' /opt/flop-miner/miner.env)

CASE="run again"
: > "$W/calls"
# as 0.1.0 left it: the pack's floating tag
sed -i 's|^FLOP_WORKER_IMAGE=.*|FLOP_WORKER_IMAGE=ghcr.io/flop-labs/flop-core/miner-worker:stable|' /opt/flop-miner/miner.env
fm install --yes
check "exit 0" [ "$RC" = 0 ]
check "a floating tag pinned again" grep -qE '^FLOP_WORKER_IMAGE=ghcr\.io/flop-labs/flop-core/miner-worker:v0\.1\.286@sha256:[0-9a-f]{64}$' /opt/flop-miner/miner.env
check "account kept" count "$F/keygen" 1
check "same address" grep -qxF "$FAKE_ADDR" /opt/flop-miner/address
check "same session seed" [ "$(cat /opt/flop-miner/session-keys/enclave.seed)" = "$SEED" ]
check "same inference key" grep -qxF "$KEY" /opt/flop-miner/miner.env
check "pack not downloaded again" bash -c "! grep -q 'flop-miner-pack' '$W/calls'"
check "model not fetched again" bash -c "! grep -q '^fetch-model' '$W/calls'"
check "sponsor not asked again" count "$F/sponsor-calls" 1

CASE="status"
FM=/usr/local/bin/flop-miner fm status
check "exit 0" [ "$RC" = 0 ]
check "shows the address" has "$FAKE_ADDR"
check "endpoint up" has "up (answers 401, as it should)"
check "registered" has "registered at block 42, 1000000 test FLOP of sponsored stake"
check "calibration in progress" has "in progress (3 jobs verified so far"
check "one-shot GPU probe hidden" hasnt "gpu-inventory"

CASE="status, endpoint answering on the machine only"
echo 000 > "$F/public-code"
FM=/usr/local/bin/flop-miner fm status
rm -f "$F/public-code"
check "says it answers on this machine" has "answers on this machine; check from your computer"

CASE="restart"
: > "$W/calls"
FM=/usr/local/bin/flop-miner fm restart
check "exit 0" [ "$RC" = 0 ]
check "recreates the containers" grep -qF -- "--force-recreate" "$F/last-up"

CASE="decode policy dropped by FLOP's chain"
touch "$F/policy-dropped"
FM=/usr/local/bin/flop-miner fm restart
rm -f "$F/policy-dropped"
check "exit 0" [ "$RC" = 0 ]
check "the published policy taken again" grep -qxF DECODE_POLICY_HASH=0xfeed /opt/flop-miner/miner.env

CASE="a token of the user's own"
sed -i 's/^INFERENCE_API_KEY=.*/INFERENCE_API_KEY=my-own-credential/' /opt/flop-miner/miner.env
fm install --yes
check "exit 0" [ "$RC" = 0 ]
check "kept" grep -qxF INFERENCE_API_KEY=my-own-credential /opt/flop-miner/miner.env

CASE="a new FLOP pack"
SUM_RUN=$SUM2 PACK=$W/pack2.tar.gz
fm install --yes
SUM_RUN=$SUM PACK=$W/pack.tar.gz
check "exit 0" [ "$RC" = 0 ]
check "new pack's settings" grep -qxF MODEL_HASH=0x2222 /opt/flop-miner/miner.env
check "token kept" grep -qxF INFERENCE_API_KEY=my-own-credential /opt/flop-miner/miner.env
check "public name kept" grep -qxF SESSION_PUBLIC_HOST=203-0-113-10.sslip.io /opt/flop-miner/miner.env
check "policy taken again" grep -qxF DECODE_POLICY_HASH=0xfeed /opt/flop-miner/miner.env
check "previous settings kept aside" bash -c "ls /opt/flop-miner/.flop-miner/miner.env.before-*"
check "images pinned over the new pack's tags" bash -c "! grep -q ':stable' /opt/flop-miner/miner.env"

CASE="retire"
FM=/usr/local/bin/flop-miner fm retire --yes
check "exit 0" [ "$RC" = 0 ]
check "retire.sh signs with the miner file" called "retire MINER_SIGNER_FILE=/opt/flop-miner/signer"
check "shows FLOP's answer" has "deregistered in finalized block"
check "says delete the machine" has "You can now delete the machine"
check "miner stopped" [ ! -f "$F/up" ]
check "tunnel and its timer stopped" called "systemctl disable --now flop-miner-sync.timer flop-miner-tunnel.service"
check "sponsored flag cleared" [ ! -e /opt/flop-miner/.flop-miner/sponsored ]
FM=/usr/local/bin/flop-miner fm status
check "status: retired" has "retired on "
check "status: no restart offered" hasnt "sudo flop-miner restart"
check "status: no unexpected error" hasnt "Unexpected error"

CASE="install after retire"
fm install --yes
check "exit 1" [ "$RC" = 1 ]
check "explains" has "was retired. FLOP sponsors each account only once"

fresh "sponsorship full (429), then a free slot"
echo 429 > "$F/sponsor-code"
fm install --yes
check "exit 0" [ "$RC" = 0 ]
check "says full" has "full right now (HTTP 429)"
check "shows FLOP's own words" has "FLOP says: automatic miner sponsorship is full"
check "retry timer on" [ -f "$F/sponsor-timer" ]
check "timer unit written" grep -qF "ExecStart=/usr/local/bin/flop-miner sponsor --auto" /etc/systemd/system/flop-miner-sponsor.service
check "miner still started" [ -f "$F/up" ]
check "summary says waiting" has "waiting: FLOP's sponsor is looked at every hour"
check "FLOP's wait kept" [ -s /opt/flop-miner/.flop-miner/sponsor-not-before ]
check "says until when" has "FLOP asks to wait until"
FM=/usr/local/bin/flop-miner fm status
check "status: retry on" has "looked at again every hour"
check "status: FLOP's wait" has "FLOP asked to wait until"
echo 201 > "$F/sponsor-code"
FM=/usr/local/bin/flop-miner fm sponsor --auto
check "timer run within FLOP's wait: nothing sent" count "$F/sponsor-calls" 1
FM=/usr/local/bin/flop-miner fm sponsor
check "asked by hand within FLOP's wait: nothing sent" count "$F/sponsor-calls" 1
check "asked by hand within FLOP's wait: says so" has "FLOP asked to wait until"
echo 0 > /opt/flop-miner/.flop-miner/sponsor-not-before # an hour later
FM=/usr/local/bin/flop-miner fm sponsor --auto
check "timer run: exit 0" [ "$RC" = 0 ]
check "timer run: asked once more" count "$F/sponsor-calls" 2
check "timer run: sponsored" grep -qxF "$FAKE_ADDR" /opt/flop-miner/.flop-miner/sponsored
check "timer run: timer off" [ ! -f "$F/sponsor-timer" ]

fresh "sponsor unavailable (503), then accepted"
printf '503\n201\n' > "$F/sponsor-seq"
fm install --yes
check "exit 0" [ "$RC" = 0 ]
check "asked once, no retry in a loop" count "$F/sponsor-calls" 1
check "no quick retry" bash -c "! grep -q '^sleep 60' '$W/calls'"
check "says unavailable, not full" has "unavailable right now (HTTP 503)"
check "shows FLOP's reason" has "FLOP says: sponsor temporarily unavailable (sponsor_unavailable)"
check "retry timer on" [ -f "$F/sponsor-timer" ]
FM=/usr/local/bin/flop-miner fm sponsor --auto
check "timer run: sponsored" [ -s /opt/flop-miner/.flop-miner/sponsored ]
check "timer run: asked twice in all" count "$F/sponsor-calls" 2

fresh "FLOP's limits say full (automatic_full)"
echo automatic_full > "$F/limits"
fm install --yes
check "exit 0" [ "$RC" = 0 ]
check "nothing sent" [ ! -e "$F/sponsor-calls" ]
check "says full, from the limits" has "full right now (its limits page says automatic_full)"
check "retry timer on" [ -f "$F/sponsor-timer" ]
check "miner still started" [ -f "$F/up" ]
check "no unexpected error" hasnt "Unexpected error"
FM=/usr/local/bin/flop-miner fm status
check "status: FLOP's limits shown" has "FLOP's limits on "
check "status: their status" has ": automatic_full"
FM=/usr/local/bin/flop-miner fm sponsor --auto
check "timer run while full: nothing sent" [ ! -e "$F/sponsor-calls" ]
echo open > "$F/limits"
FM=/usr/local/bin/flop-miner fm sponsor --auto
check "timer run once open: sent once" count "$F/sponsor-calls" 1
check "timer run once open: sponsored" [ -s /opt/flop-miner/.flop-miner/sponsored ]

fresh "FLOP's limits cannot read the sponsor (unknown)"
echo unknown > "$F/limits"
fm install --yes
check "exit 0" [ "$RC" = 0 ]
check "nothing sent" [ ! -e "$F/sponsor-calls" ]
check "says it is not open" has "does not say that the sponsor is open (it says unknown, sponsor_read_timeout)"
check "retry timer on" [ -f "$F/sponsor-timer" ]
FM=/usr/local/bin/flop-miner fm status
check "status: limits and reason" has "unknown (sponsor_read_timeout)"

fresh "FLOP's limits page down"
echo down > "$F/limits"
fm install --yes
check "exit 0" [ "$RC" = 0 ]
check "nothing sent" [ ! -e "$F/sponsor-calls" ]
check "says it does not answer" has "does not answer right now"

fresh "operator grant while the automatic cap is full"
echo automatic_full > "$F/limits"
jq -n --arg a "$FAKE_ADDR" '{role: "miner", account: $a, operator: "5Op", expiresAt: 1, signature: "0x00"}' > "$W/grant.json"
fm install --yes --grant "$W/grant.json"
check "exit 0" [ "$RC" = 0 ]
check "sent with the grant" grep -qxF GRANT_FILE=/opt/flop-miner/grant.json "$F/sponsor-env"
check "sponsored" [ -s /opt/flop-miner/.flop-miner/sponsored ]

fresh "sponsor failing on the chain"
touch "$F/chain-failing"
fm install --yes
check "exit 0" [ "$RC" = 0 ]
check "nothing sent" [ ! -e "$F/sponsor-calls" ]
check "says why" has "failed its latest registrations on the devnet"
check "retry timer on" [ -f "$F/sponsor-timer" ]

fresh "accepted, not on the explorer yet"
touch "$F/no-register"
fm install --yes
check "exit 0" [ "$RC" = 0 ]
check "says accepted, not registered" has "Sponsorship accepted by FLOP (HTTP 201)"
check "says to check later" has "not on FLOP's explorer yet"
check "sponsored flag set" [ -s /opt/flop-miner/.flop-miner/sponsored ]
check "explorer looked at for two minutes" [ "$(grep -c '^sleep 10' "$W/calls")" = 12 ]
FM=/usr/local/bin/flop-miner fm status
check "status: accepted, not on the explorer" has "not on the explorer yet (FLOP accepted the sponsorship on "

fresh "refusal for a person (report_to_operator)"
echo 429op > "$F/sponsor-code"
fm install --yes
check "exit 0" [ "$RC" = 0 ]
check "stops asking" has "FLOP did not sponsor this miner (HTTP 429, report_to_operator)"
check "shows FLOP's words" has "FLOP says: operator quota used up (operator_quota)"
check "no retry timer" [ ! -f "$F/sponsor-timer" ]

fresh "sponsor unreachable"
echo none > "$F/sponsor-code"
fm install --yes
check "exit 0" [ "$RC" = 0 ]
check "says no answer" has "did not answer"
check "shows the error" has "FLOP says: Error: getaddrinfo EAI_AGAIN"
check "retry timer on" [ -f "$F/sponsor-timer" ]

fresh "sponsorship refused (403), then restart, then sponsor"
echo 403 > "$F/sponsor-code"
fm install --yes
check "exit 0" [ "$RC" = 0 ]
check "says not approved" has "FLOP did not sponsor this miner (HTTP 403)"
check "no retry timer" [ ! -f "$F/sponsor-timer" ]
FM=/usr/local/bin/flop-miner fm status
check "status: refused, how to ask again" has "ask once more with: sudo flop-miner sponsor"
echo 201 > "$F/sponsor-code"
FM=/usr/local/bin/flop-miner fm restart
check "restart does not ask again after a refusal" count "$F/sponsor-calls" 1
check "restart says why" has "FLOP refused this miner earlier (HTTP 403)"
FM=/usr/local/bin/flop-miner fm sponsor
check "sponsor asks again on request" count "$F/sponsor-calls" 2
check "then sponsored" grep -qxF "$FAKE_ADDR" /opt/flop-miner/.flop-miner/sponsored

fresh "already sponsored (409), on the explorer"
echo 409reg > "$F/sponsor-code"
fm install --yes
check "exit 0" [ "$RC" = 0 ]
check "says already sponsored, with the block" has "Already sponsored: your miner is registered on FLOP's devnet (block 42)"
check "sponsored flag set" [ -s /opt/flop-miner/.flop-miner/sponsored ]

fresh "already sponsored (409), not on the explorer"
echo 409 > "$F/sponsor-code"
fm install --yes
check "exit 0" [ "$RC" = 0 ]
check "says FLOP must reconcile it" has "already sponsored (HTTP 409), but your miner is not on FLOP's explorer"
check "not marked sponsored" [ ! -e /opt/flop-miner/.flop-miner/sponsored ]
check "summary not done" hasnt "done: calibration starts by itself"
check "no retry timer" [ ! -f "$F/sponsor-timer" ]
FM=/usr/local/bin/flop-miner fm restart
check "restart does not ask again" count "$F/sponsor-calls" 1

fresh "409 that FLOP sends to a person (report_to_operator)"
echo 409op > "$F/sponsor-code"
fm install --yes
check "FLOP's action first" has "FLOP did not sponsor this miner (HTTP 409, report_to_operator)"
check "not marked sponsored" [ ! -e /opt/flop-miner/.flop-miner/sponsored ]

fresh "operator review (422)"
echo 422 > "$F/sponsor-code"
fm install --yes
check "exit 0" [ "$RC" = 0 ]
check "stops asking" has "FLOP did not sponsor this miner (HTTP 422)"
check "no retry timer" [ ! -f "$F/sponsor-timer" ]

fresh "request to change (fix_request), then restart"
echo 400fix > "$F/sponsor-code"
fm install --yes
check "stops asking" has "FLOP did not sponsor this miner (HTTP 400, fix_request)"
check "shows FLOP's words" has "FLOP says: issuedAt is too old (stale_request)"
FM=/usr/local/bin/flop-miner fm restart
check "restart sends nothing more" count "$F/sponsor-calls" 1

fresh "a gateway's 502 without FLOP's answer, from the timer"
echo 429 > "$F/sponsor-code"
fm install --yes
echo 0 > /opt/flop-miner/.flop-miner/sponsor-not-before
echo 502raw > "$F/sponsor-code"
FM=/usr/local/bin/flop-miner fm sponsor --auto
check "timer run: exit 0" [ "$RC" = 0 ]
check "asked twice in all" count "$F/sponsor-calls" 2
check "the timer stays on" [ -f "$F/sponsor-timer" ]
check "no stop recorded" [ ! -e /opt/flop-miner/.flop-miner/sponsor-stopped ]
FM=/usr/local/bin/flop-miner fm status
check "status: last answer 502" has "last answer: HTTP 502"

fresh "503 with FLOP's wait"
echo 503w > "$F/sponsor-code"
fm install --yes
check "exit 0" [ "$RC" = 0 ]
check "says unavailable" has "unavailable right now (HTTP 503)"
check "FLOP's wait kept" [ -s /opt/flop-miner/.flop-miner/sponsor-not-before ]
check "says until when" has "FLOP asks to wait until"

fresh "daily limit reached"
echo daily_limit_reached > "$F/limits"
fm install --yes
check "exit 0" [ "$RC" = 0 ]
check "nothing sent" [ ! -e "$F/sponsor-calls" ]
check "says full, from the limits" has "full right now (its limits page says daily_limit_reached)"

fresh "daily limit reached, with an operator grant"
echo daily_limit_reached > "$F/limits"
jq -n --arg a "$FAKE_ADDR" '{role: "miner", account: $a, operator: "5Op", expiresAt: 1, signature: "0x00"}' > "$W/grant.json"
fm install --yes --grant "$W/grant.json"
check "sent with the grant" count "$F/sponsor-calls" 1

fresh "a stopped miner is not registered"
echo 429 > "$F/sponsor-code"
fm install --yes
echo 0 > /opt/flop-miner/.flop-miner/sponsor-not-before
FM=/usr/local/bin/flop-miner fm stop --yes
echo 201 > "$F/sponsor-code"
FM=/usr/local/bin/flop-miner fm sponsor --auto
check "timer run while stopped: nothing sent" count "$F/sponsor-calls" 1
check "not sponsored" [ ! -e /opt/flop-miner/.flop-miner/sponsored ]
FM=/usr/local/bin/flop-miner fm status
check "status: on hold" has "on hold while the miner is stopped"
FM=/usr/local/bin/flop-miner fm sponsor
check "sponsor by hand while stopped: says so" has "The miner is stopped: start it with sudo flop-miner restart"
check "sponsor by hand while stopped: nothing sent" count "$F/sponsor-calls" 1
FM=/usr/local/bin/flop-miner fm restart
check "restart asks" count "$F/sponsor-calls" 2
check "then sponsored" [ -s /opt/flop-miner/.flop-miner/sponsored ]

fresh "7 days without a free slot"
echo automatic_full > "$F/limits"
fm install --yes
echo 1 > /opt/flop-miner/.flop-miner/sponsor-since
echo open > "$F/limits"
FM=/usr/local/bin/flop-miner fm sponsor --auto
check "timer run after 7 days: nothing sent" [ ! -e "$F/sponsor-calls" ]
check "timer off" [ ! -f "$F/sponsor-timer" ]
check "logged" grep -qF "automatic sponsorship retry stopped after 7 days" /var/log/flop-miner.log

fresh "another account restored"
fm install --yes
OTHER=5HxRestoredAccountFromBackupXyz11111111111111111 # base58: no 0, O, I or l
echo "$OTHER" > "$F/inspect-addr"
jq --arg a "$OTHER" '.ss58Address = $a' /opt/flop-miner/miner-key.json > "$W/k.json" && cat "$W/k.json" > /opt/flop-miner/miner-key.json
echo "HTTP 403" > /opt/flop-miner/.flop-miner/sponsor-stopped
rm -f "$F/registered"
fm install --yes
rm -f "$F/inspect-addr"
check "exit 0" [ "$RC" = 0 ]
check "says the account changed" has "The miner account changed"
check "the other account's refusal forgotten" [ ! -e /opt/flop-miner/.flop-miner/sponsor-stopped ]
check "asked for the new account" count "$F/sponsor-calls" 2
check "flag for the new account" grep -qxF "$OTHER" /opt/flop-miner/.flop-miner/sponsored

fresh "decode-policy check past its time limit"
touch "$F/timeout-decode-policy.sh"
fm install --yes
check "exit 1" [ "$RC" = 1 ]
check "explains" has "decode-policy check did not pass (code 124)"
check "the container left behind found by image ID" called "docker ps -aq --filter ancestor=sha256:fakecli --filter volume=/app/decode-policy.mjs"
check "and removed" called "docker rm -f fakecid"

fresh "operator grant"
jq -n --arg a "$FAKE_ADDR" '{role: "miner", account: $a, operator: "5Op", expiresAt: 1, signature: "0x00"}' > "$W/grant.json"
fm install --yes --grant "$W/grant.json"
check "exit 0" [ "$RC" = 0 ]
check "grant sent with the request" grep -qxF GRANT_FILE=/opt/flop-miner/grant.json "$F/sponsor-env"
fm install --yes --grant /opt/flop-miner/grant.json
check "the grant already in place: exit 0" [ "$RC" = 0 ]

fresh "grant for another account"
jq -n '{role: "miner", account: "5SomeoneElse"}' > "$W/grant.json"
fm install --yes --grant "$W/grant.json"
check "exit 1" [ "$RC" = 1 ]
check "explains" has "is not a grant for this miner"
check "nothing asked" [ ! -e "$F/sponsor-calls" ]

fresh "wrong pack fingerprint"
SUM_RUN=0000000000000000
fm install --yes
check "exit 1" [ "$RC" = 1 ]
check "says fingerprint" has "does not have the expected fingerprint"
check "no account created" [ ! -e /opt/flop-miner/signer ]

fresh "GPU with 12 GB"
echo "NVIDIA GeForce RTX 3060, 12288, 580.95.05, 8.6" > "$F/gpu"
fm install --yes
check "exit 1" [ "$RC" = 1 ]
check "says 16 GB" has "FLOP needs at least 16 GB"
check "nothing installed" [ ! -e /opt/flop-miner ]

fresh "16 GB card (16 311 MiB)"
echo "NVIDIA GeForce RTX 5060 Ti, 16311, 580.95.05, 12.0" > "$F/gpu"
fm install --yes
check "accepted" [ "$RC" = 0 ]

fresh "old driver"
echo "NVIDIA L4, 23034, 550.54.15, 8.9" > "$F/gpu"
fm install --yes
check "exit 1" [ "$RC" = 1 ]
check "says 580" has "needs 580.65.06 or newer"

fresh "GPU without BF16"
echo "Tesla T4, 15360, 580.95.05, 7.5" > "$F/gpu"
fm install --yes
check "exit 1" [ "$RC" = 1 ]
check "says compute capability" has "compute capability 7.5"

fresh "no driver, no terminal"
mv "$FAKES/nvidia-smi" "$W/nvidia-smi.off"
fm install
mv "$W/nvidia-smi.off" "$FAKES/nvidia-smi"
check "exit 1" [ "$RC" = 1 ]
check "explains" has "No NVIDIA driver on this machine"
check "asks for --yes" has "run the same command again with --yes"

fresh "no driver, --yes"
mv "$FAKES/nvidia-smi" "$W/nvidia-smi.off"
fm install --yes
mv "$W/nvidia-smi.off" "$FAKES/nvidia-smi"
check "exit 3 (reboot, then run again)" [ "$RC" = 3 ]
check "Ubuntu's driver installed" called "install -y -q linux-headers-6.8.0-fake nvidia-driver-580-server-open"
check "apt waits for the lock" called "apt-get -o DPkg::Lock::Timeout=600"
check "says reboot" has "sudo reboot"

fresh "no confirmation without a terminal"
fm install
check "exit 1" [ "$RC" = 1 ]
check "asks for --yes" has "with --yes"
check "nothing installed" [ ! -e /opt/flop-miner ]

fresh "a container"
env PATH="$FAKES:$PATH" FAKE_STATE="$F" FAKE_CALLS="$W/calls" bash "$SCRIPT" install --yes > "$W/out" 2>&1 < /dev/null
RC=$?
check "exit 1" [ "$RC" = 1 ]
check "says pod" has "not a full virtual machine"

fresh "small disk"
echo 30 > "$F/disk-gb"
fm install --yes
check "exit 1" [ "$RC" = 1 ]
check "says disk" has "Only 30 GB of free disk"

fresh "port 80 taken"
touch "$F/port-used"
fm install --yes
check "exit 1" [ "$RC" = 1 ]
check "names the program" has "(by nginx)"

fresh "own domain pointing elsewhere"
echo 198.51.100.7 > "$F/dns"
fm install --yes --domain miner.example.org
check "exit 1" [ "$RC" = 1 ]
check "explains the A record" has "create an A record for miner.example.org with the value 203.0.113.10"

fresh "own domain"
echo 203.0.113.10 > "$F/dns"
fm install --yes --domain miner.example.org
check "exit 0" [ "$RC" = 0 ]
check "domain used" grep -qxF SESSION_PUBLIC_HOST=miner.example.org /opt/flop-miner/miner.env
: > "$W/calls"
fm install --yes
check "rerun keeps the domain" grep -qxF SESSION_PUBLIC_HOST=miner.example.org /opt/flop-miner/miner.env

fresh "IP lookup down on a re-run"
fm install --yes
touch "$F/no-ip"
fm install --yes
rm -f "$F/no-ip"
check "exit 0" [ "$RC" = 0 ]
check "keeps the public name" grep -qxF SESSION_PUBLIC_HOST=203-0-113-10.sslip.io /opt/flop-miner/miner.env
check "stays in public mode" grep -qxF public /opt/flop-miner/.flop-miner/mode

fresh "NVIDIA toolkit missing"
touch "$F/no-nvidia"
echo gnupg > "$F/missing-pkgs"
fm install --yes
check "exit 0" [ "$RC" = 0 ]
check "missing package installed" called "install -y -q gnupg"
check "toolkit installed" called "install -y -q nvidia-container-toolkit"
check "Docker given the GPU" called "nvidia-ctk runtime configure --runtime=docker"

fresh "decode policy refused"
touch "$F/policy-fail"
fm install --yes
check "exit 1" [ "$RC" = 1 ]
check "explains" has "decode-policy check did not pass"
check "says run the same command again" has "run the same command again"
check "nothing started" [ ! -f "$F/up" ]

fresh "tunnel"
fake_cloudflared
fm install --yes --tunnel
check "exit 0" [ "$RC" = 0 ]
check "tunnel name" grep -qxF SESSION_PUBLIC_HOST=fake-tunnel-1.trycloudflare.com /opt/flop-miner/miner.env
check "no TLS sidecar" bash -c "! grep -q docker-compose.tls.yml '$F/last-up'"
check "tunnel units written" [ -f /etc/systemd/system/flop-miner-tunnel.service ] && [ -f /etc/systemd/system/flop-miner-sync.timer ]
check "no port check in tunnel mode" bash -c "! grep -q '^ss ' '$W/calls'"
echo 'ERR Failed to request quick Tunnel: Post "https://api.trycloudflare.com/tunnel": dial tcp: lookup api.trycloudflare.com' >> /opt/flop-miner/.flop-miner/tunnel.log
FM=/usr/local/bin/flop-miner fm tunnel-sync
check "Cloudflare's API host is never the tunnel" grep -qxF SESSION_PUBLIC_HOST=fake-tunnel-1.trycloudflare.com /opt/flop-miner/miner.env
echo "INF |  https://fake-tunnel-9.trycloudflare.com  |" >> /opt/flop-miner/.flop-miner/tunnel.log
FM=/usr/local/bin/flop-miner fm tunnel-sync
check "sync: exit 0" [ "$RC" = 0 ]
check "sync follows a new address" grep -qxF SESSION_PUBLIC_HOST=fake-tunnel-9.trycloudflare.com /opt/flop-miner/miner.env
check "sync restarts the worker" grep -qF -- "--pull never" "$F/last-up"
FM=/usr/local/bin/flop-miner fm stop --yes
check "stop: exit 0" [ "$RC" = 0 ]
echo "INF |  https://fake-tunnel-10.trycloudflare.com  |" >> /opt/flop-miner/.flop-miner/tunnel.log
FM=/usr/local/bin/flop-miner fm tunnel-sync
check "after stop, sync updates the settings" grep -qxF SESSION_PUBLIC_HOST=fake-tunnel-10.trycloudflare.com /opt/flop-miner/miner.env
check "after stop, sync does not start the miner" [ ! -f "$F/up" ]
FM=/usr/local/bin/flop-miner fm status
check "status: stopped by the user" has "stopped by you"
fm install --yes --public
check "back to ports 80 and 443: exit 0" [ "$RC" = 0 ]
check "back to public mode" grep -qxF public /opt/flop-miner/.flop-miner/mode
check "back to the IP's name" grep -qxF SESSION_PUBLIC_HOST=203-0-113-10.sslip.io /opt/flop-miner/miner.env

fresh "unreachable on 80 and 443, then tunnel"
fake_cloudflared
echo 000 > "$F/public-code"
echo 000 > "$F/local-code"
touch "$F/tls-error"
fm install --yes
check "exit 0" [ "$RC" = 0 ]
check "explains the certificate" has "could not get its HTTPS certificate"
check "shows Caddy's error" has "acme:error:connection"
check "switched to the tunnel" grep -qxF tunnel /opt/flop-miner/.flop-miner/mode
check "tunnel name" grep -qxF SESSION_PUBLIC_HOST=fake-tunnel-1.trycloudflare.com /opt/flop-miner/miner.env

fresh "the worker itself does not answer"
fake_cloudflared
echo 502 > "$F/public-code"
echo 502 > "$F/local-code"
echo 000 > "$F/worker-code"
fm install --yes
check "exit 1" [ "$RC" = 1 ]
check "blames the miner, not the network" has "The miner itself does not answer yet"
check "no switch to the tunnel" grep -qxF public /opt/flop-miner/.flop-miner/mode

fresh "public address answers only locally"
echo 000 > "$F/public-code"
fm install --yes
check "exit 0" [ "$RC" = 0 ]
check "explains" has "works on this machine, but its public address does not answer"

fresh "signer and miner-key.json disagree"
fm install --yes
echo 5DifferentAccountXyz1111111111111111111111111111 > "$F/inspect-addr"
fm install --yes
rm -f "$F/inspect-addr"
check "exit 1" [ "$RC" = 1 ]
check "explains" has "are two different accounts"

fresh "account files gone, address still known"
fm install --yes
mkdir -p "$W/aside" && mv /opt/flop-miner/signer /opt/flop-miner/miner-key.json "$W/aside/"
fm install --yes
check "exit 1" [ "$RC" = 1 ]
check "explains" has "The files of your miner account are missing"
check "no new account drawn" count "$F/keygen" 1
mv "$W/aside/signer" "$W/aside/miner-key.json" /opt/flop-miner/

fresh "empty signer file"
mkdir -p /opt/flop-miner/.flop-miner && : > /opt/flop-miner/signer
fm install --yes
check "exit 1" [ "$RC" = 1 ]
check "explains" has "signer is empty"
check "no secret phrase left aside" bash -c "! ls /opt/flop-miner/.miner-key.* 2> /dev/null"

fresh "interrupted model download"
fm install --yes
rm -f /opt/flop-miner/.flop-miner/model-*
: > "$W/calls"
fm install --yes
check "exit 0" [ "$RC" = 0 ]
check "goes on with --resume" called "fetch-model Qwen/Qwen2.5-0.5B-Instruct 7ae557604adf67be50417f59c2c2f167def9a775 /opt/flop-miner/models/qwen2.5-0.5b-instruct --resume"

fresh "uninstall"
fm install --yes
FM=/usr/local/bin/flop-miner fm uninstall --yes
check "exit 0" [ "$RC" = 0 ]
check "warns while registered" has "still registered on FLOP's devnet"
check "command removed" [ ! -e /usr/local/bin/flop-miner ]
check "keys kept" [ -s /opt/flop-miner/signer ]

CASE="help without root"
check "help works for anyone" bash -c "su nobody -s /bin/bash -c 'bash $SCRIPT help' | grep -q 'sudo flop-miner status'"

printf '\n%s checks passed, %s failed\n' "$PASS" "$FAIL"
rm -rf "$W"
[ "$FAIL" = 0 ]
