#!/usr/bin/env bash
# LM-Switchyard M0 hardware probe.
#
#   probe.sh facts            Collect hardware, GPU memory mode and existing vLLM facts.
#   probe.sh sleep [options]  Test vLLM Sleep Mode (level 1 and level 2) with a small model.
#
# Reports are written to ./probe-reports/<host>-<timestamp>/. Secrets (API keys,
# tokens, passwords) are redacted from everything the probe records.

set -uo pipefail

PROBE_VERSION="0.1.0"
HOST_NAME="$(hostname 2>/dev/null || echo unknown)"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${PROBE_OUT_DIR:-./probe-reports/${HOST_NAME}-${STAMP}}"

# ---------------------------------------------------------------- helpers

die() { echo "error: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
now() { date +%s.%N; }
elapsed() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.2f", b - a }'; }

# Redact anything that looks like a secret: --api-key values, *TOKEN*/*KEY*/
# *SECRET*/*PASSWORD* assignments, and Hugging Face tokens.
redact() {
  sed -E \
    -e 's/(--api-key[= ]+)[^ ",]+/\1<redacted>/g' \
    -e 's/(--hf-token[= ]+)[^ ",]+/\1<redacted>/g' \
    -e 's/([A-Za-z0-9_]*(TOKEN|KEY|SECRET|PASSWORD|PASSWD)[A-Za-z0-9_]*[=:] *)[^ ",]+/\1<redacted>/gI' \
    -e 's/hf_[A-Za-z0-9]{16,}/hf_<redacted>/g' \
    -e 's/(Bearer +)[^ ",]+/\1<redacted>/g'
}

# Write a section with a command's output in a code block. Never fails.
section() {
  local title="$1"; shift
  {
    echo "### ${title}"
    echo
    echo '```'
    if "$@" 2>&1 | redact; then :; fi
    echo '```'
    echo
  } >>"$REPORT"
}

kv() { echo "- **$1**: $2" >>"$REPORT"; }

is_wsl() { grep -qi microsoft /proc/version 2>/dev/null; }

docker_ok() { have docker && docker info >/dev/null 2>&1; }

docker_status() {
  if ! have docker; then echo "not installed"; return; fi
  local v
  v="$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
  if [ -n "$v" ]; then echo "$v"
  else echo "installed, but the daemon is not reachable (not running, or this user lacks permission)"
  fi
}

amd_cards() {
  local d
  for d in /sys/class/drm/card*/device; do
    [ -r "$d/vendor" ] || continue
    [ "$(cat "$d/vendor")" = "0x1002" ] || continue
    [ -r "$d/mem_info_vram_total" ] || continue
    echo "$d"
  done | sort -u
}

# Sum a sysfs memory counter over all AMD GPUs, in MiB.
amd_sum_mib() {
  local file="$1" total=0 d v
  for d in $(amd_cards); do
    [ -r "$d/$file" ] || continue
    v="$(cat "$d/$file")"
    total=$((total + v))
  done
  echo $((total / 1048576))
}

nvidia_used_mib() {
  have nvidia-smi || { echo "n/a"; return; }
  nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null \
    | awk '{ s += $1 } END { if (NR) print s; else print "n/a" }'
}

ram_avail_mib() {
  awk '/^MemAvailable:/ { printf "%d", $2 / 1024 }' /proc/meminfo
}

gpu_vendor() {
  # PROBE_GPU_VENDOR overrides detection; used by tools/probe/testing.
  if [ -n "${PROBE_GPU_VENDOR:-}" ]; then echo "$PROBE_GPU_VENDOR"
  elif [ -n "$(amd_cards)" ]; then echo amd
  elif have nvidia-smi && nvidia-smi -L >/dev/null 2>&1; then echo nvidia
  else echo none
  fi
}

# One memory snapshot: "<gpu_used_mib> <gtt_used_mib> <ram_avail_mib>".
mem_snapshot() {
  case "$(gpu_vendor)" in
    amd) echo "$(amd_sum_mib mem_info_vram_used) $(amd_sum_mib mem_info_gtt_used) $(ram_avail_mib)" ;;
    nvidia) echo "$(nvidia_used_mib) n/a $(ram_avail_mib)" ;;
    *) echo "n/a n/a $(ram_avail_mib)" ;;
  esac
}

