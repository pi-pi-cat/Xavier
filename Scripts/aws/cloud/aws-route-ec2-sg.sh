#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_PREFIX="aws-route-sg"
# shellcheck source=aws-route-common.sh
source "$SCRIPT_DIR/aws-route-common.sh"

ACTION="help"
POSITIONAL=()
for argument in "$@"; do
  case "$argument" in
    create|status|delete|help|-h|--help) ACTION="$argument" ;;
    -y|--yes) AUTO_APPROVE=1 ;;
    --non-interactive) INTERACTIVE=0 ;;
    -*) die "unknown option: $argument" ;;
    *) POSITIONAL+=("$argument") ;;
  esac
done
[ "${#POSITIONAL[@]}" -eq 0 ] || die "unexpected argument(s): ${POSITIONAL[*]}"

AWS_PROFILE="${AWS_PROFILE:-personal}"
REGION="${REGION:-ap-southeast-1}"
AZ="${AZ:-ap-southeast-1a}"

INSTANCE_NAME="${INSTANCE_NAME:-ec2-sg-route}"
INSTANCE_TYPE_REQUEST="${INSTANCE_TYPE:-auto}"
INSTANCE_TYPE="$INSTANCE_TYPE_REQUEST"
MIN_VCPUS="${MIN_VCPUS:-1}"
MIN_MEMORY_MIB="${MIN_MEMORY_MIB:-512}"
ROOT_VOLUME_TYPE_REQUEST="${ROOT_VOLUME_TYPE:-auto}"
ROOT_VOLUME_TYPE="$ROOT_VOLUME_TYPE_REQUEST"
ROOT_VOLUME_SIZE_OVERRIDE="${ROOT_VOLUME_SIZE_GIB:-}"

SECURITY_GROUP_NAME="${SECURITY_GROUP_NAME:-aws-route-sg}"
KEY_NAME="${KEY_NAME:-aws-route}"
INGRESS_CIDR="${INGRESS_CIDR:-0.0.0.0/0}"

DEBIAN_RELEASE="${DEBIAN_RELEASE:-13}"
DEBIAN_OWNER_ID="${DEBIAN_OWNER_ID:-136693071363}"
ARCHITECTURE="${ARCHITECTURE:-x86_64}"

PROJECT_TAG="${PROJECT_TAG:-aws-route}"
ROLE_TAG="${ROLE_TAG:-sg-transit}"
MANAGED_BY="${MANAGED_BY:-aws-route-script}"

if [ -z "${PEM_PATH:-}" ]; then
  if [ -f "$HOME/.ssh/aws-route.pem" ]; then
    PEM_PATH="$HOME/.ssh/aws-route.pem"
  elif [ -f "$HOME/Downloads/aws-route.pem" ]; then
    PEM_PATH="$HOME/Downloads/aws-route.pem"
  else
    PEM_PATH="$HOME/.ssh/aws-route.pem"
  fi
fi

INSTANCE_TYPE_AUTO=0
VOLUME_TYPE_AUTO=0
INSTANCE_TYPE_CANDIDATES=""
VOLUME_TYPE_CANDIDATES=""

aws_region() {
  aws_at "$AWS_PROFILE" "$REGION" "$@"
}

validate_positive_integer() {
  local value="$1"
  local label="$2"
  case "$value" in
    ''|*[!0-9]*) die "$label must be a positive integer" ;;
  esac
  [ "$value" -gt 0 ] || die "$label must be greater than zero"
}

verify_identity() {
  local account arn
  account="$(aws_region sts get-caller-identity --query Account --output text)" || \
    die "AWS login failed for profile $AWS_PROFILE"
  arn="$(aws_region sts get-caller-identity --query Arn --output text)"
  detail "AWS account: $account"
  detail "Identity: $arn"
}

wait_for_lightsail_peering() {
  local peered attempt=0
  while [ "$attempt" -lt 40 ]; do
    peered="$(aws_region lightsail is-vpc-peered --query isPeered --output text)"
    peered="$(printf '%s' "$peered" | tr '[:upper:]' '[:lower:]')"
    [ "$peered" = "true" ] && return 0
    sleep 3
    attempt=$((attempt + 1))
  done
  return 1
}

