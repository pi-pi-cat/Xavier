#!/usr/bin/env bash

# Shared helpers for the AWS route node scripts. The callers enable strict mode.

export AWS_PAGER=""
export AWS_CLI_AUTO_PROMPT=off

AWS_BIN="${AWS_BIN:-aws}"
LOG_PREFIX="${LOG_PREFIX:-aws-route}"
INTERACTIVE="${INTERACTIVE:-auto}"
AUTO_APPROVE="${AUTO_APPROVE:-0}"
NO_COLOR="${NO_COLOR:-0}"

STEP_CURRENT=0
STEP_TOTAL=0
AWS_ROUTE_LOCK_DIR=""
AWS_ROUTE_TEMP_FILES=()
AWS_ROUTE_WORK_DIR="${TMPDIR:-/tmp}/aws-route-work-$$"

if [ -t 1 ] && [ "$NO_COLOR" != "1" ]; then
  COLOR_BLUE='\033[34m'
  COLOR_GREEN='\033[32m'
  COLOR_YELLOW='\033[33m'
  COLOR_RED='\033[31m'
  COLOR_RESET='\033[0m'
else
  COLOR_BLUE=''
  COLOR_GREEN=''
  COLOR_YELLOW=''
  COLOR_RED=''
  COLOR_RESET=''
fi

log() {
  printf '[%s] %s\n' "$LOG_PREFIX" "$*"
}

detail() {
  printf '  %s\n' "$*"
}

warn() {
  printf '%b[%s] WARNING: %s%b\n' "$COLOR_YELLOW" "$LOG_PREFIX" "$*" "$COLOR_RESET" >&2
}

die() {
  printf '%b[%s] ERROR: %s%b\n' "$COLOR_RED" "$LOG_PREFIX" "$*" "$COLOR_RESET" >&2
  exit 1
}

aws_route_unexpected_error() {
  local exit_code="$1"
  local line_number="$2"
  local command="$3"

  if [ "${AWS_ROUTE_ERROR_REPORTED:-0}" = "1" ]; then
    return 0
  fi
  AWS_ROUTE_ERROR_REPORTED=1
  printf '%b[%s] ERROR: unexpected exit %s at line %s: %s%b\n' \
    "$COLOR_RED" "$LOG_PREFIX" "$exit_code" "$line_number" "$command" "$COLOR_RESET" >&2
}

trap 'aws_route_unexpected_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

is_none() {
  case "${1:-}" in
    ""|None|null) return 0 ;;
    *) return 1 ;;
  esac
}

is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

is_interactive() {
  [ "$INTERACTIVE" != "0" ] && [ "$INTERACTIVE" != "false" ] && [ -t 0 ] && [ -t 1 ]
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is not installed or is not in PATH"
}

require_aws() {
  if [ "$AWS_BIN" = "aws" ]; then
    require_command aws
  elif [ ! -x "$AWS_BIN" ]; then
    die "AWS_BIN is not executable: $AWS_BIN"
  fi
}

validate_positive_integer() {
  local value="$1"
  local label="$2"
  case "$value" in
    ''|*[!0-9]*) die "$label must be a positive integer" ;;
  esac
  [ "$value" -gt 0 ] || die "$label must be greater than zero"
}

is_aws_authentication_error() {
  local error_file="$1"
  grep -Eqi \
    'CreateOAuth2Token|authorization grant is invalid|INVALID_REQUEST|ExpiredToken|ExpiredTokenException|InvalidClientTokenId|UnrecognizedClientException|SSO session.*expired|token has expired|refresh failed|Unable to locate credentials' \
    "$error_file"
}

can_run_aws_login_interactively() {
  [ "$INTERACTIVE" != "0" ] && [ "$INTERACTIVE" != "false" ] && \
    [ -r /dev/tty ] && [ -w /dev/tty ]
}