http_code() {
  # http_code METHOD URL [JSON_BODY]
  local method="$1" url="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -s -o /dev/null -w '%{http_code}' -m 600 -X "$method" -H 'Content-Type: application/json' -d "$body" "$url"
  else
    curl -s -o /dev/null -w '%{http_code}' -m 600 -X "$method" "$url"
  fi
}

# ---------------------------------------------------------------- facts

vllm_containers() {
  have docker || return 0
  docker ps -a --no-trunc --format '{{.ID}}\t{{.Image}}\t{{.Names}}\t{{.Status}}\t{{.Command}}' 2>/dev/null \
    | grep -i vllm
}

env_names_and_safe_values() {
  # Print env var names; show values only for prefixes that never hold secrets.
  docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null \
    | while IFS= read -r line; do
        [ -n "$line" ] || continue
        name="${line%%=*}"
        case "$name" in
          *TOKEN*|*KEY*|*SECRET*|*PASSWORD*) echo "$name=<redacted>" ;;
          HSA_*|HIP_*|ROCR_*|ROCM_*|VLLM_*|PYTORCH_*|TORCH_*|AMD_*|MIOPEN_*|TRITON_*|CUDA_*|NVIDIA_*|HF_HUB_OFFLINE|HF_ENDPOINT|HF_HOME|NCCL_*|OMP_*)
            echo "$line" ;;
          *) echo "$name=<value not recorded>" ;;
        esac
      done
}

describe_container() {
  local id="$1"
  docker inspect --format \
'name: {{.Name}}
image: {{.Config.Image}}
state: {{.State.Status}} (started {{.State.StartedAt}})
entrypoint: {{json .Config.Entrypoint}}
cmd: {{json .Config.Cmd}}
network_mode: {{.HostConfig.NetworkMode}}
ports: {{json .HostConfig.PortBindings}}
devices: {{json .HostConfig.Devices}}
device_requests: {{json .HostConfig.DeviceRequests}}
group_add: {{json .HostConfig.GroupAdd}}
ipc_mode: {{.HostConfig.IpcMode}}
restart_policy: {{.HostConfig.RestartPolicy.Name}}
mounts:{{range .Mounts}}
  {{.Source}} -> {{.Destination}}{{end}}
labels:{{range $k, $v := .Config.Labels}}
  {{$k}}={{$v}}{{end}}' "$id" 2>&1
  echo "env:"
  env_names_and_safe_values "$id" | sed 's/^/  /'
}

# Find host ports that look like vLLM API ports: published ports of vLLM
# containers, ports of vLLM processes, plus the default 8000.
candidate_ports() {
  {
    echo 8000
    if have docker; then
      local id
      for id in $(vllm_containers | cut -f1); do
        docker port "$id" 2>/dev/null | sed -nE 's/.*:([0-9]+)$/\1/p'
        # host networking: read --port from the command line
        docker inspect --format '{{json .Config.Cmd}}' "$id" 2>/dev/null \
          | grep -oE -- '--port"?,? ?"?[0-9]+' | grep -oE '[0-9]+$'
      done
    fi
    ps -eo args 2>/dev/null | grep -E 'vllm|api_server' | grep -v grep \
      | grep -oE -- '--port[= ]+[0-9]+' | grep -oE '[0-9]+$'
  } | sort -un
}