ensure_lightsail_peering() {
  local peered
  peered="$(aws_region lightsail is-vpc-peered --query isPeered --output text)"
  peered="$(printf '%s' "$peered" | tr '[:upper:]' '[:lower:]')"

  if [ "$peered" != "true" ]; then
    log "enabling Lightsail VPC peering in $REGION"
    aws_region lightsail peer-vpc >/dev/null
    run_with_progress "waiting for Lightsail VPC peering" wait_for_lightsail_peering || \
      die "Lightsail VPC peering did not become ready"
  else
    detail "Lightsail VPC peering is enabled"
  fi
}

find_instance_ids() {
  aws_region ec2 describe-instances \
    --filters \
      "Name=tag:Name,Values=$INSTANCE_NAME" \
      "Name=tag:Role,Values=$ROLE_TAG" \
      "Name=tag:ManagedBy,Values=$MANAGED_BY" \
      Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text
}

get_single_instance_id() {
  local ids count
  ids="$(find_instance_ids)"
  count="$(word_count "$ids")"
  [ "$count" -le 1 ] || die "found $count managed instances named $INSTANCE_NAME: $ids"
  [ "$count" = "1" ] && printf '%s\n' "$ids" | awk '{print $1}'
  return 0
}

resolve_network() {
  local existing_instance fallback_subnet

  VPC_ID="$(aws_region ec2 describe-vpcs \
    --filters Name=is-default,Values=true \
    --query 'Vpcs[0].VpcId' \
    --output text)"
  is_none "$VPC_ID" && die "no default VPC was found in $REGION; Lightsail peering uses the default VPC"

  existing_instance="$(get_single_instance_id)"
  if [ -n "$existing_instance" ]; then
    SUBNET_ID="$(aws_region ec2 describe-instances \
      --instance-ids "$existing_instance" \
      --query 'Reservations[0].Instances[0].SubnetId' \
      --output text)"
    AZ="$(aws_region ec2 describe-instances \
      --instance-ids "$existing_instance" \
      --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' \
      --output text)"
  else
    SUBNET_ID="$(aws_region ec2 describe-subnets \
      --filters \
        "Name=vpc-id,Values=$VPC_ID" \
        "Name=availability-zone,Values=$AZ" \
        Name=default-for-az,Values=true \
        Name=state,Values=available \
      --query 'Subnets[0].SubnetId' \
      --output text)"

    if is_none "$SUBNET_ID"; then
      fallback_subnet="$(aws_region ec2 describe-subnets \
        --filters \
          "Name=vpc-id,Values=$VPC_ID" \
          Name=default-for-az,Values=true \
          Name=state,Values=available \
        --query 'reverse(sort_by(Subnets,&AvailableIpAddressCount))[0].SubnetId' \
        --output text)"
      is_none "$fallback_subnet" && die "no available default subnet was found in $REGION"
      SUBNET_ID="$fallback_subnet"
      AZ="$(aws_region ec2 describe-subnets \
        --subnet-ids "$SUBNET_ID" \
        --query 'Subnets[0].AvailabilityZone' \
        --output text)"
      warn "requested AZ has no available default subnet; using $AZ"
    fi
  fi

  VPC_CIDR="$(aws_region ec2 describe-vpcs \
    --vpc-ids "$VPC_ID" \
    --query 'Vpcs[0].CidrBlock' \
    --output text)"
  detail "VPC: $VPC_ID ($VPC_CIDR)"
  detail "Subnet: $SUBNET_ID ($AZ)"
}