aws_at() {
  local profile="$1"
  local region="$2"
  local stdout_file stderr_file exit_code retry_exit_code
  shift 2

  mkdir -p "$AWS_ROUTE_WORK_DIR"
  stdout_file="$(mktemp "$AWS_ROUTE_WORK_DIR/aws-stdout.XXXXXX")"
  stderr_file="$(mktemp "$AWS_ROUTE_WORK_DIR/aws-stderr.XXXXXX")"

  if "$AWS_BIN" --profile "$profile" --region "$region" "$@" >"$stdout_file" 2>"$stderr_file"; then
    cat "$stdout_file"
    cat "$stderr_file" >&2
    rm -f "$stdout_file" "$stderr_file"
    return 0
  else
    exit_code=$?
  fi

  if ! is_aws_authentication_error "$stderr_file"; then
    cat "$stdout_file"
    cat "$stderr_file" >&2
    rm -f "$stdout_file" "$stderr_file"
    return "$exit_code"
  fi

  warn "AWS authentication failed for profile $profile"
  printf '  Run: aws login --profile %s\n' "$profile" >&2

  if ! can_run_aws_login_interactively; then
    cat "$stderr_file" >&2
    warn "no interactive terminal is available; run the command above and retry"
    rm -f "$stdout_file" "$stderr_file"
    return "$exit_code"
  fi

  printf '  Opening AWS login now; complete authorization in the browser...\n' >&2
  if "$AWS_BIN" login --profile "$profile" </dev/tty >/dev/tty 2>/dev/tty; then
    printf '  AWS login completed; retrying the interrupted command...\n' >&2
  else
    retry_exit_code=$?
    warn "AWS login did not complete successfully for profile $profile"
    rm -f "$stdout_file" "$stderr_file"
    return "$retry_exit_code"
  fi

  : >"$stdout_file"
  : >"$stderr_file"
  if "$AWS_BIN" --profile "$profile" --region "$region" "$@" >"$stdout_file" 2>"$stderr_file"; then
    cat "$stdout_file"
    cat "$stderr_file" >&2
    rm -f "$stdout_file" "$stderr_file"
    return 0
  else
    retry_exit_code=$?
  fi

  cat "$stdout_file"
  cat "$stderr_file" >&2
  warn "AWS command still failed after login; not retrying again"
  rm -f "$stdout_file" "$stderr_file"
  return "$retry_exit_code"
}

set_step_total() {
  STEP_CURRENT=0
  STEP_TOTAL="$1"
}

step() {
  STEP_CURRENT=$((STEP_CURRENT + 1))
  printf '\n%b[%d/%d] %s%b\n' "$COLOR_BLUE" "$STEP_CURRENT" "$STEP_TOTAL" "$*" "$COLOR_RESET"
}

register_temp_file() {
  AWS_ROUTE_TEMP_FILES+=("$1")
}

new_temp_file() {
  local template="${1:-aws-route.XXXXXX}"
  local path
  mkdir -p "$AWS_ROUTE_WORK_DIR"
  path="$(mktemp "$AWS_ROUTE_WORK_DIR/$template")"
  register_temp_file "$path"
  printf '%s\n' "$path"
}

