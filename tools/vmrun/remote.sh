#!/bin/bash
# The VM side of tools/vmrun/vmrun: the startup script a new VM runs at
# boot. It reads the run from the instance's metadata, installs Zig
# (pinned and checked), unpacks the tree, runs the job, uploads
# /opt/vmrun/results to the run's bucket (results/exit last, which is
# what the driver waits for), and powers off.
set -u
MD=http://metadata.google.internal/computeMetadata/v1
md() { curl -sf -H "Metadata-Flavor: Google" "$MD/instance/attributes/$1"; }
BK=$(md bucket)
tok() { curl -s -H "Metadata-Flavor: Google" "$MD/instance/service-accounts/default/token" | sed -n 's/.*"access_token" *: *"\([^"]*\)".*/\1/p'; }
get() { curl -sf -H "Authorization: Bearer $(tok)" -o "$2" "https://storage.googleapis.com/storage/v1/b/$BK/o/${1//\//%2F}?alt=media"; }
put() { curl -sf -X POST -H "Authorization: Bearer $(tok)" -H "Content-Type: application/octet-stream" --data-binary "@$2" "https://storage.googleapis.com/upload/storage/v1/b/$BK/o?uploadType=media&name=${1//\//%2F}" > /dev/null; }

W=/opt/vmrun
RES=$W/results
mkdir -p "$RES"
cd "$W"
export HOME=/root DEBIAN_FRONTEND=noninteractive
exec > >(tee -a "$RES/boot.log") 2>&1
T0=$(date +%s)

stage() {
  echo "[$(( $(date +%s) - T0 ))s] $1" >> "$RES/stages"
  printf '%s\n' "$1" > "$W/stage"
  put results/stage "$W/stage" || true
}
finish() {
  (cd "$RES" && find . -type f ! -name exit) | while read -r f; do put "results/${f#./}" "$RES/${f#./}" || true; done
  put results/exit "$RES/exit"
  sync
  poweroff
  exit 0
}
fail() {
  echo "vmrun: $1"
  echo 125 > "$RES/exit"
  finish
}

JOB=$(md job)
ZIG_VERSION=$(md zig-version)
ZIG_SHA=$(md zig-sha256)
# The VM deletes itself this long after it starts, which is a little
# before this script did: the job's deadline errs early, never late.
DEADLINE=$((T0 + $(md timeout-seconds)))
ARGS=()
while IFS= read -r a; do [ -n "$a" ] && ARGS+=("$a"); done < <(md job-args || true)

{ uname -a; nproc; free -h | head -2; . /etc/os-release && echo "$PRETTY_NAME"; } > "$RES/info.txt"

stage "installing"
apt-get update -q > "$RES/apt.log" 2>&1 && apt-get install -y -q xz-utils >> "$RES/apt.log" 2>&1 || fail "apt-get install xz-utils failed (results/apt.log)"

pin() { # url, sha256, file
  curl -sfL -o "$3" "$1" || fail "download $1 failed"
  echo "$2  $3" | sha256sum -c --quiet || fail "$1 does not have the pinned SHA-256"
}

stage "zig $ZIG_VERSION"
pin "https://ziglang.org/download/$ZIG_VERSION/zig-x86_64-linux-$ZIG_VERSION.tar.xz" "$ZIG_SHA" zig.tar.xz
tar xf zig.tar.xz
export PATH=$W/zig-x86_64-linux-$ZIG_VERSION:$PATH

stage "unpacking"
mkdir -p src
get src.tgz src.tgz || fail "no src.tgz in the bucket"
tar xzf src.tgz -C src || fail "src.tgz does not unpack"

stage "running $JOB${ARGS[*]:+ ${ARGS[*]}}"
zig version >> "$RES/info.txt"
(cd src && RESULTS=$RES VMRUN_DEADLINE=$DEADLINE bash "$JOB" "${ARGS[@]}") > "$RES/job.log" 2>&1
echo $? > "$RES/exit"
stage "done, exit $(cat "$RES/exit")"
finish