resolve_image_and_launch_candidates() {
  local existing_instance existing_type existing_volume root_volume_id candidate_file requested_line

  resolve_debian_ami "$AWS_PROFILE" "$REGION" "$DEBIAN_RELEASE" "$DEBIAN_OWNER_ID" "$ARCHITECTURE"
  [ -z "$ROOT_VOLUME_SIZE_OVERRIDE" ] || ROOT_VOLUME_SIZE="$ROOT_VOLUME_SIZE_OVERRIDE"
  validate_positive_integer "$ROOT_VOLUME_SIZE" "ROOT_VOLUME_SIZE_GIB"

  existing_instance="$(get_single_instance_id)"
  if [ -n "$existing_instance" ]; then
    existing_type="$(aws_region ec2 describe-instances \
      --instance-ids "$existing_instance" \
      --query 'Reservations[0].Instances[0].InstanceType' \
      --output text)"
    if [ "$INSTANCE_TYPE_REQUEST" != "auto" ] && [ "$INSTANCE_TYPE_REQUEST" != "$existing_type" ]; then
      die "existing instance uses $existing_type, requested $INSTANCE_TYPE_REQUEST"
    fi
    INSTANCE_TYPE="$existing_type"
    INSTANCE_TYPE_CANDIDATES="$existing_type"

    root_volume_id="$(aws_region ec2 describe-instances \
      --instance-ids "$existing_instance" \
      --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
      --output text)"
    if ! is_none "$root_volume_id"; then
      existing_volume="$(aws_region ec2 describe-volumes \
        --volume-ids "$root_volume_id" \
        --query 'Volumes[0].VolumeType' \
        --output text)"
      ROOT_VOLUME_TYPE="$existing_volume"
      VOLUME_TYPE_CANDIDATES="$existing_volume"
    fi
    return 0
  fi

  candidate_file="$(new_temp_file aws-route-sg-types.XXXXXX)"
  load_instance_candidates "$AWS_PROFILE" "$REGION" "$AZ" "$ARCHITECTURE" \
    "$MIN_VCPUS" "$MIN_MEMORY_MIB" "$candidate_file"

  if [ "$INSTANCE_TYPE_REQUEST" = "auto" ]; then
    INSTANCE_TYPE_AUTO=1
    INSTANCE_TYPE="$(awk 'NR==1 {print $1}' "$candidate_file")"
    INSTANCE_TYPE_CANDIDATES="$(instance_candidate_names "$candidate_file" 10)"
  else
    requested_line="$(awk -v requested="$INSTANCE_TYPE_REQUEST" '$1 == requested {print; exit}' "$candidate_file")"
    [ -n "$requested_line" ] || die "$INSTANCE_TYPE_REQUEST is not offered in $AZ or does not satisfy the requested architecture/resources"
    INSTANCE_TYPE="$INSTANCE_TYPE_REQUEST"
    INSTANCE_TYPE_CANDIDATES="$INSTANCE_TYPE_REQUEST"
  fi

  if [ "$ROOT_VOLUME_TYPE_REQUEST" = "auto" ]; then
    VOLUME_TYPE_AUTO=1
    ROOT_VOLUME_TYPE="gp3"
    VOLUME_TYPE_CANDIDATES="gp3 gp2"
  else
    ROOT_VOLUME_TYPE="$ROOT_VOLUME_TYPE_REQUEST"
    VOLUME_TYPE_CANDIDATES="$ROOT_VOLUME_TYPE_REQUEST"
  fi

  detail "Recommended instance offerings:"
  print_instance_candidates "$candidate_file" 5
}

customize_launch_plan() {
  local selected_type selected_volume candidate_file

  candidate_file="$(new_temp_file aws-route-sg-custom-types.XXXXXX)"
  load_instance_candidates "$AWS_PROFILE" "$REGION" "$AZ" "$ARCHITECTURE" \
    "$MIN_VCPUS" "$MIN_MEMORY_MIB" "$candidate_file"
  printf '\nAvailable recommendations:\n'
  print_instance_candidates "$candidate_file" 8

  selected_type="$(prompt_with_default "Instance type" "$INSTANCE_TYPE")"
  if ! awk -v requested="$selected_type" '$1 == requested {found=1} END {exit !found}' "$candidate_file"; then
    die "$selected_type is not an eligible offering in $AZ"
  fi
  selected_volume="$(prompt_with_default "Root volume type" "$ROOT_VOLUME_TYPE")"
  case "$selected_volume" in
    gp3|gp2|io2|io1|standard) ;;
    *) die "unsupported EBS root volume choice: $selected_volume" ;;
  esac

  INSTANCE_TYPE="$selected_type"
  INSTANCE_TYPE_CANDIDATES="$selected_type"
  INSTANCE_TYPE_AUTO=0
  ROOT_VOLUME_TYPE="$selected_volume"
  VOLUME_TYPE_CANDIDATES="$selected_volume"
  VOLUME_TYPE_AUTO=0
}