aws_route_cleanup() {
  local path
  for path in "${AWS_ROUTE_TEMP_FILES[@]-}"; do
    [ -n "$path" ] && rm -f "$path"
  done
  if [ -d "$AWS_ROUTE_WORK_DIR" ]; then
    for path in "$AWS_ROUTE_WORK_DIR"/*; do
      [ -e "$path" ] && rm -f "$path"
    done
    rmdir "$AWS_ROUTE_WORK_DIR" 2>/dev/null || true
  fi
  if [ -n "$AWS_ROUTE_LOCK_DIR" ]; then
    rmdir "$AWS_ROUTE_LOCK_DIR" 2>/dev/null || true
  fi
}

trap aws_route_cleanup EXIT

acquire_lock() {
  local key safe_key
  key="$1"
  safe_key="$(printf '%s' "$key" | tr -c '[:alnum:]._- ' '-' | tr ' ' '-')"
  AWS_ROUTE_LOCK_DIR="${TMPDIR:-/tmp}/${safe_key}.lock"
  if ! mkdir "$AWS_ROUTE_LOCK_DIR" 2>/dev/null; then
    die "another operation appears to be running (lock: $AWS_ROUTE_LOCK_DIR)"
  fi
}

run_with_progress() {
  local label="$1"
  shift
  local output_file pid rc elapsed spinner_index spinner

  output_file="$(new_temp_file aws-route-progress.XXXXXX)"
  "$@" >"$output_file" 2>&1 &
  pid=$!
  elapsed=0
  spinner_index=0
  spinner='|/-\'

  if [ -t 1 ]; then
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r  %s %s (%ds)' "${spinner:$spinner_index:1}" "$label" "$elapsed"
      spinner_index=$(((spinner_index + 1) % 4))
      sleep 1
      elapsed=$((elapsed + 1))
    done
  fi

  if wait "$pid"; then
    rc=0
  else
    rc=$?
  fi

  if [ -t 1 ] && [ "$rc" -eq 0 ]; then
    printf '\r  %bOK%b %s (%ds)%*s\n' "$COLOR_GREEN" "$COLOR_RESET" "$label" "$elapsed" 8 ''
  elif [ -t 1 ]; then
    printf '\r  %bFAIL%b %s (%ds)%*s\n' "$COLOR_RED" "$COLOR_RESET" "$label" "$elapsed" 8 ''
  elif [ "$rc" -eq 0 ]; then
    detail "OK: $label"
  fi

  if [ "$rc" -ne 0 ]; then
    if [ -s "$output_file" ]; then
      sed 's/^/  /' "$output_file" >&2
    fi
    return "$rc"
  fi
}

prompt_with_default() {
  local prompt="$1"
  local default_value="$2"
  local answer

  if ! is_interactive; then
    printf '%s\n' "$default_value"
    return 0
  fi

  printf '%s [%s]: ' "$prompt" "$default_value" >&2
  IFS= read -r answer || true
  printf '%s\n' "${answer:-$default_value}"
}

confirm_action() {
  local prompt="$1"
  local default_answer="${2:-no}"
  local answer suffix

  is_true "$AUTO_APPROVE" && return 0
  if ! is_interactive; then
    [ "$default_answer" = "yes" ]
    return
  fi

  if [ "$default_answer" = "yes" ]; then
    suffix='[Y/n]'
  else
    suffix='[y/N]'
  fi

  printf '%s %s ' "$prompt" "$suffix" >&2
  IFS= read -r answer || true
  if [ -z "$answer" ]; then
    [ "$default_answer" = "yes" ]
    return
  fi
  is_true "$answer"
}

word_count() {
  printf '%s\n' "${1:-}" | awk '{for (i=1; i<=NF; i++) count++} END {print count+0}'
}

short_error() {
  printf '%s' "$1" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g' | cut -c1-280
}

make_client_token() {
  local seed checksum
  seed="$1"
  checksum="$(printf '%s' "$seed" | cksum | awk '{print $1}')"
  printf 'aws-route-%s-%s-%s\n' "$(date +%s)" "$$" "$checksum"
}

is_capacity_error() {
  case "$1" in
    *InsufficientInstanceCapacity*|*InsufficientHostCapacity*|*InsufficientReservedInstanceCapacity*|*UnsupportedOperation*capacity*) return 0 ;;
    *) return 1 ;;
  esac
}

is_volume_error() {
  case "$1" in
    *VolumeType*|*volume\ type*|*InvalidVolume*|*Unsupported*volume*|*not\ supported*gp2*|*not\ supported*gp3*) return 0 ;;
    *) return 1 ;;
  esac
}

is_retryable_aws_error() {
  case "$1" in
    *RequestLimitExceeded*|*Throttl*|*InternalError*|*ServiceUnavailable*|*RequestTimeout*|*ConnectionReset*|*connection\ reset*|*Could\ not\ connect\ to\ the\ endpoint*|*timed\ out*) return 0 ;;
    *) return 1 ;;
  esac
}

validate_cidr() {
  awk -v cidr="$1" '
    BEGIN {
      n = split(cidr, parts, "/")
      if (n != 2 || parts[2] !~ /^[0-9]+$/ || parts[2] < 0 || parts[2] > 32) exit 1
      m = split(parts[1], octets, ".")
      if (m != 4) exit 1
      for (i = 1; i <= 4; i++) {
        if (octets[i] !~ /^[0-9]+$/ || octets[i] < 0 || octets[i] > 255) exit 1
      }
    }
  '
}

cidrs_overlap() {
  awk -v left="$1" -v right="$2" '
    function bounds(cidr, out, p, o, ip, size) {
      split(cidr, p, "/")
      split(p[1], o, ".")
      ip = ((o[1] * 256 + o[2]) * 256 + o[3]) * 256 + o[4]
      size = 2 ^ (32 - p[2])
      out[1] = int(ip / size) * size
      out[2] = out[1] + size - 1
    }
    BEGIN {
      bounds(left, a)
      bounds(right, b)
      exit !((a[1] <= b[2]) && (b[1] <= a[2]))
    }
  '
}

cidr_contains() {
  awk -v parent="$1" -v child="$2" '
    function bounds(cidr, out, p, o, ip, size) {
      split(cidr, p, "/")
      split(p[1], o, ".")
      ip = ((o[1] * 256 + o[2]) * 256 + o[3]) * 256 + o[4]
      size = 2 ^ (32 - p[2])
      out[1] = int(ip / size) * size
      out[2] = out[1] + size - 1
    }
    BEGIN {
      bounds(parent, a)
      bounds(child, b)
      exit !(a[1] <= b[1] && a[2] >= b[2])
    }
  '
}

choose_free_vpc_cidr() {
  local used_cidrs="$1"
  local second candidate used collision

  second=20
  while [ "$second" -le 250 ]; do
    candidate="10.${second}.0.0/16"
    collision=0
    for used in $used_cidrs; do
      if validate_cidr "$used" && cidrs_overlap "$candidate" "$used"; then
        collision=1
        break
      fi
    done
    if [ "$collision" -eq 0 ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    second=$((second + 1))
  done
  return 1
}

default_subnet_for_vpc_cidr() {
  local vpc_cidr="$1"
  local base prefix first second
  base="${vpc_cidr%/*}"
  prefix="${vpc_cidr#*/}"
  first="$(printf '%s' "$base" | cut -d. -f1)"
  second="$(printf '%s' "$base" | cut -d. -f2)"

  if [ "$prefix" -le 16 ]; then
    printf '%s.%s.1.0/24\n' "$first" "$second"
  else
    return 1
  fi
}