probe_endpoint() {
  local port="$1" path code body
  for path in /health /version /v1/models; do
    code="$(curl -s -o /tmp/lmsy-probe-body.$$ -w '%{http_code}' -m 3 "http://127.0.0.1:${port}${path}")"
    body="$(head -c 600 /tmp/lmsy-probe-body.$$ 2>/dev/null | tr '\n' ' ')"
    echo "GET :${port}${path} -> ${code} ${body}"
  done
  rm -f /tmp/lmsy-probe-body.$$
}

memory_mode_guess() {
  local vram_total gtt_total ram_total_mib
  vram_total="$(amd_sum_mib mem_info_vram_total)"
  gtt_total="$(amd_sum_mib mem_info_gtt_total)"
  ram_total_mib="$(awk '/^MemTotal:/ { printf "%d", $2 / 1024 }' /proc/meminfo)"
  echo "vram_total_mib=${vram_total} gtt_total_mib=${gtt_total} system_ram_mib=${ram_total_mib}"
  if [ "$vram_total" -ge 16384 ] && [ "$vram_total" -lt "$gtt_total" ] ; then
    echo "guess: large carve-out (BIOS) plus GTT"
  elif [ "$vram_total" -ge 16384 ]; then
    echo "guess: large carve-out (BIOS)"
  elif [ "$gtt_total" -gt "$vram_total" ]; then
    echo "guess: small carve-out, GPU memory mostly from GTT (shared system RAM)"
  else
    echo "guess: unclear — see raw counters"
  fi
}