confirm_create_plan() {
  local answer

  printf '\nCreate plan:\n'
  detail "Region/AZ: $REGION / $AZ"
  detail "Network: default VPC $VPC_ID, subnet $SUBNET_ID"
  detail "Image: $AMI_NAME ($AMI_ID)"
  detail "Launch: $INSTANCE_TYPE, ${ROOT_VOLUME_SIZE} GiB $ROOT_VOLUME_TYPE"
  detail "Inbound: all protocols from $INGRESS_CIDR"
  detail "Managed name: $INSTANCE_NAME"

  [ "$INGRESS_CIDR" != "0.0.0.0/0" ] || \
    warn "INGRESS_CIDR=0.0.0.0/0 exposes all protocols to the public internet"

  is_true "$AUTO_APPROVE" && return 0
  if ! is_interactive; then
    die "non-interactive create requires --yes or AUTO_APPROVE=1"
  fi

  printf 'Use this plan? [Y/n/c=customize] ' >&2
  IFS= read -r answer || true
  case "${answer:-y}" in
    y|Y|yes|YES) return 0 ;;
    c|C)
      customize_launch_plan
      printf '\nSelected launch: %s, %s GiB %s\n' "$INSTANCE_TYPE" "$ROOT_VOLUME_SIZE" "$ROOT_VOLUME_TYPE"
      confirm_action "Start creating resources?" yes || die "operation cancelled"
      ;;
    *) die "operation cancelled" ;;
  esac
}

find_security_group_id() {
  local ids count
  ids="$(aws_region ec2 describe-security-groups \
    --filters \
      "Name=vpc-id,Values=$VPC_ID" \
      "Name=group-name,Values=$SECURITY_GROUP_NAME" \
    --query 'SecurityGroups[].GroupId' \
    --output text)"
  count="$(word_count "$ids")"
  [ "$count" -le 1 ] || die "found multiple security groups named $SECURITY_GROUP_NAME in $VPC_ID: $ids"
  [ "$count" = "1" ] && printf '%s\n' "$ids" | awk '{print $1}'
  return 0
}

ensure_security_group() {
  local owner ingress_cidrs egress_cidrs

  SECURITY_GROUP_ID="$(find_security_group_id)"
  if [ -z "$SECURITY_GROUP_ID" ]; then
    log "creating security group $SECURITY_GROUP_NAME"
    SECURITY_GROUP_ID="$(aws_region ec2 create-security-group \
      --group-name "$SECURITY_GROUP_NAME" \
      --description "AWS route Singapore transit node" \
      --vpc-id "$VPC_ID" \
      --tag-specifications \
        "ResourceType=security-group,Tags=[{Key=Name,Value=$SECURITY_GROUP_NAME},{Key=Project,Value=$PROJECT_TAG},{Key=Role,Value=$ROLE_TAG},{Key=ManagedBy,Value=$MANAGED_BY}]" \
      --query GroupId \
      --output text)"
  else
    owner="$(aws_region ec2 describe-security-groups \
      --group-ids "$SECURITY_GROUP_ID" \
      --query 'SecurityGroups[0].Tags[?Key==`ManagedBy`]|[0].Value' \
      --output text)"
    [ "$owner" = "$MANAGED_BY" ] || \
      die "security group $SECURITY_GROUP_NAME already exists but is not managed by this script ($SECURITY_GROUP_ID)"
    detail "Security group: reusing $SECURITY_GROUP_ID"
  fi

  ingress_cidrs="$(aws_region ec2 describe-security-groups \
    --group-ids "$SECURITY_GROUP_ID" \
    --query "SecurityGroups[0].IpPermissions[?IpProtocol=='-1'].IpRanges[].CidrIp" \
    --output text | tr '\t' ' ')"
  case " $ingress_cidrs " in
    *" $INGRESS_CIDR "*) ;;
    *)
      log "adding all-protocol ingress from $INGRESS_CIDR"
      aws_region ec2 authorize-security-group-ingress \
        --group-id "$SECURITY_GROUP_ID" \
        --ip-permissions \
          "IpProtocol=-1,IpRanges=[{CidrIp=$INGRESS_CIDR,Description='AWS route traffic'}]" >/dev/null
      ;;
  esac

  egress_cidrs="$(aws_region ec2 describe-security-groups \
    --group-ids "$SECURITY_GROUP_ID" \
    --query "SecurityGroups[0].IpPermissionsEgress[?IpProtocol=='-1'].IpRanges[].CidrIp" \
    --output text | tr '\t' ' ')"
  case " $egress_cidrs " in
    *" 0.0.0.0/0 "*) ;;
    *)
      aws_region ec2 authorize-security-group-egress \
        --group-id "$SECURITY_GROUP_ID" \
        --ip-permissions \
          "IpProtocol=-1,IpRanges=[{CidrIp=0.0.0.0/0,Description='AWS route egress'}]" >/dev/null
      ;;
  esac
}