choose_free_subnet_cidr() {
  local vpc_cidr="$1"
  local used_cidrs="$2"
  local base prefix first second third candidate used collision

  base="${vpc_cidr%/*}"
  prefix="${vpc_cidr#*/}"
  [ "$prefix" -le 16 ] || return 1
  first="$(printf '%s' "$base" | cut -d. -f1)"
  second="$(printf '%s' "$base" | cut -d. -f2)"

  third=1
  while [ "$third" -le 254 ]; do
    candidate="${first}.${second}.${third}.0/24"
    cidr_contains "$vpc_cidr" "$candidate" || {
      third=$((third + 1))
      continue
    }
    collision=0
    for used in $used_cidrs; do
      if validate_cidr "$used" && cidrs_overlap "$candidate" "$used"; then
        collision=1
        break
      fi
    done
    if [ "$collision" -eq 0 ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    third=$((third + 1))
  done
  return 1
}

resolve_debian_ami() {
  local profile="$1"
  local region="$2"
  local release="$3"
  local owner_id="$4"
  local architecture="$5"
  local image_arch

  case "$architecture" in
    x86_64) image_arch="amd64" ;;
    arm64) image_arch="arm64" ;;
    *) die "unsupported Debian AMI architecture: $architecture" ;;
  esac

  AMI_ID="$(aws_at "$profile" "$region" ec2 describe-images \
    --owners "$owner_id" \
    --filters \
      "Name=name,Values=debian-${release}-${image_arch}-*" \
      "Name=architecture,Values=$architecture" \
      Name=root-device-type,Values=ebs \
      Name=virtualization-type,Values=hvm \
      Name=state,Values=available \
    --query 'sort_by(Images,&CreationDate)[-1].ImageId' \
    --output text)"
  is_none "$AMI_ID" && die "no official Debian $release $architecture AMI was found in $region"

  AMI_NAME="$(aws_at "$profile" "$region" ec2 describe-images \
    --image-ids "$AMI_ID" \
    --query 'Images[0].Name' \
    --output text)"
  ROOT_DEVICE_NAME="$(aws_at "$profile" "$region" ec2 describe-images \
    --image-ids "$AMI_ID" \
    --query 'Images[0].RootDeviceName' \
    --output text)"
  ROOT_VOLUME_SIZE="$(aws_at "$profile" "$region" ec2 describe-images \
    --image-ids "$AMI_ID" \
    --query "Images[0].BlockDeviceMappings[?DeviceName=='$ROOT_DEVICE_NAME'].Ebs.VolumeSize | [0]" \
    --output text)"
  if is_none "$ROOT_VOLUME_SIZE"; then
    ROOT_VOLUME_SIZE=8
  fi
}