cmd_facts() {
  mkdir -p "$OUT_DIR"
  REPORT="$OUT_DIR/facts.md"
  : >"$REPORT"
  {
    echo "# LM-Switchyard probe: facts"
    echo
  } >>"$REPORT"
  kv "probe version" "$PROBE_VERSION"
  kv "date" "$(date -Iseconds)"
  kv "host" "$HOST_NAME"
  kv "os" "$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
  kv "kernel" "$(uname -r)"
  kv "wsl" "$(is_wsl && echo "yes (${WSL_DISTRO_NAME:-unknown distro})" || echo no)"
  kv "cpu" "$(lscpu 2>/dev/null | sed -nE 's/^Model name: +//p' | head -1)"
  kv "cpu threads" "$(nproc)"
  kv "ram total MiB" "$(awk '/^MemTotal:/ { printf "%d", $2 / 1024 }' /proc/meminfo)"
  kv "ram available MiB" "$(ram_avail_mib)"
  kv "gpu vendor" "$(gpu_vendor)"
  kv "docker" "$(docker_status)"
  kv "podman" "$(have podman && podman --version || echo 'not installed')"
  kv "user groups" "$(id -nG)"
  kv "python3" "$(have python3 && python3 --version 2>&1 || echo 'not installed')"
  kv "uv" "$(have uv && uv --version 2>&1 || echo 'not installed')"
  echo >>"$REPORT"

  echo "## GPU" >>"$REPORT"
  echo >>"$REPORT"
  if [ -n "$(amd_cards)" ]; then
    section "AMD memory counters (sysfs, bytes)" bash -c '
      for d in '"$(amd_cards | tr '\n' ' ')"'; do
        echo "$d"
        for f in mem_info_vram_total mem_info_vram_used mem_info_vis_vram_total mem_info_vis_vram_used mem_info_gtt_total mem_info_gtt_used; do
          [ -r "$d/$f" ] && printf "  %-24s %s\n" "$f" "$(cat "$d/$f")"
        done
      done'
    section "AMD memory mode" memory_mode_guess
    section "Kernel parameters (amdgpu / ttm)" bash -c '
      tr " " "\n" </proc/cmdline | grep -Ei "amdgpu|ttm|iommu" || echo "(none on cmdline)"
      for p in /sys/module/ttm/parameters/pages_limit /sys/module/ttm/parameters/page_pool_size /sys/module/amdgpu/parameters/gttsize; do
        [ -r "$p" ] && echo "$p = $(cat "$p")"
      done'
    section "ROCm version" bash -c 'cat /opt/rocm/.info/version 2>/dev/null || echo "no /opt/rocm/.info/version"'
    have rocminfo && section "rocminfo (agents)" bash -c 'rocminfo 2>/dev/null | grep -E "^ +(Name|Marketing Name|Compute Unit|Device Type):" | head -40'
    have amd-smi && section "amd-smi static" bash -c 'amd-smi static --asic --vram 2>/dev/null | head -60'
    have rocm-smi && section "rocm-smi" bash -c 'rocm-smi --showproductname --showmeminfo vram gtt 2>/dev/null | head -60'
  fi
  if have nvidia-smi; then
    section "nvidia-smi" bash -c 'nvidia-smi --query-gpu=name,memory.total,memory.used,driver_version,compute_cap --format=csv; nvidia-smi | head -5'
  fi
  [ "$(gpu_vendor)" = none ] && printf 'No AMD or NVIDIA GPU detected.\n\n' >>"$REPORT"

  echo "## Existing vLLM" >>"$REPORT"
  echo >>"$REPORT"
  if docker_ok; then
    section "Docker containers with vllm in image or command" vllm_containers
    local id
    for id in $(vllm_containers | cut -f1); do
      section "Container ${id:0:12}" describe_container "$id"
      section "vLLM version inside ${id:0:12}" \
        docker exec "$id" sh -c 'python3 -c "import vllm, torch; print(\"vllm\", vllm.__version__); print(\"torch\", torch.__version__, \"hip\", getattr(torch.version, \"hip\", None), \"cuda\", torch.version.cuda)" 2>/dev/null || python -c "import vllm; print(\"vllm\", vllm.__version__)"'
    done
    section "Docker images with vllm in name" bash -c 'docker images --format "{{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}" | grep -i vllm'
  fi
  section "vLLM processes" bash -c 'ps -eo pid,user,etime,args | grep -E "vllm (serve|.*api_server)|vllm\.entrypoints" | grep -v grep || echo "(none)"'
  section "systemd units mentioning vllm" bash -c '
    systemctl list-units --type=service --all --no-pager 2>/dev/null | grep -i vllm || echo "(no system units)"
    systemctl --user list-units --type=service --all --no-pager 2>/dev/null | grep -i vllm || echo "(no user units)"'
  local port
  for port in $(candidate_ports); do
    section "Endpoint probe on port ${port}" probe_endpoint "$port"
  done

  echo "## Hugging Face cache" >>"$REPORT"
  echo >>"$REPORT"
  section "Model directories" bash -c '
    hub="${HF_HOME:-$HOME/.cache/huggingface}/hub"
    echo "$hub"
    ls -1 "$hub" 2>/dev/null | grep "^models--" || echo "(none)"'

  echo "Facts written to $REPORT"
}

# ---------------------------------------------------------------- sleep test

SLEEP_IMAGE=""
SLEEP_MODEL="Qwen/Qwen3-0.6B"
SLEEP_PORT=18000
SLEEP_URL=""
SLEEP_EXTRA=""
SLEEP_GPU_UTIL="0.3"
SLEEP_TIMEOUT=1500
SLEEP_KEEP=0
SLEEP_LEGACY=0
CONTAINER_NAME="lmsy-probe-sleep"