run_instance_request() {
  local instance_type="$1"
  local volume_type="$2"
  local client_token="$3"
  local dry_run="$4"
  local args

  args=(
    ec2 run-instances
    --image-id "$AMI_ID"
    --instance-type "$instance_type"
    --key-name "$KEY_NAME"
    --subnet-id "$SUBNET_ID"
    --security-group-ids "$SECURITY_GROUP_ID"
    --associate-public-ip-address
    --metadata-options HttpTokens=required,HttpEndpoint=enabled
    --client-token "$client_token"
    --block-device-mappings "DeviceName=$ROOT_DEVICE_NAME,Ebs={VolumeSize=$ROOT_VOLUME_SIZE,VolumeType=$volume_type,DeleteOnTermination=true}"
    --tag-specifications
      "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=Project,Value=$PROJECT_TAG},{Key=Role,Value=$ROLE_TAG},{Key=ManagedBy,Value=$MANAGED_BY}]"
      "ResourceType=volume,Tags=[{Key=Name,Value=${INSTANCE_NAME}-root},{Key=Project,Value=$PROJECT_TAG},{Key=Role,Value=$ROLE_TAG},{Key=ManagedBy,Value=$MANAGED_BY}]"
    --count 1
    --query 'Instances[0].InstanceId'
    --output text
  )
  case "$instance_type" in
    t2.*|t3.*|t3a.*|t4g.*) args+=(--credit-specification CpuCredits=standard) ;;
  esac
  if [ "$dry_run" != "0" ]; then
    args+=(--dry-run)
  fi
  aws_region "${args[@]}"
}

launch_new_instance() {
  local instance_type volume_type output token attempt recovered capacity_failure last_error
  last_error=""

  for instance_type in $INSTANCE_TYPE_CANDIDATES; do
    capacity_failure=0
    for volume_type in $VOLUME_TYPE_CANDIDATES; do
      token="$(make_client_token "$REGION/$AZ/$INSTANCE_NAME/$instance_type/$volume_type")"
      output="$(run_instance_request "$instance_type" "$volume_type" "$token" 1 2>&1 || true)"
      case "$output" in
        *DryRunOperation*) ;;
        *)
          last_error="$(short_error "$output")"
          case "$output" in
            *UnauthorizedOperation*|*AuthFailure*|*AccessDenied*) die "launch preflight is not authorized: $last_error" ;;
          esac
          warn "skipping $instance_type + $volume_type: $last_error"
          continue
          ;;
      esac

      log "launching $instance_type with ${ROOT_VOLUME_SIZE} GiB $volume_type"
      attempt=1
      while [ "$attempt" -le 3 ]; do
        if output="$(run_instance_request "$instance_type" "$volume_type" "$token" 0 2>&1)"; then
          INSTANCE_ID="$output"
          INSTANCE_TYPE="$instance_type"
          ROOT_VOLUME_TYPE="$volume_type"
          return 0
        fi

        recovered="$(get_single_instance_id)"
        if [ -n "$recovered" ]; then
          warn "launch response was incomplete, but managed instance $recovered exists; continuing"
          INSTANCE_ID="$recovered"
          INSTANCE_TYPE="$instance_type"
          ROOT_VOLUME_TYPE="$volume_type"
          return 0
        fi

        last_error="$(short_error "$output")"
        if is_capacity_error "$output"; then
          warn "$instance_type has insufficient capacity in $AZ; trying the next candidate"
          capacity_failure=1
          break
        fi
        if is_volume_error "$output"; then
          warn "$volume_type is not usable in $AZ; trying another volume type"
          break
        fi
        if is_retryable_aws_error "$output" && [ "$attempt" -lt 3 ]; then
          warn "temporary AWS error; retrying the same idempotent launch ($attempt/3)"
          sleep $((attempt * 3))
          attempt=$((attempt + 1))
          continue
        fi
        die "instance launch failed: $last_error"
      done
      [ "$capacity_failure" -eq 0 ] || break
    done
  done

  die "no launch candidate succeeded in $AZ. Last error: ${last_error:-unknown}"
}