load_instance_candidates() {
  local profile="$1"
  local region="$2"
  local az="$3"
  local architecture="$4"
  local min_vcpus="$5"
  local min_memory_mib="$6"
  local output_file="$7"
  local offered_types batch batch_count instance_type raw_file

  offered_types="$(aws_at "$profile" "$region" ec2 describe-instance-type-offerings \
    --location-type availability-zone \
    --filters "Name=location,Values=$az" \
    --query 'InstanceTypeOfferings[].InstanceType' \
    --output text)"
  [ -n "$offered_types" ] || die "no EC2 instance types are currently offered in $az"

  raw_file="$(new_temp_file aws-route-instance-specs.XXXXXX)"
  : >"$raw_file"
  batch=""
  batch_count=0

  for instance_type in $offered_types; do
    batch="$batch $instance_type"
    batch_count=$((batch_count + 1))
    if [ "$batch_count" -eq 100 ]; then
      # Instance type names contain no whitespace; intentional splitting keeps calls below API limits.
      aws_at "$profile" "$region" ec2 describe-instance-types \
        --instance-types $batch \
        --query "InstanceTypes[?VCpuInfo.DefaultVCpus >= \`$min_vcpus\` && MemoryInfo.SizeInMiB >= \`$min_memory_mib\` && contains(ProcessorInfo.SupportedArchitectures, '$architecture')].[InstanceType,VCpuInfo.DefaultVCpus,MemoryInfo.SizeInMiB]" \
        --output text >>"$raw_file"
      batch=""
      batch_count=0
    fi
  done

  if [ "$batch_count" -gt 0 ]; then
    aws_at "$profile" "$region" ec2 describe-instance-types \
      --instance-types $batch \
      --query "InstanceTypes[?VCpuInfo.DefaultVCpus >= \`$min_vcpus\` && MemoryInfo.SizeInMiB >= \`$min_memory_mib\` && contains(ProcessorInfo.SupportedArchitectures, '$architecture')].[InstanceType,VCpuInfo.DefaultVCpus,MemoryInfo.SizeInMiB]" \
      --output text >>"$raw_file"
  fi

  awk '
    NF >= 3 {
      type=$1; vcpu=$2; memory=$3; rank=8
      if (type ~ /^t[0-9]/) rank=1
      else if (type ~ /^c[0-9]/) rank=2
      else if (type ~ /^m[0-9]/) rank=3
      else if (type ~ /^a[0-9]/) rank=4
      else if (type ~ /^r[0-9]/) rank=5
      else if (type ~ /^i[0-9]/ || type ~ /^d[0-9]/) rank=7
      else if (type ~ /^mac/ || type ~ /\.metal$/ || type ~ /^g[0-9]/ || type ~ /^p[0-9]/ || type ~ /^f[0-9]/ || type ~ /^inf/ || type ~ /^trn/) rank=9
      print vcpu, rank, memory, type
    }
  ' "$raw_file" | sort -k1,1n -k2,2n -k3,3n -k4,4 | awk '{print $4 "\t" $1 "\t" $3}' >"$output_file"

  [ -s "$output_file" ] || die "no $architecture instance type in $az satisfies ${min_vcpus} vCPU and ${min_memory_mib} MiB memory"
}