sleep_usage() {
  cat <<'EOF'
probe.sh sleep [options]

Starts a small vLLM server with Sleep Mode enabled in Docker, then measures
memory and timing for sleep level 1, wake, sleep level 2, and wake with
weight reload. Checks that the model gives the same answer after each wake.

Options:
  --image IMAGE      vLLM image. Default: NVIDIA -> vllm/vllm-openai:latest;
                     AMD -> the image of a running vLLM container.
  --model MODEL      Model to load (default Qwen/Qwen3-0.6B, about 1.5 GB).
  --port PORT        Host port, bound to 127.0.0.1 only (default 18000).
  --gpu-util FRAC    --gpu-memory-utilization for the test server (default 0.3).
  --extra "ARGS"     Extra arguments for vllm serve, e.g. "--enforce-eager".
  --legacy-entrypoint  Start with python3 -m vllm.entrypoints.openai.api_server
                     instead of the vllm CLI.
  --url URL          Skip Docker and test a server that is already running.
                     It must have been started with --enable-sleep-mode and
                     VLLM_SERVER_DEV_MODE=1.
  --timeout SECONDS  How long to wait for the server to become healthy (default 1500).
  --keep             Leave the test container running afterwards.
EOF
}

# The user's working vLLM server container, if one is running: first a
# container whose command starts vLLM, else one whose image name has vllm in it
# (but not the Playground web UI).
source_container_id() {
  have docker || return 0
  local rows id
  rows="$(docker ps --no-trunc --format '{{.ID}}\t{{.Image}}\t{{.Names}}\t{{.Command}}' 2>/dev/null \
    | grep -v "$CONTAINER_NAME")"
  id="$(grep -E 'vllm serve|api_server|vllm\.entrypoints' <<<"$rows" | head -1 | cut -f1)"
  [ -n "$id" ] || id="$(awk -F'\t' 'tolower($2) ~ /vllm/ && tolower($2) !~ /playground/ { print $1; exit }' <<<"$rows")"
  echo "$id"
}

auto_image() {
  case "$(gpu_vendor)" in
    nvidia) echo "vllm/vllm-openai:latest" ;;
    amd)
      local src
      src="$(source_container_id)"
      [ -n "$src" ] || return 1
      docker inspect --format '{{.Config.Image}}' "$src" 2>/dev/null ;;
    *) return 1 ;;
  esac
}

# --enforce-eager is often required on consumer AMD GPUs; copy it when the
# user's working server uses it.
copied_serve_flags() {
  local src
  src="$(source_container_id)"
  [ -n "$src" ] || return 0
  docker inspect --format '{{json .Config.Cmd}} {{json .Config.Entrypoint}}' "$src" 2>/dev/null \
    | grep -q -- '--enforce-eager' && echo "--enforce-eager"
}

# Env vars worth copying from the user's working vLLM container (AMD tuning).
copied_env_args() {
  have docker || return 0
  local src
  src="$(source_container_id)"
  [ -n "$src" ] || return 0
  docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$src" 2>/dev/null \
    | grep -E '^(HSA_|HIP_|ROCR_|ROCM_|PYTORCH_|TORCH_|AMD_|MIOPEN_|TRITON_|VLLM_ROCM_|VLLM_USE_|VLLM_ATTENTION_|FLASH_ATTENTION)' \
    | grep -vE 'TOKEN|KEY|SECRET|PASSWORD' \
    | sed 's/^/-e\n/'
}