ensure_instance() {
  local state actual_vpc actual_subnet actual_key attached_groups

  INSTANCE_ID="$(get_single_instance_id)"
  if [ -z "$INSTANCE_ID" ]; then
    launch_new_instance
  else
    detail "Instance: reusing $INSTANCE_ID"
  fi

  actual_vpc="$(aws_region ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].VpcId' --output text)"
  actual_subnet="$(aws_region ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].SubnetId' --output text)"
  actual_key="$(aws_region ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].KeyName' --output text)"
  attached_groups="$(aws_region ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' --output text)"
  [ "$actual_vpc" = "$VPC_ID" ] || die "existing instance is in VPC $actual_vpc, expected $VPC_ID"
  [ "$actual_subnet" = "$SUBNET_ID" ] || die "existing instance is in subnet $actual_subnet, expected $SUBNET_ID"
  [ "$actual_key" = "$KEY_NAME" ] || die "existing instance uses key pair $actual_key, expected $KEY_NAME"
  case " $attached_groups " in
    *" $SECURITY_GROUP_ID "*) ;;
    *) die "existing instance does not use security group $SECURITY_GROUP_ID" ;;
  esac

  state="$(aws_region ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name' --output text)"
  if [ "$state" = "stopping" ]; then
    run_with_progress "waiting for $INSTANCE_ID to stop" \
      aws_region ec2 wait instance-stopped --instance-ids "$INSTANCE_ID" || \
      die "$INSTANCE_ID did not stop"
    state="stopped"
  fi
  if [ "$state" = "stopped" ]; then
    log "starting $INSTANCE_ID"
    aws_region ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null
  fi

  run_with_progress "waiting for instance state running" \
    aws_region ec2 wait instance-running --instance-ids "$INSTANCE_ID" || \
    die "$INSTANCE_ID did not reach running state"
  run_with_progress "waiting for EC2 status checks" \
    aws_region ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID" || \
    die "$INSTANCE_ID status checks did not become healthy"
}

show_status() {
  local instance_id public_ip vpc_id vpc_cidr

  instance_id="$(get_single_instance_id)"
  if [ -z "$instance_id" ]; then
    log "Role=SG_TRANSIT Region=$REGION Instance=None"
    detail "No managed active instance named $INSTANCE_NAME"
    return 0
  fi

  vpc_id="$(aws_region ec2 describe-instances \
    --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0].VpcId' \
    --output text)"
  vpc_cidr="$(aws_region ec2 describe-vpcs \
    --vpc-ids "$vpc_id" \
    --query 'Vpcs[0].CidrBlock' \
    --output text)"
  public_ip="$(aws_region ec2 describe-instances \
    --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)"

  log "Role=SG_TRANSIT Region=$REGION VPC=$vpc_id CIDR=$vpc_cidr"
  aws_region ec2 describe-instances \
    --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0].{Instance:InstanceId,State:State.Name,PrivateIP:PrivateIpAddress,PublicIP:PublicIpAddress,AZ:Placement.AvailabilityZone,VPC:VpcId,Subnet:SubnetId,SecurityGroup:SecurityGroups[0].GroupId}' \
    --output table

  if ! is_none "$public_ip"; then
    log "SSH: ssh -i '$PEM_PATH' admin@$public_ip"
  else
    detail "SSH: unavailable (instance has no public IP)"
  fi
}

delete_security_group_with_retry() {
  local group_id="$1"
  local output attempt=0
  while [ "$attempt" -lt 18 ]; do
    if output="$(aws_region ec2 delete-security-group --group-id "$group_id" 2>&1)"; then
      detail "Deleted security group: $group_id"
      return 0
    fi
    case "$output" in
      *DependencyViolation*) sleep 5 ;;
      *InvalidGroup.NotFound*) return 0 ;;
      *) die "could not delete security group $group_id: $(short_error "$output")" ;;
    esac
    attempt=$((attempt + 1))
  done
  die "security group still has dependencies: $group_id"
}