print_instance_candidates() {
  local file="$1"
  local limit="${2:-5}"
  local index=0 type vcpus memory

  while IFS=$'\t' read -r type vcpus memory; do
    index=$((index + 1))
    detail "${index}. ${type} (${vcpus} vCPU, ${memory} MiB)"
    if [ "$index" -ge "$limit" ]; then
      break
    fi
  done <"$file"
  return 0
}

instance_candidate_names() {
  local file="$1"
  local limit="${2:-10}"
  awk -v limit="$limit" 'NR <= limit {print $1}' "$file"
}

ensure_key_pair_for_region() {
  local profile="$1"
  local region="$2"
  local key_name="$3"
  local pem_path="$4"
  local pub_path local_public remote_count remote_public

  require_command ssh-keygen
  mkdir -p "$(dirname "$pem_path")"
  if [ ! -f "$pem_path" ]; then
    log "local private key not found; creating $pem_path"
    umask 077
    ssh-keygen -q -t ed25519 -f "$pem_path" -N "" -C "$key_name"
  fi
  chmod 600 "$pem_path"

  pub_path="${pem_path}.pub"
  ssh-keygen -y -f "$pem_path" >"$pub_path"
  local_public="$(awk '{print $1 " " $2}' "$pub_path")"

  remote_count="$(aws_at "$profile" "$region" ec2 describe-key-pairs \
    --filters "Name=key-name,Values=$key_name" \
    --query 'length(KeyPairs)' \
    --output text)"

  if [ "$remote_count" = "0" ]; then
    log "importing key pair $key_name into $region"
    aws_at "$profile" "$region" ec2 import-key-pair \
      --key-name "$key_name" \
      --public-key-material "fileb://$pub_path" >/dev/null
  else
    remote_public="$(aws_at "$profile" "$region" ec2 describe-key-pairs \
      --key-names "$key_name" \
      --include-public-key \
      --query 'KeyPairs[0].PublicKey' \
      --output text)"
    remote_public="$(printf '%s\n' "$remote_public" | awk '{print $1 " " $2}')"
    if ! is_none "$remote_public" && [ "$local_public" != "$remote_public" ]; then
      local active_instance_ids verified_public
      active_instance_ids="$(aws_at "$profile" "$region" ec2 describe-instances \
        --filters \
          "Name=key-name,Values=$key_name" \
          'Name=instance-state-name,Values=pending,running,stopping,stopped' \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text)"
      if ! is_none "$active_instance_ids"; then
        die "refusing to replace AWS key pair $key_name: active instance(s) still reference it: $active_instance_ids"
      fi

      warn "AWS key pair $key_name does not match $pem_path; replacing its public key in $region"
      aws_at "$profile" "$region" ec2 delete-key-pair --key-name "$key_name" >/dev/null
      aws_at "$profile" "$region" ec2 import-key-pair \
        --key-name "$key_name" \
        --public-key-material "fileb://$pub_path" >/dev/null

      verified_public="$(aws_at "$profile" "$region" ec2 describe-key-pairs \
        --key-names "$key_name" \
        --include-public-key \
        --query 'KeyPairs[0].PublicKey' \
        --output text)"
      verified_public="$(printf '%s\n' "$verified_public" | awk '{print $1 " " $2}')"
      [ "$local_public" = "$verified_public" ] ||
        die "AWS key pair $key_name still does not match $pem_path after replacement"
      log "key pair replaced and verified: $key_name in $region"
    else
      log "key pair: reusing $key_name in $region"
    fi
  fi
}