start_container() {
  docker_ok || die "docker: $(docker_status). Fix that, or use --url to test a server that is already running"
  [ -n "$SLEEP_IMAGE" ] || SLEEP_IMAGE="$(auto_image)" || true
  [ -n "$SLEEP_IMAGE" ] || die "could not pick an image automatically; pass --image"

  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

  local hf_host="${HF_HOME:-$HOME/.cache/huggingface}"
  mkdir -p "$hf_host"

  local -a args=(run -d --name "$CONTAINER_NAME" --ipc=host
    -p "127.0.0.1:${SLEEP_PORT}:8000"
    -e VLLM_SERVER_DEV_MODE=1 -e HF_HOME=/hf -v "${hf_host}:/hf")
  case "$(gpu_vendor)" in
    amd)
      args+=(--device /dev/kfd --device /dev/dri --group-add video
        --security-opt seccomp=unconfined --cap-add SYS_PTRACE)
      local line
      while IFS= read -r line; do [ -n "$line" ] && args+=("$line"); done < <(copied_env_args)
      if [ "$SLEEP_LEGACY" = 0 ] && [ -n "$(copied_serve_flags)" ] && [[ " $SLEEP_EXTRA " != *" --enforce-eager "* ]]; then
        SLEEP_EXTRA="$SLEEP_EXTRA --enforce-eager"
      fi
      ;;
    nvidia) args+=(--gpus all) ;;
  esac
  [ -n "${HF_TOKEN:-}" ] && args+=(-e HF_TOKEN)

  local -a serve
  # shellcheck disable=SC2206  # word splitting of --extra is intended
  local -a extra=($SLEEP_EXTRA)
  if [ "$SLEEP_LEGACY" = 1 ]; then
    args+=(--entrypoint python3 "$SLEEP_IMAGE" -m vllm.entrypoints.openai.api_server --model "$SLEEP_MODEL")
  else
    args+=(--entrypoint vllm "$SLEEP_IMAGE" serve "$SLEEP_MODEL")
  fi
  serve=(--host 0.0.0.0 --port 8000 --enable-sleep-mode
    --gpu-memory-utilization "$SLEEP_GPU_UTIL" --max-model-len 4096 "${extra[@]}")
  args+=("${serve[@]}")

  echo "Starting test server from image: $SLEEP_IMAGE"
  echo "docker ${args[*]}" | redact >>"$OUT_DIR/sleep-docker-command.txt"
  docker "${args[@]}" >/dev/null || die "docker run failed (command saved in $OUT_DIR/sleep-docker-command.txt)"
}

container_running() {
  [ "$(docker inspect --format '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" = "true" ]
}

wait_healthy() {
  local base="$1" start t
  start="$(now)"
  echo "Waiting for $base/health (up to ${SLEEP_TIMEOUT}s; the first run downloads the image and model)..."
  while :; do
    if [ "$(curl -s -o /dev/null -w '%{http_code}' -m 3 "$base/health")" = "200" ]; then
      echo "healthy after $(elapsed "$start" "$(now)") s"
      return 0
    fi
    if [ -z "$SLEEP_URL" ] && ! container_running; then
      echo "the test container exited"
      return 1
    fi
    t="$(elapsed "$start" "$(now)")"
    if awk -v t="$t" -v m="$SLEEP_TIMEOUT" 'BEGIN { exit !(t > m) }'; then
      echo "timed out"
      return 1
    fi
    sleep 3
  done
}

served_model() {
  curl -s -m 10 "$1/v1/models" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])' 2>/dev/null
}

# Greedy completion; prints the generated text on one line.
complete() {
  local base="$1" model="$2"
  curl -s -m 300 -H 'Content-Type: application/json' \
    -d "{\"model\": \"$model\", \"prompt\": \"The capital of France is\", \"max_tokens\": 8, \"temperature\": 0}" \
    "$base/v1/completions" \
    | python3 -c 'import json,sys
try:
    print(json.dumps(json.load(sys.stdin)["choices"][0]["text"]))
except Exception as e:
    print("ERROR: %s" % e)'
}

is_sleeping() {
  curl -s -m 10 "$1/is_sleeping" | tr -d '\n '
}

ROWS=()
add_row() {
  # step, http, seconds, snapshot
  local step="$1" code="$2" secs="$3" snap="$4"
  local g t r
  read -r g t r <<<"$snap"
  ROWS+=("| $step | $code | $secs | $g | $t | $r |")
}

timed_post() {
  # timed_post URL [BODY] -> prints "<code> <seconds>"
  local start code
  start="$(now)"
  code="$(http_code POST "$1" "${2:-}")"
  echo "$code $(elapsed "$start" "$(now)")"
}

freed_pct() {
  # freed_pct LOADED_SUM AFTER_SUM BASE_SUM
  awk -v l="$1" -v a="$2" -v b="$3" 'BEGIN {
    if (l == "" || a == "" || b == "" || l - b <= 0) { print "n/a"; exit }
    printf "%.0f%%", (l - a) * 100 / (l - b) }'
}