delete_stack() {
  local instance_ids allocation_ids volume_ids security_group_ids

  instance_ids="$(find_instance_ids)"
  if [ -n "$instance_ids" ]; then
    allocation_ids="$(aws_region ec2 describe-instances \
      --instance-ids $instance_ids \
      --query 'Reservations[].Instances[].NetworkInterfaces[].Association.AllocationId' \
      --output text)"
    if ! is_none "$allocation_ids"; then
      warn "Elastic IP allocation(s) are attached and will not be released automatically: $allocation_ids"
    fi
    log "terminating instance(s): $instance_ids"
    aws_region ec2 terminate-instances --instance-ids $instance_ids >/dev/null
    run_with_progress "waiting for instance termination" \
      aws_region ec2 wait instance-terminated --instance-ids $instance_ids || \
      die "instance termination did not finish"
  else
    detail "No managed active instance named $INSTANCE_NAME"
  fi

  volume_ids="$(aws_region ec2 describe-volumes \
    --filters \
      "Name=tag:Name,Values=${INSTANCE_NAME}-root" \
      "Name=tag:ManagedBy,Values=$MANAGED_BY" \
      Name=status,Values=available \
    --query 'Volumes[].VolumeId' \
    --output text)"
  for volume_id in $volume_ids; do
    aws_region ec2 delete-volume --volume-id "$volume_id"
    detail "Deleted leftover volume: $volume_id"
  done

  security_group_ids="$(aws_region ec2 describe-security-groups \
    --filters \
      "Name=group-name,Values=$SECURITY_GROUP_NAME" \
      "Name=tag:Role,Values=$ROLE_TAG" \
      "Name=tag:ManagedBy,Values=$MANAGED_BY" \
    --query 'SecurityGroups[].GroupId' \
    --output text)"
  for group_id in $security_group_ids; do
    delete_security_group_with_retry "$group_id"
  done

  detail "Preserved key pair $KEY_NAME and local key $PEM_PATH"
  detail "Preserved default VPC, subnets, route tables, and Lightsail VPC peering"
}

show_help() {
  cat <<EOF
Usage:
  $0 create [--yes]          Create or reuse the Singapore transit EC2
  $0 status                  Show instance status and connection commands
  $0 delete [--yes]          Delete the managed EC2 and security group

The create command queries the selected AZ before launch. With the defaults it
chooses a small eligible x86_64 instance and tries gp3, then gp2. If an EC2 type
has no capacity or an EBS type is unsupported, auto mode tries the next candidate.

Common overrides:
  AWS_PROFILE=$AWS_PROFILE
  REGION=$REGION
  AZ=$AZ
  INSTANCE_TYPE=auto         Or an exact offered type
  MIN_VCPUS=$MIN_VCPUS
  MIN_MEMORY_MIB=$MIN_MEMORY_MIB
  ROOT_VOLUME_TYPE=auto      Or gp3/gp2/io2/io1/standard
  ROOT_VOLUME_SIZE_GIB=      Defaults to the AMI root size
  KEY_NAME=$KEY_NAME
  PEM_PATH=$PEM_PATH
  INGRESS_CIDR=$INGRESS_CIDR
  AUTO_APPROVE=1             Skip interactive confirmation
  INTERACTIVE=0              Disable prompts

Examples:
  $0 create
  INSTANCE_TYPE=t3.micro ROOT_VOLUME_TYPE=gp3 $0 create
  $0 status
  $0 delete
EOF
}

main() {
  case "$ACTION" in
    help|-h|--help)
      show_help
      return 0
      ;;
  esac

  require_aws
  acquire_lock "aws-route-sg-$AWS_PROFILE-$REGION-$INSTANCE_NAME"

  case "$ACTION" in
    create)
      set_step_total 8
      step "Verify AWS identity"
      verify_identity
      step "Ensure Lightsail VPC peering"
      ensure_lightsail_peering
      step "Resolve the default VPC and subnet"
      resolve_network
      step "Resolve AMI, instance, and EBS candidates"
      resolve_image_and_launch_candidates
      confirm_create_plan
      step "Ensure the regional SSH key pair"
      ensure_key_pair_for_region "$AWS_PROFILE" "$REGION" "$KEY_NAME" "$PEM_PATH"
      step "Ensure the dedicated security group"
      ensure_security_group
      step "Create or start the EC2 instance"
      ensure_instance
      step "Show final status"
      show_status
      ;;
    status)
      set_step_total 2
      step "Verify AWS identity"
      verify_identity
      step "Show current status"
      show_status
      ;;
    delete)
      set_step_total 3
      step "Verify AWS identity"
      verify_identity
      step "Confirm deletion"
      detail "Managed instance name: $INSTANCE_NAME"
      detail "Region: $REGION"
      confirm_action "Delete the managed Singapore EC2 and security group?" no || die "operation cancelled"
      step "Delete managed resources"
      delete_stack
      ;;
    *)
      show_help
      die "unknown action: $ACTION"
      ;;
  esac
}

main