snap_sum() {
  # GPU + GTT used, for a snapshot "<gpu> <gtt> <ram>"; empty if unknown.
  local g t r
  read -r g t r <<<"$1"
  [ "$g" = "n/a" ] && { echo ""; return; }
  [ "$t" = "n/a" ] && t=0
  echo $((g + t))
}

cmd_sleep() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --image) SLEEP_IMAGE="$2"; shift 2 ;;
      --model) SLEEP_MODEL="$2"; shift 2 ;;
      --port) SLEEP_PORT="$2"; shift 2 ;;
      --gpu-util) SLEEP_GPU_UTIL="$2"; shift 2 ;;
      --extra) SLEEP_EXTRA="$2"; shift 2 ;;
      --legacy-entrypoint) SLEEP_LEGACY=1; shift ;;
      --url) SLEEP_URL="${2%/}"; shift 2 ;;
      --timeout) SLEEP_TIMEOUT="$2"; shift 2 ;;
      --keep) SLEEP_KEEP=1; shift ;;
      -h|--help) sleep_usage; exit 0 ;;
      *) die "unknown option: $1 (see probe.sh sleep --help)" ;;
    esac
  done
  have curl || die "curl is required"
  have python3 || die "python3 is required"

  mkdir -p "$OUT_DIR"
  REPORT="$OUT_DIR/sleep.md"
  : >"$REPORT"

  local base model snap_base snap_loaded snap code secs r
  snap_base="$(mem_snapshot)"

  if [ -n "$SLEEP_URL" ]; then
    base="$SLEEP_URL"
  else
    base="http://127.0.0.1:${SLEEP_PORT}"
    start_container
  fi

  if ! wait_healthy "$base"; then
    if [ -z "$SLEEP_URL" ]; then
      docker logs --tail 200 "$CONTAINER_NAME" 2>&1 | redact >"$OUT_DIR/sleep-container.log"
      [ "$SLEEP_KEEP" = 1 ] || docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
    fi
    {
      echo "# LM-Switchyard probe: sleep mode"
      echo
      if [ -n "$SLEEP_URL" ]; then
        echo "**Result: $SLEEP_URL/health never returned 200.**"
      else
        echo "**Result: the test server never became healthy.** See sleep-container.log and sleep-docker-command.txt."
      fi
    } >>"$REPORT"
    echo "Server did not start. Report: $REPORT"
    exit 1
  fi

  model="$(served_model "$base")"
  [ -n "$model" ] || model="$SLEEP_MODEL"
  sleep 5
  snap_loaded="$(mem_snapshot)"

  local text_ref text_l1 text_l2 sleeping_l1 sleeping_l2
  local start
  start="$(now)"
  text_ref="$(complete "$base" "$model")"
  add_row "baseline before start" "-" "-" "$snap_base"
  add_row "loaded + first completion" "200" "$(elapsed "$start" "$(now)")" "$snap_loaded"

  read -r code secs <<<"$(timed_post "$base/sleep?level=1")"
  sleep 3; snap="$(mem_snapshot)"; sleeping_l1="$(is_sleeping "$base")"
  local snap_s1="$snap"
  add_row "sleep level 1" "$code" "$secs" "$snap"
  local l1_code="$code"

  read -r code secs <<<"$(timed_post "$base/wake_up")"
  snap="$(mem_snapshot)"
  add_row "wake from level 1" "$code" "$secs" "$snap"
  local l1_wake_secs="$secs"
  text_l1="$(complete "$base" "$model")"

  read -r code secs <<<"$(timed_post "$base/sleep?level=2")"
  sleep 3; snap="$(mem_snapshot)"; sleeping_l2="$(is_sleeping "$base")"
  local snap_s2="$snap"
  add_row "sleep level 2" "$code" "$secs" "$snap"
  local l2_code="$code"

  local s2 c1 c2 c3 s1 s3
  read -r c1 s1 <<<"$(timed_post "$base/wake_up?tags=weights")"
  read -r c2 s2 <<<"$(timed_post "$base/collective_rpc" '{"method":"reload_weights"}')"
  read -r c3 s3 <<<"$(timed_post "$base/wake_up?tags=kv_cache")"
  snap="$(mem_snapshot)"
  local l2_wake_secs
  l2_wake_secs="$(awk -v a="$s1" -v b="$s2" -v c="$s3" 'BEGIN { printf "%.2f", a + b + c }')"
  add_row "wake from level 2 (weights $c1, reload $c2, kv_cache $c3)" "$c1/$c2/$c3" "$l2_wake_secs" "$snap"
  text_l2="$(complete "$base" "$model")"

  local loaded_sum base_sum s1_sum s2_sum
  loaded_sum="$(snap_sum "$snap_loaded")"; base_sum="$(snap_sum "$snap_base")"
  s1_sum="$(snap_sum "$snap_s1")"; s2_sum="$(snap_sum "$snap_s2")"

  {
    echo "# LM-Switchyard probe: sleep mode"
    echo
    echo "- **probe version**: $PROBE_VERSION"
    echo "- **date**: $(date -Iseconds)"
    echo "- **host**: $HOST_NAME ($(gpu_vendor)$(is_wsl && echo ', WSL2'))"
    echo "- **server**: ${SLEEP_URL:-docker image $SLEEP_IMAGE}"
    echo "- **model**: $model"
    echo "- **extra serve args**: ${SLEEP_EXTRA:-none}"
    echo "- **vLLM version**: $(curl -s -m 5 "$base/version" | tr -d '\n')"
    echo
    echo "## Measurements"
    echo
    echo "Memory in MiB. GPU = VRAM used (NVIDIA: nvidia-smi). GTT = AMD GTT used. RAM = MemAvailable."
    echo
    echo "| step | HTTP | seconds | GPU used | GTT used | RAM available |"
    echo "|---|---|---|---|---|---|"
    for r in "${ROWS[@]}"; do echo "$r"; done
    echo
    echo "## Results"
    echo
    echo "- **reference completion**: $text_ref"
    echo "- **level 1**: sleep HTTP $l1_code, is_sleeping=$sleeping_l1, GPU+GTT freed $(freed_pct "$loaded_sum" "$s1_sum" "$base_sum") of the server's footprint, wake ${l1_wake_secs}s, completion after wake: $text_l1 ($( [ "$text_l1" = "$text_ref" ] && echo match || echo DIFFERENT))"
    echo "- **level 2**: sleep HTTP $l2_code, is_sleeping=$sleeping_l2, GPU+GTT freed $(freed_pct "$loaded_sum" "$s2_sum" "$base_sum") of the server's footprint, wake ${l2_wake_secs}s, completion after wake: $text_l2 ($( [ "$text_l2" = "$text_ref" ] && echo match || echo DIFFERENT))"
    echo
    echo "A level works when sleep returns 200, is_sleeping is true, most of the footprint is freed, and the completion after wake matches."
  } >>"$REPORT"

  if [ -z "$SLEEP_URL" ]; then
    docker logs --tail 300 "$CONTAINER_NAME" 2>&1 | redact >"$OUT_DIR/sleep-container.log"
    if [ "$SLEEP_KEEP" = 1 ]; then
      echo "Test container left running: $CONTAINER_NAME"
    else
      docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
    fi
  fi
  echo "Sleep test written to $REPORT"
}

# ---------------------------------------------------------------- main

usage() {
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  facts) shift; cmd_facts "$@" ;;
  sleep) shift; cmd_sleep "$@" ;;
  -h|--help|"") usage ;;
  *) die "unknown command: $1" ;;
esac
