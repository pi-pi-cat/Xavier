#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_PREFIX="aws-route-edge"
# shellcheck source=aws-route-common.sh
source "$SCRIPT_DIR/aws-route-common.sh"

TARGET_REGION_ENV="${TARGET_REGION:-}"
TARGET_AZ_ENV="${TARGET_AZ:-}"
TARGET_VPC_CIDR_ENV="${TARGET_VPC_CIDR:-}"
TARGET_SUBNET_CIDR_ENV="${TARGET_SUBNET_CIDR:-}"

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
[ "${#POSITIONAL[@]}" -le 4 ] || die "too many positional arguments: ${POSITIONAL[*]}"

TARGET_REGION="${POSITIONAL[0]-$TARGET_REGION_ENV}"
TARGET_AZ="${POSITIONAL[1]-$TARGET_AZ_ENV}"
TARGET_VPC_CIDR="${POSITIONAL[2]-$TARGET_VPC_CIDR_ENV}"
TARGET_SUBNET_CIDR="${POSITIONAL[3]-$TARGET_SUBNET_CIDR_ENV}"

AWS_PROFILE="${AWS_PROFILE:-personal}"
SOURCE_REGION="${SOURCE_REGION:-ap-southeast-1}"
SOURCE_INSTANCE_NAME="${SOURCE_INSTANCE_NAME:-ec2-sg-route}"
SOURCE_ROLE_TAG="${SOURCE_ROLE_TAG:-sg-transit}"
SOURCE_MANAGED_BY="${SOURCE_MANAGED_BY:-aws-route-script}"

INSTANCE_TYPE_REQUEST="${INSTANCE_TYPE:-auto}"
INSTANCE_TYPE="$INSTANCE_TYPE_REQUEST"
MIN_VCPUS="${MIN_VCPUS:-1}"
MIN_MEMORY_MIB="${MIN_MEMORY_MIB:-512}"
DEBIAN_RELEASE="${DEBIAN_RELEASE:-13}"
DEBIAN_OWNER_ID="${DEBIAN_OWNER_ID:-136693071363}"
ARCHITECTURE="${ARCHITECTURE:-x86_64}"
KEY_NAME="${KEY_NAME:-aws-route}"
INGRESS_CIDR="${INGRESS_CIDR:-0.0.0.0/0}"
ROOT_VOLUME_TYPE_REQUEST="${ROOT_VOLUME_TYPE:-auto}"
ROOT_VOLUME_TYPE="$ROOT_VOLUME_TYPE_REQUEST"
ROOT_VOLUME_SIZE_OVERRIDE="${ROOT_VOLUME_SIZE_GIB:-}"

PROJECT_TAG="${PROJECT_TAG:-aws-route}"
ROLE_TAG="${ROLE_TAG:-edge-node}"
MANAGED_BY="${MANAGED_BY:-aws-route-edge-script}"

if [ -z "${PEM_PATH:-}" ]; then
  if [ -f "$HOME/.ssh/aws-route.pem" ]; then
    PEM_PATH="$HOME/.ssh/aws-route.pem"
  elif [ -f "$HOME/Downloads/aws-route.pem" ]; then
    PEM_PATH="$HOME/Downloads/aws-route.pem"
  else
    PEM_PATH="$HOME/.ssh/aws-route.pem"
  fi
fi

STACK_NAME=""
TARGET_VPC_NAME=""
TARGET_SUBNET_NAME=""
TARGET_ROUTE_TABLE_NAME=""
TARGET_IGW_NAME=""
TARGET_SECURITY_GROUP_NAME=""
TARGET_INSTANCE_NAME=""

INSTANCE_TYPE_AUTO=0
VOLUME_TYPE_AUTO=0
INSTANCE_TYPE_CANDIDATES=""
VOLUME_TYPE_CANDIDATES=""

aws_for_region() {
  local region="$1"
  shift
  aws_at "$AWS_PROFILE" "$region" "$@"
}

aws_source() {
  aws_for_region "$SOURCE_REGION" "$@"
}

aws_target() {
  aws_for_region "$TARGET_REGION" "$@"
}

require_commands() {
  require_aws
}

resolve_target_inputs() {
  local region_exists zone_rows default_az

  if [ -z "$TARGET_REGION" ]; then
    [ "$ACTION" = "create" ] || die "TARGET_REGION is required for $ACTION"
    if is_interactive; then
      TARGET_REGION="$(prompt_with_default "Target AWS Region" "af-south-1")"
    else
      die "TARGET_REGION is required"
    fi
  fi

  region_exists="$(aws_for_region "$SOURCE_REGION" ec2 describe-regions \
    --all-regions \
    --filters "Name=region-name,Values=$TARGET_REGION" \
    --query 'length(Regions)' \
    --output text)"
  [ "$region_exists" != "0" ] || die "AWS Region $TARGET_REGION was not found"

  if [ -z "$TARGET_AZ" ]; then
    [ "$ACTION" = "create" ] || die "TARGET_AZ is required for $ACTION"
    zone_rows="$(aws_target ec2 describe-availability-zones \
      --all-availability-zones \
      --query "AvailabilityZones[?State=='available' || OptInStatus=='not-opted-in'].[ZoneName,ZoneType,OptInStatus]" \
      --output text)"
    [ -n "$zone_rows" ] || die "no availability zones were returned for $TARGET_REGION"
    printf '\nAvailable target zones:\n'
    printf '%s\n' "$zone_rows" | sed 's/^/  /'
    default_az="$(printf '%s\n' "$zone_rows" | awk '
      NR == 1 { fallback=$1 }
      $1 ~ /-los-/ { selected=$1; exit }
      END { print (selected ? selected : fallback) }
    ')"
    TARGET_AZ="$(prompt_with_default "Target Availability Zone or Local Zone" "$default_az")"
  fi
}

require_target_identity() {
  [ -n "$TARGET_REGION" ] || die "TARGET_REGION is required"
  [ -n "$TARGET_AZ" ] || die "TARGET_AZ is required"

  local slug
  slug="$(printf '%s' "$TARGET_AZ" | tr -c '[:alnum:]-' '-')"
  STACK_NAME="${STACK_NAME_OVERRIDE:-aws-route-$slug}"
  TARGET_VPC_NAME="${TARGET_VPC_NAME_OVERRIDE:-$STACK_NAME-vpc}"
  TARGET_SUBNET_NAME="${TARGET_SUBNET_NAME_OVERRIDE:-$STACK_NAME-subnet}"
  TARGET_ROUTE_TABLE_NAME="${TARGET_ROUTE_TABLE_NAME_OVERRIDE:-$STACK_NAME-rt}"
  TARGET_IGW_NAME="${TARGET_IGW_NAME_OVERRIDE:-$STACK_NAME-igw}"
  TARGET_SECURITY_GROUP_NAME="${TARGET_SECURITY_GROUP_NAME_OVERRIDE:-$STACK_NAME-sg}"
  TARGET_INSTANCE_NAME="${TARGET_INSTANCE_NAME_OVERRIDE:-$STACK_NAME-node}"
}

verify_identity() {
  local account arn
  account="$(aws_source sts get-caller-identity --query Account --output text)" || \
    die "AWS login failed for profile $AWS_PROFILE"
  arn="$(aws_source sts get-caller-identity --query Arn --output text)"
  detail "AWS account: $account"
  detail "Identity: $arn"
}

get_single_id() {
  local label="$1"
  local ids="$2"
  local count
  count="$(word_count "$ids")"
  [ "$count" -le 1 ] || die "Found $count $label resources; resolve duplicates first: $ids"
  if [ "$count" = "1" ]; then
    printf '%s\n' "$ids" | awk '{print $1}'
  fi
}

resolve_source_network() {
  local mode="${1:-required}"
  local source_ids explicit_route_table

  source_ids="$(aws_source ec2 describe-instances \
    --filters \
      "Name=tag:Name,Values=$SOURCE_INSTANCE_NAME" \
      "Name=tag:Role,Values=$SOURCE_ROLE_TAG" \
      "Name=tag:ManagedBy,Values=$SOURCE_MANAGED_BY" \
      Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text)"
  SOURCE_INSTANCE_ID="$(get_single_id "source instances named $SOURCE_INSTANCE_NAME" "$source_ids")"
  if [ -z "$SOURCE_INSTANCE_ID" ]; then
    if [ "$mode" = "optional" ]; then
      warn "source instance $SOURCE_INSTANCE_NAME was not found in $SOURCE_REGION; deletion will discover peering from the target VPC"
      return 1
    fi
    die "source instance $SOURCE_INSTANCE_NAME was not found in $SOURCE_REGION"
  fi

  SOURCE_VPC_ID="$(aws_source ec2 describe-instances \
    --instance-ids "$SOURCE_INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].VpcId' \
    --output text)"
  SOURCE_SUBNET_ID="$(aws_source ec2 describe-instances \
    --instance-ids "$SOURCE_INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].SubnetId' \
    --output text)"
  SOURCE_PRIVATE_IP="$(aws_source ec2 describe-instances \
    --instance-ids "$SOURCE_INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' \
    --output text)"
  SOURCE_VPC_CIDR="$(aws_source ec2 describe-vpcs \
    --vpc-ids "$SOURCE_VPC_ID" \
    --query 'Vpcs[0].CidrBlock' \
    --output text)"

  explicit_route_table="$(aws_source ec2 describe-route-tables \
    --filters "Name=association.subnet-id,Values=$SOURCE_SUBNET_ID" \
    --query 'RouteTables[0].RouteTableId' \
    --output text)"

  if is_none "$explicit_route_table"; then
    SOURCE_ROUTE_TABLE_ID="$(aws_source ec2 describe-route-tables \
      --filters \
        "Name=vpc-id,Values=$SOURCE_VPC_ID" \
        Name=association.main,Values=true \
      --query 'RouteTables[0].RouteTableId' \
      --output text)"
  else
    SOURCE_ROUTE_TABLE_ID="$explicit_route_table"
  fi

  if is_none "$SOURCE_ROUTE_TABLE_ID"; then die "Could not resolve the effective route table for $SOURCE_SUBNET_ID"; fi
  log "Source: Instance=$SOURCE_INSTANCE_ID PrivateIP=$SOURCE_PRIVATE_IP VPC=$SOURCE_VPC_ID CIDR=$SOURCE_VPC_CIDR RouteTable=$SOURCE_ROUTE_TABLE_ID"
}

inspect_target_zone() {
  ZONE_STATE="$(aws_target ec2 describe-availability-zones \
    --all-availability-zones \
    --zone-names "$TARGET_AZ" \
    --query 'AvailabilityZones[0].State' \
    --output text)"
  if is_none "$ZONE_STATE"; then die "Availability Zone $TARGET_AZ was not found in $TARGET_REGION"; fi

  ZONE_TYPE="$(aws_target ec2 describe-availability-zones \
    --all-availability-zones \
    --zone-names "$TARGET_AZ" \
    --query 'AvailabilityZones[0].ZoneType' \
    --output text)"
  ZONE_GROUP="$(aws_target ec2 describe-availability-zones \
    --all-availability-zones \
    --zone-names "$TARGET_AZ" \
    --query 'AvailabilityZones[0].GroupName' \
    --output text)"
  ZONE_OPT_IN="$(aws_target ec2 describe-availability-zones \
    --all-availability-zones \
    --zone-names "$TARGET_AZ" \
    --query 'AvailabilityZones[0].OptInStatus' \
    --output text)"
  NETWORK_BORDER_GROUP="$(aws_target ec2 describe-availability-zones \
    --all-availability-zones \
    --zone-names "$TARGET_AZ" \
    --query 'AvailabilityZones[0].NetworkBorderGroup' \
    --output text)"

  if is_none "$NETWORK_BORDER_GROUP"; then NETWORK_BORDER_GROUP="$TARGET_REGION"; fi
  detail "Target zone: $TARGET_AZ ($ZONE_TYPE, opt-in: $ZONE_OPT_IN, border: $NETWORK_BORDER_GROUP)"
}

wait_for_zone_ready() {
  local zone_values state opt_in attempt=0
  while [ "$attempt" -lt 60 ]; do
    zone_values="$(aws_target ec2 describe-availability-zones \
      --all-availability-zones \
      --zone-names "$TARGET_AZ" \
      --query '[AvailabilityZones[0].State,AvailabilityZones[0].OptInStatus]' \
      --output text)"
    state="$(printf '%s' "$zone_values" | awk '{print $1}')"
    opt_in="$(printf '%s' "$zone_values" | awk '{print $2}')"
    [ "$state" = "available" ] && [ "$opt_in" != "not-opted-in" ] && return 0
    sleep 5
    attempt=$((attempt + 1))
  done
  return 1
}

ensure_target_zone() {
  inspect_target_zone

  if [ "$ZONE_OPT_IN" = "not-opted-in" ]; then
    if is_none "$ZONE_GROUP"; then die "No zone group found for $TARGET_AZ"; fi
    log "opting in zone group $ZONE_GROUP"
    aws_target ec2 modify-availability-zone-group \
      --group-name "$ZONE_GROUP" \
      --opt-in-status opted-in >/dev/null
    run_with_progress "waiting for target zone readiness" wait_for_zone_ready || \
      die "$TARGET_AZ did not become opted in"
    inspect_target_zone
  fi

  [ "$ZONE_STATE" = "available" ] || die "$TARGET_AZ is not available (state: $ZONE_STATE)"
  [ "$ZONE_OPT_IN" != "not-opted-in" ] || die "$TARGET_AZ did not become opted in"
}

find_target_vpc_id() {
  local ids
  ids="$(aws_target ec2 describe-vpcs \
    --filters \
      "Name=tag:Stack,Values=$STACK_NAME" \
      "Name=tag:ManagedBy,Values=$MANAGED_BY" \
    --query 'Vpcs[].VpcId' \
    --output text)"
  get_single_id "target VPC" "$ids"
}

find_target_subnet_id() {
  local ids
  ids="$(aws_target ec2 describe-subnets \
    --filters \
      "Name=tag:Stack,Values=$STACK_NAME" \
      "Name=tag:ManagedBy,Values=$MANAGED_BY" \
    --query 'Subnets[].SubnetId' \
    --output text)"
  get_single_id "target subnet" "$ids"
}

resolve_create_cidrs() {
  local existing_vpc existing_subnet existing_cidr used_cidrs target_region_cidrs source_peer_cidrs used
  local existing_subnet_cidrs

  existing_subnet=""
  existing_vpc="$(find_target_vpc_id)"
  if [ -n "$existing_vpc" ]; then
    existing_cidr="$(aws_target ec2 describe-vpcs \
      --vpc-ids "$existing_vpc" \
      --query 'Vpcs[0].CidrBlock' \
      --output text)"
    if [ -z "$TARGET_VPC_CIDR" ]; then
      TARGET_VPC_CIDR="$existing_cidr"
    else
      [ "$TARGET_VPC_CIDR" = "$existing_cidr" ] || \
        die "existing target VPC uses $existing_cidr, requested $TARGET_VPC_CIDR"
    fi

    existing_subnet="$(find_target_subnet_id)"
    if [ -n "$existing_subnet" ]; then
      existing_cidr="$(aws_target ec2 describe-subnets \
        --subnet-ids "$existing_subnet" \
        --query 'Subnets[0].CidrBlock' \
        --output text)"
      if [ -z "$TARGET_SUBNET_CIDR" ]; then
        TARGET_SUBNET_CIDR="$existing_cidr"
      else
        [ "$TARGET_SUBNET_CIDR" = "$existing_cidr" ] || \
          die "existing target subnet uses $existing_cidr, requested $TARGET_SUBNET_CIDR"
      fi
    fi
  fi

  target_region_cidrs="$(aws_target ec2 describe-vpcs \
    --query 'Vpcs[].CidrBlock' \
    --output text)"
  source_peer_cidrs="$(aws_source ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=$SOURCE_VPC_ID" \
    --query 'RouteTables[].Routes[?VpcPeeringConnectionId!=`null`].DestinationCidrBlock' \
    --output text)"
  used_cidrs="$SOURCE_VPC_CIDR $target_region_cidrs $source_peer_cidrs"

  if [ -z "$TARGET_VPC_CIDR" ]; then
    TARGET_VPC_CIDR="$(choose_free_vpc_cidr "$used_cidrs")" || \
      die "could not find a free automatic 10.x.0.0/16 VPC CIDR"
  fi
  validate_cidr "$TARGET_VPC_CIDR" || die "invalid TARGET_VPC_CIDR: $TARGET_VPC_CIDR"

  if [ -z "$existing_vpc" ]; then
    for used in $used_cidrs; do
      validate_cidr "$used" || continue
      if cidrs_overlap "$TARGET_VPC_CIDR" "$used"; then
        die "target VPC CIDR $TARGET_VPC_CIDR overlaps existing network $used"
      fi
    done
  fi

  existing_subnet_cidrs=""
  if [ -n "$existing_vpc" ]; then
    existing_subnet_cidrs="$(aws_target ec2 describe-subnets \
      --filters "Name=vpc-id,Values=$existing_vpc" \
      --query 'Subnets[].CidrBlock' \
      --output text)"
  fi

  if [ -z "$TARGET_SUBNET_CIDR" ]; then
    TARGET_SUBNET_CIDR="$(choose_free_subnet_cidr "$TARGET_VPC_CIDR" "$existing_subnet_cidrs")" || \
      die "could not select a free /24 subnet inside $TARGET_VPC_CIDR"
  fi
  validate_cidr "$TARGET_SUBNET_CIDR" || die "invalid TARGET_SUBNET_CIDR: $TARGET_SUBNET_CIDR"
  cidr_contains "$TARGET_VPC_CIDR" "$TARGET_SUBNET_CIDR" || \
    die "subnet $TARGET_SUBNET_CIDR is not inside VPC $TARGET_VPC_CIDR"
  if [ -z "$existing_subnet" ]; then
    for used in $existing_subnet_cidrs; do
      validate_cidr "$used" || continue
      if cidrs_overlap "$TARGET_SUBNET_CIDR" "$used"; then
        die "target subnet $TARGET_SUBNET_CIDR overlaps existing subnet $used"
      fi
    done
  fi

  detail "Target VPC CIDR: $TARGET_VPC_CIDR"
  detail "Target subnet CIDR: $TARGET_SUBNET_CIDR"
}

ensure_target_vpc() {
  TARGET_VPC_ID="$(find_target_vpc_id)"
  if [ -z "$TARGET_VPC_ID" ]; then
    log "Creating target VPC $TARGET_VPC_CIDR"
    TARGET_VPC_ID="$(aws_target ec2 create-vpc \
      --cidr-block "$TARGET_VPC_CIDR" \
      --tag-specifications \
        "ResourceType=vpc,Tags=[{Key=Name,Value=$TARGET_VPC_NAME},{Key=Project,Value=$PROJECT_TAG},{Key=Role,Value=$ROLE_TAG},{Key=Stack,Value=$STACK_NAME},{Key=ManagedBy,Value=$MANAGED_BY}]" \
      --query 'Vpc.VpcId' \
      --output text)"
    run_with_progress "waiting for target VPC availability" \
      aws_target ec2 wait vpc-available --vpc-ids "$TARGET_VPC_ID" || \
      die "target VPC $TARGET_VPC_ID did not become available"
  else
    local actual_cidr
    actual_cidr="$(aws_target ec2 describe-vpcs \
      --vpc-ids "$TARGET_VPC_ID" \
      --query 'Vpcs[0].CidrBlock' \
      --output text)"
    [ "$actual_cidr" = "$TARGET_VPC_CIDR" ] || die "Existing VPC uses $actual_cidr, requested $TARGET_VPC_CIDR"
    log "Target VPC: reusing $TARGET_VPC_ID"
  fi

  aws_target ec2 modify-vpc-attribute --vpc-id "$TARGET_VPC_ID" --enable-dns-support Value=true
  aws_target ec2 modify-vpc-attribute --vpc-id "$TARGET_VPC_ID" --enable-dns-hostnames Value=true
}

ensure_target_subnet() {
  local ids actual_vpc actual_az actual_cidr
  ids="$(aws_target ec2 describe-subnets \
    --filters \
      "Name=tag:Stack,Values=$STACK_NAME" \
      "Name=tag:ManagedBy,Values=$MANAGED_BY" \
    --query 'Subnets[].SubnetId' \
    --output text)"
  TARGET_SUBNET_ID="$(get_single_id "target subnet" "$ids")"

  if [ -z "$TARGET_SUBNET_ID" ]; then
    log "Creating target subnet $TARGET_SUBNET_CIDR in $TARGET_AZ"
    TARGET_SUBNET_ID="$(aws_target ec2 create-subnet \
      --vpc-id "$TARGET_VPC_ID" \
      --cidr-block "$TARGET_SUBNET_CIDR" \
      --availability-zone "$TARGET_AZ" \
      --tag-specifications \
        "ResourceType=subnet,Tags=[{Key=Name,Value=$TARGET_SUBNET_NAME},{Key=Project,Value=$PROJECT_TAG},{Key=Role,Value=$ROLE_TAG},{Key=Stack,Value=$STACK_NAME},{Key=ManagedBy,Value=$MANAGED_BY}]" \
      --query 'Subnet.SubnetId' \
      --output text)"
    run_with_progress "waiting for target subnet availability" \
      aws_target ec2 wait subnet-available --subnet-ids "$TARGET_SUBNET_ID" || \
      die "target subnet $TARGET_SUBNET_ID did not become available"
  else
    actual_vpc="$(aws_target ec2 describe-subnets --subnet-ids "$TARGET_SUBNET_ID" --query 'Subnets[0].VpcId' --output text)"
    actual_az="$(aws_target ec2 describe-subnets --subnet-ids "$TARGET_SUBNET_ID" --query 'Subnets[0].AvailabilityZone' --output text)"
    actual_cidr="$(aws_target ec2 describe-subnets --subnet-ids "$TARGET_SUBNET_ID" --query 'Subnets[0].CidrBlock' --output text)"
    [ "$actual_vpc" = "$TARGET_VPC_ID" ] || die "Existing subnet is in VPC $actual_vpc, expected $TARGET_VPC_ID"
    [ "$actual_az" = "$TARGET_AZ" ] || die "Existing subnet is in $actual_az, expected $TARGET_AZ"
    [ "$actual_cidr" = "$TARGET_SUBNET_CIDR" ] || die "Existing subnet uses $actual_cidr, requested $TARGET_SUBNET_CIDR"
    log "Target subnet: reusing $TARGET_SUBNET_ID"
  fi

  aws_target ec2 modify-subnet-attribute \
    --subnet-id "$TARGET_SUBNET_ID" \
    --no-map-public-ip-on-launch
}

ensure_target_igw() {
  local ids attached_vpc
  ids="$(aws_target ec2 describe-internet-gateways \
    --filters \
      "Name=tag:Stack,Values=$STACK_NAME" \
      "Name=tag:ManagedBy,Values=$MANAGED_BY" \
    --query 'InternetGateways[].InternetGatewayId' \
    --output text)"
  TARGET_IGW_ID="$(get_single_id "target internet gateway" "$ids")"

  if [ -z "$TARGET_IGW_ID" ]; then
    log "Creating target internet gateway"
    TARGET_IGW_ID="$(aws_target ec2 create-internet-gateway \
      --tag-specifications \
        "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$TARGET_IGW_NAME},{Key=Project,Value=$PROJECT_TAG},{Key=Role,Value=$ROLE_TAG},{Key=Stack,Value=$STACK_NAME},{Key=ManagedBy,Value=$MANAGED_BY}]" \
      --query 'InternetGateway.InternetGatewayId' \
      --output text)"
  else
    log "Internet gateway: reusing $TARGET_IGW_ID"
  fi

  attached_vpc="$(aws_target ec2 describe-internet-gateways \
    --internet-gateway-ids "$TARGET_IGW_ID" \
    --query 'InternetGateways[0].Attachments[0].VpcId' \
    --output text)"

  if is_none "$attached_vpc"; then
    aws_target ec2 attach-internet-gateway \
      --internet-gateway-id "$TARGET_IGW_ID" \
      --vpc-id "$TARGET_VPC_ID"
  elif [ "$attached_vpc" != "$TARGET_VPC_ID" ]; then
    die "Internet gateway $TARGET_IGW_ID is attached to $attached_vpc"
  fi
}

ensure_route() {
  local region="$1"
  local route_table_id="$2"
  local destination_cidr="$3"
  local target_kind="$4"
  local target_id="$5"
  local route_count route_state current_target target_option target_field

  case "$target_kind" in
    igw) target_option="--gateway-id"; target_field="GatewayId" ;;
    pcx) target_option="--vpc-peering-connection-id"; target_field="VpcPeeringConnectionId" ;;
    *) die "Unsupported route target kind: $target_kind" ;;
  esac

  route_count="$(aws_for_region "$region" ec2 describe-route-tables \
    --route-table-ids "$route_table_id" \
    --query "length(RouteTables[0].Routes[?DestinationCidrBlock=='$destination_cidr'])" \
    --output text)"

  if [ "$route_count" = "0" ]; then
    aws_for_region "$region" ec2 create-route \
      --route-table-id "$route_table_id" \
      --destination-cidr-block "$destination_cidr" \
      "$target_option" "$target_id" >/dev/null
    return
  fi

  current_target="$(aws_for_region "$region" ec2 describe-route-tables \
    --route-table-ids "$route_table_id" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='$destination_cidr'] | [0].$target_field" \
    --output text)"
  [ "$current_target" = "$target_id" ] && return 0

  route_state="$(aws_for_region "$region" ec2 describe-route-tables \
    --route-table-ids "$route_table_id" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='$destination_cidr'] | [0].State" \
    --output text)"

  if [ "$target_kind" = "pcx" ] && [ "$route_state" = "blackhole" ]; then
    log "Replacing blackhole route $destination_cidr in $route_table_id"
    aws_for_region "$region" ec2 replace-route \
      --route-table-id "$route_table_id" \
      --destination-cidr-block "$destination_cidr" \
      "$target_option" "$target_id" >/dev/null
    return 0
  fi

  die "Route $destination_cidr already exists in $route_table_id with another target"
}

delete_route_if_matches() {
  local region="$1"
  local route_table_id="$2"
  local destination_cidr="$3"
  local target_field="$4"
  local target_id="$5"
  local current_target

  if is_none "$route_table_id"; then return 0; fi
  current_target="$(aws_for_region "$region" ec2 describe-route-tables \
    --route-table-ids "$route_table_id" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='$destination_cidr'] | [0].$target_field" \
    --output text 2>/dev/null || true)"

  if [ "$current_target" = "$target_id" ]; then
    aws_for_region "$region" ec2 delete-route \
      --route-table-id "$route_table_id" \
      --destination-cidr-block "$destination_cidr"
  fi
}

ensure_target_route_table() {
  local ids association_id
  ids="$(aws_target ec2 describe-route-tables \
    --filters \
      "Name=tag:Stack,Values=$STACK_NAME" \
      "Name=tag:ManagedBy,Values=$MANAGED_BY" \
    --query 'RouteTables[].RouteTableId' \
    --output text)"
  TARGET_ROUTE_TABLE_ID="$(get_single_id "target route table" "$ids")"

  if [ -z "$TARGET_ROUTE_TABLE_ID" ]; then
    log "Creating target route table"
    TARGET_ROUTE_TABLE_ID="$(aws_target ec2 create-route-table \
      --vpc-id "$TARGET_VPC_ID" \
      --tag-specifications \
        "ResourceType=route-table,Tags=[{Key=Name,Value=$TARGET_ROUTE_TABLE_NAME},{Key=Project,Value=$PROJECT_TAG},{Key=Role,Value=$ROLE_TAG},{Key=Stack,Value=$STACK_NAME},{Key=ManagedBy,Value=$MANAGED_BY}]" \
      --query 'RouteTable.RouteTableId' \
      --output text)"
  else
    log "Target route table: reusing $TARGET_ROUTE_TABLE_ID"
  fi

  association_id="$(aws_target ec2 describe-route-tables \
    --route-table-ids "$TARGET_ROUTE_TABLE_ID" \
    --query "RouteTables[0].Associations[?SubnetId=='$TARGET_SUBNET_ID'].RouteTableAssociationId | [0]" \
    --output text)"
  if is_none "$association_id"; then
    aws_target ec2 associate-route-table \
      --route-table-id "$TARGET_ROUTE_TABLE_ID" \
      --subnet-id "$TARGET_SUBNET_ID" >/dev/null
  fi

  ensure_route "$TARGET_REGION" "$TARGET_ROUTE_TABLE_ID" "0.0.0.0/0" igw "$TARGET_IGW_ID"
}

find_peering_id() {
  local ids peering_id actual_stack actual_managed_by
  ids="$(aws_source ec2 describe-vpc-peering-connections \
    --filters \
      "Name=requester-vpc-info.vpc-id,Values=$SOURCE_VPC_ID" \
      "Name=accepter-vpc-info.vpc-id,Values=$TARGET_VPC_ID" \
      Name=status-code,Values=initiating-request,pending-acceptance,provisioning,active \
    --query 'VpcPeeringConnections[].VpcPeeringConnectionId' \
    --output text)"
  peering_id="$(get_single_id "VPC peering connections" "$ids")"
  if [ -z "$peering_id" ]; then
    return 0
  fi

  actual_stack="$(aws_source ec2 describe-vpc-peering-connections \
    --vpc-peering-connection-ids "$peering_id" \
    --query "VpcPeeringConnections[0].Tags[?Key=='Stack'] | [0].Value" \
    --output text)"
  actual_managed_by="$(aws_source ec2 describe-vpc-peering-connections \
    --vpc-peering-connection-ids "$peering_id" \
    --query "VpcPeeringConnections[0].Tags[?Key=='ManagedBy'] | [0].Value" \
    --output text)"
  if [ "$actual_stack" != "$STACK_NAME" ] || [ "$actual_managed_by" != "$MANAGED_BY" ]; then
    die "VPC peering $peering_id connects the source and target VPCs but is not managed by stack $STACK_NAME"
  fi
  printf '%s\n' "$peering_id"
}
wait_for_peering_active() {
  local status attempt=0
  while [ "$attempt" -lt 60 ]; do
    status="$(aws_source ec2 describe-vpc-peering-connections \
      --vpc-peering-connection-ids "$PEERING_ID" \
      --query 'VpcPeeringConnections[0].Status.Code' \
      --output text)"
    [ "$status" = "active" ] && return 0
    if [ "$status" = "pending-acceptance" ]; then
      aws_target ec2 accept-vpc-peering-connection \
        --vpc-peering-connection-id "$PEERING_ID" >/dev/null
    fi
    case "$status" in
      failed|rejected|expired|deleted) return 1 ;;
    esac
    sleep 5
    attempt=$((attempt + 1))
  done
  return 1
}

ensure_peering() {
  PEERING_ID="$(find_peering_id)"
  if [ -z "$PEERING_ID" ]; then
    log "Creating inter-region VPC peering: $SOURCE_REGION -> $TARGET_REGION"
    PEERING_ID="$(aws_source ec2 create-vpc-peering-connection \
      --vpc-id "$SOURCE_VPC_ID" \
      --peer-vpc-id "$TARGET_VPC_ID" \
      --peer-region "$TARGET_REGION" \
      --query 'VpcPeeringConnection.VpcPeeringConnectionId' \
      --output text)"
    aws_source ec2 create-tags \
      --resources "$PEERING_ID" \
      --tags \
        "Key=Name,Value=$STACK_NAME-peering" \
        "Key=Project,Value=$PROJECT_TAG" \
        "Key=Stack,Value=$STACK_NAME" \
        "Key=ManagedBy,Value=$MANAGED_BY" >/dev/null
  else
    log "VPC peering: reusing $PEERING_ID"
  fi

  run_with_progress "waiting for VPC peering activation" wait_for_peering_active || \
    die "VPC peering $PEERING_ID did not become active"

  ensure_route "$SOURCE_REGION" "$SOURCE_ROUTE_TABLE_ID" "$TARGET_VPC_CIDR" pcx "$PEERING_ID"
  ensure_route "$TARGET_REGION" "$TARGET_ROUTE_TABLE_ID" "$SOURCE_VPC_CIDR" pcx "$PEERING_ID"
}
resolve_latest_debian_ami() {
  local existing_instance root_volume_id existing_volume

  resolve_debian_ami "$AWS_PROFILE" "$TARGET_REGION" "$DEBIAN_RELEASE" "$DEBIAN_OWNER_ID" "$ARCHITECTURE"
  [ -z "$ROOT_VOLUME_SIZE_OVERRIDE" ] || ROOT_VOLUME_SIZE="$ROOT_VOLUME_SIZE_OVERRIDE"
  validate_positive_integer "$ROOT_VOLUME_SIZE" "ROOT_VOLUME_SIZE_GIB"

  existing_instance="$(find_target_instance_id)"
  if [ -n "$existing_instance" ]; then
    root_volume_id="$(aws_target ec2 describe-instances \
      --instance-ids "$existing_instance" \
      --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
      --output text)"
    if ! is_none "$root_volume_id"; then
      existing_volume="$(aws_target ec2 describe-volumes \
        --volume-ids "$root_volume_id" \
        --query 'Volumes[0].VolumeType' \
        --output text)"
      ROOT_VOLUME_TYPE="$existing_volume"
      VOLUME_TYPE_CANDIDATES="$existing_volume"
    fi
  elif [ "$ROOT_VOLUME_TYPE_REQUEST" = "auto" ]; then
    VOLUME_TYPE_AUTO=1
    if [ "$ZONE_TYPE" = "local-zone" ]; then
      ROOT_VOLUME_TYPE="gp2"
      VOLUME_TYPE_CANDIDATES="gp2 gp3"
    else
      ROOT_VOLUME_TYPE="gp3"
      VOLUME_TYPE_CANDIDATES="gp3 gp2"
    fi
  else
    ROOT_VOLUME_TYPE="$ROOT_VOLUME_TYPE_REQUEST"
    VOLUME_TYPE_CANDIDATES="$ROOT_VOLUME_TYPE_REQUEST"
  fi

  detail "AMI: $AMI_ID ($AMI_NAME)"
  detail "Recommended root volume: ${ROOT_VOLUME_SIZE} GiB $ROOT_VOLUME_TYPE"
}

select_instance_type() {
  local specs_file requested_line existing_instance existing_type

  existing_instance="$(find_target_instance_id)"
  if [ -n "$existing_instance" ]; then
    existing_type="$(aws_target ec2 describe-instances \
      --instance-ids "$existing_instance" \
      --query 'Reservations[0].Instances[0].InstanceType' \
      --output text)"
    if [ "$INSTANCE_TYPE_REQUEST" != "auto" ] && [ "$INSTANCE_TYPE_REQUEST" != "$existing_type" ]; then
      die "existing instance uses $existing_type, requested $INSTANCE_TYPE_REQUEST"
    fi
    INSTANCE_TYPE="$existing_type"
    INSTANCE_TYPE_CANDIDATES="$existing_type"
    detail "Instance type: reusing existing $INSTANCE_TYPE"
    return 0
  fi

  specs_file="$(new_temp_file aws-route-edge-types.XXXXXX)"
  load_instance_candidates "$AWS_PROFILE" "$TARGET_REGION" "$TARGET_AZ" "$ARCHITECTURE" \
    "$MIN_VCPUS" "$MIN_MEMORY_MIB" "$specs_file"

  if [ "$INSTANCE_TYPE_REQUEST" = "auto" ]; then
    INSTANCE_TYPE_AUTO=1
    INSTANCE_TYPE="$(awk 'NR==1 {print $1}' "$specs_file")"
    INSTANCE_TYPE_CANDIDATES="$(instance_candidate_names "$specs_file" 10)"
  else
    requested_line="$(awk -v requested="$INSTANCE_TYPE_REQUEST" '$1 == requested {print; exit}' "$specs_file")"
    [ -n "$requested_line" ] || \
      die "$INSTANCE_TYPE_REQUEST is not offered in $TARGET_AZ or does not satisfy the requested architecture/resources"
    INSTANCE_TYPE="$INSTANCE_TYPE_REQUEST"
    INSTANCE_TYPE_CANDIDATES="$INSTANCE_TYPE_REQUEST"
  fi

  detail "Recommended instance offerings:"
  print_instance_candidates "$specs_file" 6
}

ensure_target_key_pair() {
  ensure_key_pair_for_region "$AWS_PROFILE" "$TARGET_REGION" "$KEY_NAME" "$PEM_PATH"
}

ensure_target_security_group() {
  local ids ingress_cidrs egress_cidrs actual_stack actual_managed_by
  ids="$(aws_target ec2 describe-security-groups \
    --filters \
      "Name=vpc-id,Values=$TARGET_VPC_ID" \
      "Name=group-name,Values=$TARGET_SECURITY_GROUP_NAME" \
    --query 'SecurityGroups[].GroupId' \
    --output text)"
  TARGET_SECURITY_GROUP_ID="$(get_single_id "target security groups" "$ids")"

  if [ -z "$TARGET_SECURITY_GROUP_ID" ]; then
    log "Creating target security group"
    TARGET_SECURITY_GROUP_ID="$(aws_target ec2 create-security-group \
      --group-name "$TARGET_SECURITY_GROUP_NAME" \
      --description "Temporary route edge node" \
      --vpc-id "$TARGET_VPC_ID" \
      --tag-specifications \
        "ResourceType=security-group,Tags=[{Key=Name,Value=$TARGET_SECURITY_GROUP_NAME},{Key=Project,Value=$PROJECT_TAG},{Key=Role,Value=$ROLE_TAG},{Key=Stack,Value=$STACK_NAME},{Key=ManagedBy,Value=$MANAGED_BY}]" \
      --query GroupId \
      --output text)"
  else
    actual_stack="$(aws_target ec2 describe-security-groups \
      --group-ids "$TARGET_SECURITY_GROUP_ID" \
      --query "SecurityGroups[0].Tags[?Key=='Stack'] | [0].Value" \
      --output text)"
    actual_managed_by="$(aws_target ec2 describe-security-groups \
      --group-ids "$TARGET_SECURITY_GROUP_ID" \
      --query "SecurityGroups[0].Tags[?Key=='ManagedBy'] | [0].Value" \
      --output text)"
    if [ "$actual_stack" != "$STACK_NAME" ] || [ "$actual_managed_by" != "$MANAGED_BY" ]; then
      die "security group $TARGET_SECURITY_GROUP_NAME exists but is not managed by stack $STACK_NAME ($TARGET_SECURITY_GROUP_ID)"
    fi
    log "Target security group: reusing $TARGET_SECURITY_GROUP_ID"
  fi

  ingress_cidrs="$(aws_target ec2 describe-security-groups \
    --group-ids "$TARGET_SECURITY_GROUP_ID" \
    --query "SecurityGroups[0].IpPermissions[?IpProtocol=='-1'].IpRanges[].CidrIp" \
    --output text | tr '\t' ' ')"
  case " $ingress_cidrs " in
    *" $INGRESS_CIDR "*) ;;
    *)
      aws_target ec2 authorize-security-group-ingress \
        --group-id "$TARGET_SECURITY_GROUP_ID" \
        --ip-permissions \
          "IpProtocol=-1,IpRanges=[{CidrIp=$INGRESS_CIDR,Description='TEMP route testing'}]" >/dev/null
      ;;
  esac

  egress_cidrs="$(aws_target ec2 describe-security-groups \
    --group-ids "$TARGET_SECURITY_GROUP_ID" \
    --query "SecurityGroups[0].IpPermissionsEgress[?IpProtocol=='-1'].IpRanges[].CidrIp" \
    --output text | tr '\t' ' ')"
  case " $egress_cidrs " in
    *" 0.0.0.0/0 "*) ;;
    *)
      aws_target ec2 authorize-security-group-egress \
        --group-id "$TARGET_SECURITY_GROUP_ID" \
        --ip-permissions \
          "IpProtocol=-1,IpRanges=[{CidrIp=0.0.0.0/0,Description='Edge node egress'}]" >/dev/null
      ;;
  esac
}

find_target_instance_id() {
  local ids
  ids="$(aws_target ec2 describe-instances \
    --filters \
      "Name=tag:Name,Values=$TARGET_INSTANCE_NAME" \
      "Name=tag:Stack,Values=$STACK_NAME" \
      "Name=tag:ManagedBy,Values=$MANAGED_BY" \
      Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text)"
  get_single_id "target instances" "$ids"
}

run_target_instance_request() {
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
    --subnet-id "$TARGET_SUBNET_ID"
    --security-group-ids "$TARGET_SECURITY_GROUP_ID"
    --no-associate-public-ip-address
    --metadata-options HttpTokens=required,HttpEndpoint=enabled
    --client-token "$client_token"
    --block-device-mappings "DeviceName=$ROOT_DEVICE_NAME,Ebs={VolumeSize=$ROOT_VOLUME_SIZE,VolumeType=$volume_type,DeleteOnTermination=true}"
    --tag-specifications
      "ResourceType=instance,Tags=[{Key=Name,Value=$TARGET_INSTANCE_NAME},{Key=Project,Value=$PROJECT_TAG},{Key=Role,Value=$ROLE_TAG},{Key=Stack,Value=$STACK_NAME},{Key=ManagedBy,Value=$MANAGED_BY}]"
      "ResourceType=volume,Tags=[{Key=Name,Value=${TARGET_INSTANCE_NAME}-root},{Key=Project,Value=$PROJECT_TAG},{Key=Role,Value=$ROLE_TAG},{Key=Stack,Value=$STACK_NAME},{Key=ManagedBy,Value=$MANAGED_BY}]"
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
  aws_target "${args[@]}"
}

launch_target_instance() {
  local instance_type volume_type output token attempt recovered capacity_failure last_error
  last_error=""

  for instance_type in $INSTANCE_TYPE_CANDIDATES; do
    capacity_failure=0
    for volume_type in $VOLUME_TYPE_CANDIDATES; do
      token="$(make_client_token "$TARGET_REGION/$TARGET_AZ/$STACK_NAME/$instance_type/$volume_type")"
      if output="$(trap - ERR; run_target_instance_request "$instance_type" "$volume_type" "$token" 1 2>&1)"; then
        die "launch preflight unexpectedly succeeded without DryRunOperation for $instance_type + $volume_type"
      else
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
      fi

      log "launching $instance_type with ${ROOT_VOLUME_SIZE} GiB $volume_type"
      attempt=1
      while [ "$attempt" -le 3 ]; do
        if output="$(trap - ERR; run_target_instance_request "$instance_type" "$volume_type" "$token" 0 2>&1)"; then
          TARGET_INSTANCE_ID="$output"
          INSTANCE_TYPE="$instance_type"
          ROOT_VOLUME_TYPE="$volume_type"
          return 0
        fi

        recovered="$(find_target_instance_id)"
        if [ -n "$recovered" ]; then
          warn "launch response was incomplete, but managed instance $recovered exists; continuing"
          TARGET_INSTANCE_ID="$recovered"
          INSTANCE_TYPE="$instance_type"
          ROOT_VOLUME_TYPE="$volume_type"
          return 0
        fi

        last_error="$(short_error "$output")"
        if is_capacity_error "$output"; then
          warn "$instance_type has insufficient capacity in $TARGET_AZ; trying the next candidate"
          capacity_failure=1
          break
        fi
        if is_volume_error "$output"; then
          warn "$volume_type is not usable in $TARGET_AZ; trying another volume type"
          break
        fi
        if is_retryable_aws_error "$output" && [ "$attempt" -lt 3 ]; then
          warn "temporary AWS error; retrying the same idempotent launch ($attempt/3)"
          sleep $((attempt * 3))
          attempt=$((attempt + 1))
          continue
        fi
        die "target instance launch failed: $last_error"
      done
      [ "$capacity_failure" -eq 0 ] || break
    done
  done

  die "no launch candidate succeeded in $TARGET_AZ. Last error: ${last_error:-unknown}"
}

ensure_target_instance() {
  local state actual_vpc actual_subnet actual_key actual_type attached_groups
  TARGET_INSTANCE_ID="$(find_target_instance_id)"

  if [ -z "$TARGET_INSTANCE_ID" ]; then
    launch_target_instance
  else
    detail "Target instance: reusing $TARGET_INSTANCE_ID"
  fi

  actual_vpc="$(aws_target ec2 describe-instances --instance-ids "$TARGET_INSTANCE_ID" --query 'Reservations[0].Instances[0].VpcId' --output text)"
  actual_subnet="$(aws_target ec2 describe-instances --instance-ids "$TARGET_INSTANCE_ID" --query 'Reservations[0].Instances[0].SubnetId' --output text)"
  actual_key="$(aws_target ec2 describe-instances --instance-ids "$TARGET_INSTANCE_ID" --query 'Reservations[0].Instances[0].KeyName' --output text)"
  actual_type="$(aws_target ec2 describe-instances --instance-ids "$TARGET_INSTANCE_ID" --query 'Reservations[0].Instances[0].InstanceType' --output text)"
  attached_groups="$(aws_target ec2 describe-instances --instance-ids "$TARGET_INSTANCE_ID" --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' --output text)"
  [ "$actual_vpc" = "$TARGET_VPC_ID" ] || die "target instance VPC mismatch: $actual_vpc"
  [ "$actual_subnet" = "$TARGET_SUBNET_ID" ] || die "target instance subnet mismatch: $actual_subnet"
  [ "$actual_key" = "$KEY_NAME" ] || die "target instance key mismatch: $actual_key"
  [ "$actual_type" = "$INSTANCE_TYPE" ] || die "target instance type mismatch: $actual_type"
  case " $attached_groups " in
    *" $TARGET_SECURITY_GROUP_ID "*) ;;
    *) die "target instance security group mismatch: $attached_groups" ;;
  esac

  state="$(aws_target ec2 describe-instances --instance-ids "$TARGET_INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name' --output text)"
  if [ "$state" = "stopping" ]; then
    run_with_progress "waiting for target instance to stop" \
      aws_target ec2 wait instance-stopped --instance-ids "$TARGET_INSTANCE_ID" || \
      die "$TARGET_INSTANCE_ID did not stop"
    state="stopped"
  fi
  if [ "$state" = "stopped" ]; then
    aws_target ec2 start-instances --instance-ids "$TARGET_INSTANCE_ID" >/dev/null
  fi
  run_with_progress "waiting for target instance state running" \
    aws_target ec2 wait instance-running --instance-ids "$TARGET_INSTANCE_ID" || \
    die "$TARGET_INSTANCE_ID did not reach running state"
  run_with_progress "waiting for target EC2 status checks" \
    aws_target ec2 wait instance-status-ok --instance-ids "$TARGET_INSTANCE_ID" || \
    die "$TARGET_INSTANCE_ID status checks did not become healthy"
}

ensure_target_eip() {
  local ids associated_instance actual_border_group
  ids="$(aws_target ec2 describe-addresses \
    --filters \
      "Name=tag:Stack,Values=$STACK_NAME" \
      "Name=tag:ManagedBy,Values=$MANAGED_BY" \
    --query 'Addresses[].AllocationId' \
    --output text)"
  EIP_ALLOCATION_ID="$(get_single_id "target Elastic IPs" "$ids")"

  if [ -z "$EIP_ALLOCATION_ID" ]; then
    log "Allocating Elastic IP in network border group $NETWORK_BORDER_GROUP"
    EIP_ALLOCATION_ID="$(aws_target ec2 allocate-address \
      --domain vpc \
      --network-border-group "$NETWORK_BORDER_GROUP" \
      --tag-specifications \
        "ResourceType=elastic-ip,Tags=[{Key=Name,Value=$STACK_NAME-eip},{Key=Project,Value=$PROJECT_TAG},{Key=Role,Value=$ROLE_TAG},{Key=Stack,Value=$STACK_NAME},{Key=ManagedBy,Value=$MANAGED_BY}]" \
      --query AllocationId \
      --output text)"
  else
    log "Elastic IP: reusing $EIP_ALLOCATION_ID"
  fi

  actual_border_group="$(aws_target ec2 describe-addresses \
    --allocation-ids "$EIP_ALLOCATION_ID" \
    --query 'Addresses[0].NetworkBorderGroup' \
    --output text)"
  [ "$actual_border_group" = "$NETWORK_BORDER_GROUP" ] || die "EIP network border group mismatch: $actual_border_group"

  associated_instance="$(aws_target ec2 describe-addresses \
    --allocation-ids "$EIP_ALLOCATION_ID" \
    --query 'Addresses[0].InstanceId' \
    --output text)"
  if is_none "$associated_instance"; then
    aws_target ec2 associate-address \
      --allocation-id "$EIP_ALLOCATION_ID" \
      --instance-id "$TARGET_INSTANCE_ID" >/dev/null
  elif [ "$associated_instance" != "$TARGET_INSTANCE_ID" ]; then
    die "EIP $EIP_ALLOCATION_ID is associated with $associated_instance"
  fi

  TARGET_PUBLIC_IP="$(aws_target ec2 describe-addresses \
    --allocation-ids "$EIP_ALLOCATION_ID" \
    --query 'Addresses[0].PublicIp' \
    --output text)"
}

show_status() {
  local vpc_id instance_id eip_allocation
  vpc_id="$(find_target_vpc_id)"
  instance_id="$(find_target_instance_id)"
  eip_allocation="$(aws_target ec2 describe-addresses \
    --filters \
      "Name=tag:Stack,Values=$STACK_NAME" \
      "Name=tag:ManagedBy,Values=$MANAGED_BY" \
    --query 'Addresses[0].AllocationId' \
    --output text)"

  log "Stack=$STACK_NAME Region=$TARGET_REGION AZ=$TARGET_AZ VPC=${vpc_id:-None} Instance=${instance_id:-None} EIP=${eip_allocation:-None}"
  if [ -n "$instance_id" ]; then
    aws_target ec2 describe-instances \
      --instance-ids "$instance_id" \
      --query 'Reservations[0].Instances[0].{ID:InstanceId,AMI:ImageId,Type:InstanceType,AZ:Placement.AvailabilityZone,State:State.Name,PrivateIP:PrivateIpAddress,VPC:VpcId,Subnet:SubnetId,Key:KeyName,SecurityGroups:SecurityGroups[].GroupId}' \
      --output table
    TARGET_PRIVATE_IP="$(aws_target ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
    if ! is_none "$eip_allocation"; then
      TARGET_PUBLIC_IP="$(aws_target ec2 describe-addresses --allocation-ids "$eip_allocation" --query 'Addresses[0].PublicIp' --output text)"
      log "SSH: ssh -i '$PEM_PATH' admin@$TARGET_PUBLIC_IP"
    fi
    if [ -n "${SOURCE_PRIVATE_IP:-}" ]; then
      log "From source EC2: ping -c 4 $TARGET_PRIVATE_IP"
      log "From target EC2: ping -c 4 $SOURCE_PRIVATE_IP"
    fi
  fi
}

delete_security_group_with_retry() {
  local group_id="$1"
  local output i=0
  while [ "$i" -lt 12 ]; do
    if output="$(aws_target ec2 delete-security-group --group-id "$group_id" 2>&1)"; then
      log "Deleted security group: $group_id"
      return 0
    fi
    case "$output" in
      *DependencyViolation*) sleep 5 ;;
      *) die "Could not delete security group $group_id: $output" ;;
    esac
    i=$((i + 1))
  done
  die "Security group still has dependencies: $group_id"
}

retry_target_delete() {
  local label="$1"
  shift
  local output i=0

  while [ "$i" -lt 18 ]; do
    if output="$(aws_target "$@" 2>&1)"; then
      log "$label"
      return 0
    fi
    case "$output" in
      *DependencyViolation*|*IncorrectState*|*currently\ in\ use*) sleep 5 ;;
      *NotFound*|*NotAttached*|*does\ not\ exist*) return 0 ;;
      *) die "$label failed: $output" ;;
    esac
    i=$((i + 1))
  done
  die "$label still has dependencies after waiting"
}

wait_for_peering_deleted() {
  local peering_id="$1"
  local status i=0

  while [ "$i" -lt 30 ]; do
    status="$(aws_source ec2 describe-vpc-peering-connections \
      --vpc-peering-connection-ids "$peering_id" \
      --query 'VpcPeeringConnections[0].Status.Code' \
      --output text 2>/dev/null || true)"
    if is_none "$status" || [ "$status" = "deleted" ]; then
      return 0
    fi
    sleep 2
    i=$((i + 1))
  done
  die "VPC peering $peering_id did not reach deleted state"
}

delete_stack() {
  local instance_id allocation_ids association_ids volume_ids target_sg_ids
  local target_vpc_id target_vpc_cidr target_route_table_ids target_subnet_ids target_igw_ids peering_id peering_ids
  local source_route_table_ids source_vpc_id source_vpc_cidr source_region_from_peering
  local peering_stack peering_managed_by

  resolve_source_network optional || true
  source_vpc_id="${SOURCE_VPC_ID:-}"
  source_vpc_cidr="${SOURCE_VPC_CIDR:-}"
  target_vpc_id="$(find_target_vpc_id)"
  instance_id="$(find_target_instance_id)"

  if [ -n "$instance_id" ]; then
    log "Terminating target instance: $instance_id"
    aws_target ec2 terminate-instances --instance-ids "$instance_id" >/dev/null
    run_with_progress "waiting for target instance termination" \
      aws_target ec2 wait instance-terminated --instance-ids "$instance_id" || \
      die "target instance termination did not finish"
  fi

  allocation_ids="$(aws_target ec2 describe-addresses \
    --filters \
      "Name=tag:Stack,Values=$STACK_NAME" \
      "Name=tag:ManagedBy,Values=$MANAGED_BY" \
    --query 'Addresses[].AllocationId' \
    --output text)"
  for allocation_id in $allocation_ids; do
    association_id="$(aws_target ec2 describe-addresses --allocation-ids "$allocation_id" --query 'Addresses[0].AssociationId' --output text)"
    if ! is_none "$association_id"; then
      aws_target ec2 disassociate-address --association-id "$association_id"
    fi
    aws_target ec2 release-address --allocation-id "$allocation_id"
    log "Released Elastic IP: $allocation_id"
  done

  volume_ids="$(aws_target ec2 describe-volumes \
    --filters \
      "Name=tag:Stack,Values=$STACK_NAME" \
      "Name=tag:ManagedBy,Values=$MANAGED_BY" \
      Name=status,Values=available \
    --query 'Volumes[].VolumeId' \
    --output text)"
  for volume_id in $volume_ids; do
    aws_target ec2 delete-volume --volume-id "$volume_id"
  done

  target_sg_ids="$(aws_target ec2 describe-security-groups \
    --filters \
      "Name=tag:Stack,Values=$STACK_NAME" \
      "Name=tag:ManagedBy,Values=$MANAGED_BY" \
    --query 'SecurityGroups[].GroupId' \
    --output text)"
  for group_id in $target_sg_ids; do
    delete_security_group_with_retry "$group_id"
  done

  if [ -n "$target_vpc_id" ]; then
    target_vpc_cidr="$(aws_target ec2 describe-vpcs --vpc-ids "$target_vpc_id" --query 'Vpcs[0].CidrBlock' --output text)"
    TARGET_VPC_ID="$target_vpc_id"
    peering_ids="$(aws_target ec2 describe-vpc-peering-connections \
      --filters \
        "Name=accepter-vpc-info.vpc-id,Values=$target_vpc_id" \
        Name=status-code,Values=initiating-request,pending-acceptance,provisioning,active \
      --query 'VpcPeeringConnections[].VpcPeeringConnectionId' \
      --output text)"
    peering_id="$(get_single_id "target VPC peering connections" "$peering_ids")"

    target_route_table_ids="$(aws_target ec2 describe-route-tables \
      --filters \
        "Name=tag:Stack,Values=$STACK_NAME" \
        "Name=tag:ManagedBy,Values=$MANAGED_BY" \
      --query 'RouteTables[].RouteTableId' \
      --output text)"

    if [ -n "$peering_id" ]; then
      source_vpc_id="$(aws_target ec2 describe-vpc-peering-connections \
        --vpc-peering-connection-ids "$peering_id" \
        --query 'VpcPeeringConnections[0].RequesterVpcInfo.VpcId' \
        --output text)"
      source_vpc_cidr="$(aws_target ec2 describe-vpc-peering-connections \
        --vpc-peering-connection-ids "$peering_id" \
        --query 'VpcPeeringConnections[0].RequesterVpcInfo.CidrBlock' \
        --output text)"
      source_region_from_peering="$(aws_target ec2 describe-vpc-peering-connections \
        --vpc-peering-connection-ids "$peering_id" \
        --query 'VpcPeeringConnections[0].RequesterVpcInfo.Region' \
        --output text)"
      if ! is_none "$source_region_from_peering" && [ "$source_region_from_peering" != "$SOURCE_REGION" ]; then
        warn "peering requester is in $source_region_from_peering; overriding SOURCE_REGION=$SOURCE_REGION for deletion"
        SOURCE_REGION="$source_region_from_peering"
      fi
      peering_stack="$(aws_source ec2 describe-vpc-peering-connections \
        --vpc-peering-connection-ids "$peering_id" \
        --query "VpcPeeringConnections[0].Tags[?Key=='Stack'] | [0].Value" \
        --output text)"
      peering_managed_by="$(aws_source ec2 describe-vpc-peering-connections \
        --vpc-peering-connection-ids "$peering_id" \
        --query "VpcPeeringConnections[0].Tags[?Key=='ManagedBy'] | [0].Value" \
        --output text)"
      if [ "$peering_stack" != "$STACK_NAME" ] || [ "$peering_managed_by" != "$MANAGED_BY" ]; then
        die "refusing to delete unmanaged VPC peering $peering_id"
      fi
    fi

    if [ -n "$peering_id" ] && [ -n "${SOURCE_ROUTE_TABLE_ID:-}" ]; then
      delete_route_if_matches "$SOURCE_REGION" "$SOURCE_ROUTE_TABLE_ID" \
        "$target_vpc_cidr" VpcPeeringConnectionId "$peering_id"
    fi

    if [ -n "$peering_id" ] && [ -n "$source_vpc_cidr" ]; then
      for route_table_id in $target_route_table_ids; do
        delete_route_if_matches "$TARGET_REGION" "$route_table_id" "$source_vpc_cidr" VpcPeeringConnectionId "$peering_id"
      done
    fi

    if [ -n "$peering_id" ]; then
      aws_target ec2 delete-vpc-peering-connection --vpc-peering-connection-id "$peering_id" >/dev/null
      run_with_progress "waiting for VPC peering deletion" wait_for_peering_deleted "$peering_id" || \
        die "VPC peering $peering_id did not reach deleted state"
      log "Deleted VPC peering: $peering_id"
    fi

    for route_table_id in $target_route_table_ids; do
      association_ids="$(aws_target ec2 describe-route-tables \
        --route-table-ids "$route_table_id" \
        --query 'RouteTables[0].Associations[?Main!=`true`].RouteTableAssociationId' \
        --output text)"
      for association_id in $association_ids; do
        aws_target ec2 disassociate-route-table --association-id "$association_id"
      done
      retry_target_delete "Deleted route table: $route_table_id" \
        ec2 delete-route-table --route-table-id "$route_table_id"
    done

    target_subnet_ids="$(aws_target ec2 describe-subnets \
      --filters \
        "Name=tag:Stack,Values=$STACK_NAME" \
        "Name=tag:ManagedBy,Values=$MANAGED_BY" \
      --query 'Subnets[].SubnetId' \
      --output text)"
    for subnet_id in $target_subnet_ids; do
      retry_target_delete "Deleted subnet: $subnet_id" \
        ec2 delete-subnet --subnet-id "$subnet_id"
    done

    target_igw_ids="$(aws_target ec2 describe-internet-gateways \
      --filters \
        "Name=tag:Stack,Values=$STACK_NAME" \
        "Name=tag:ManagedBy,Values=$MANAGED_BY" \
      --query 'InternetGateways[].InternetGatewayId' \
      --output text)"
    for igw_id in $target_igw_ids; do
      retry_target_delete "Detached internet gateway: $igw_id" \
        ec2 detach-internet-gateway --internet-gateway-id "$igw_id" --vpc-id "$target_vpc_id"
      retry_target_delete "Deleted internet gateway: $igw_id" \
        ec2 delete-internet-gateway --internet-gateway-id "$igw_id"
    done

    retry_target_delete "Deleted target VPC: $target_vpc_id" \
      ec2 delete-vpc --vpc-id "$target_vpc_id"
  fi

  log "Preserved source EC2/VPC, Lightsail peering, target zone opt-in, regional key pair, and local PEM"
}

customize_launch_plan() {
  local selected_type selected_volume specs_file existing_instance

  existing_instance="$(find_target_instance_id)"
  if [ -n "$existing_instance" ]; then
    warn "the existing target instance will be reused; its instance and root volume types cannot be changed by create"
    return 0
  fi

  specs_file="$(new_temp_file aws-route-edge-custom-types.XXXXXX)"
  load_instance_candidates "$AWS_PROFILE" "$TARGET_REGION" "$TARGET_AZ" "$ARCHITECTURE" \
    "$MIN_VCPUS" "$MIN_MEMORY_MIB" "$specs_file"
  printf '\nAvailable recommendations:\n'
  print_instance_candidates "$specs_file" 8

  selected_type="$(prompt_with_default "Instance type" "$INSTANCE_TYPE")"
  if ! awk -v requested="$selected_type" '$1 == requested {found=1} END {exit !found}' "$specs_file"; then
    die "$selected_type is not an eligible offering in $TARGET_AZ"
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
  detail "Source: $SOURCE_INSTANCE_ID in $SOURCE_REGION ($SOURCE_VPC_CIDR)"
  detail "Target: $TARGET_REGION / $TARGET_AZ ($ZONE_TYPE)"
  detail "Network: $TARGET_VPC_CIDR, subnet $TARGET_SUBNET_CIDR"
  detail "Peering: source VPC $SOURCE_VPC_ID <-> target stack $STACK_NAME"
  detail "Launch: $INSTANCE_TYPE, ${ROOT_VOLUME_SIZE} GiB $ROOT_VOLUME_TYPE"
  detail "Elastic IP border group: $NETWORK_BORDER_GROUP"
  detail "Inbound: all protocols from $INGRESS_CIDR"
  [ "$ZONE_OPT_IN" != "not-opted-in" ] || detail "The zone group $ZONE_GROUP will be opted in"
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

create_stack() {
  set_step_total 12
  step "Resolve the Singapore source network"
  resolve_source_network
  step "Inspect the target zone and choose non-overlapping CIDRs"
  inspect_target_zone
  resolve_create_cidrs
  step "Resolve AMI, instance, and EBS candidates"
  resolve_latest_debian_ami
  select_instance_type
  step "Confirm the creation plan"
  confirm_create_plan
  step "Ensure target zone opt-in"
  ensure_target_zone
  step "Ensure target VPC and subnet"
  ensure_target_vpc
  ensure_target_subnet
  step "Ensure internet gateway and route table"
  ensure_target_igw
  ensure_target_route_table
  step "Ensure inter-region VPC peering and routes"
  ensure_peering
  step "Ensure SSH key pair and security group"
  ensure_target_key_pair
  ensure_target_security_group
  step "Create or start the target EC2 instance"
  ensure_target_instance
  step "Allocate and associate the target Elastic IP"
  ensure_target_eip
  step "Show final status"
  show_status
}

show_help() {
  cat <<EOF
Usage:
  $0 create [TARGET_REGION [TARGET_AZ [TARGET_VPC_CIDR TARGET_SUBNET_CIDR]]] [--yes]
  $0 status TARGET_REGION TARGET_AZ
  $0 delete TARGET_REGION TARGET_AZ [--yes]

Interactive create asks only for a target Region and AZ when they are omitted.
CIDRs are selected automatically from unused 10.x.0.0/16 space. Existing stacks
reuse their current network. All four legacy positional parameters remain valid.

Optional environment overrides:
  AWS_PROFILE=$AWS_PROFILE
  SOURCE_REGION=$SOURCE_REGION
  SOURCE_INSTANCE_NAME=$SOURCE_INSTANCE_NAME
  SOURCE_ROLE_TAG=$SOURCE_ROLE_TAG
  SOURCE_MANAGED_BY=$SOURCE_MANAGED_BY
  INSTANCE_TYPE=auto
  MIN_VCPUS=$MIN_VCPUS
  MIN_MEMORY_MIB=$MIN_MEMORY_MIB
  ROOT_VOLUME_TYPE=auto
  ROOT_VOLUME_SIZE_GIB=
  DEBIAN_RELEASE=$DEBIAN_RELEASE
  KEY_NAME=$KEY_NAME
  PEM_PATH=$PEM_PATH
  INGRESS_CIDR=$INGRESS_CIDR
  AUTO_APPROVE=1
  INTERACTIVE=0

Lagos example:
  PEM_PATH=\$HOME/Downloads/aws-route.pem \\
    $0 create af-south-1 af-south-1-los-1a

Europe example:
  PEM_PATH=\$HOME/Downloads/aws-route.pem \\
    $0 create eu-west-1 eu-west-1a
EOF
}

main() {
  case "$ACTION" in
    help|-h|--help)
      show_help
      return 0
      ;;
  esac

  require_commands
  resolve_target_inputs
  require_target_identity
  acquire_lock "aws-route-edge-$AWS_PROFILE-$TARGET_REGION-$STACK_NAME"

  case "$ACTION" in
    create)
      verify_identity
      create_stack
      ;;
    status)
      set_step_total 2
      step "Verify AWS identity"
      verify_identity
      step "Show target stack status"
      show_status
      ;;
    delete)
      set_step_total 3
      step "Verify AWS identity"
      verify_identity
      step "Confirm deletion"
      detail "Stack: $STACK_NAME"
      detail "Target: $TARGET_REGION / $TARGET_AZ"
      confirm_action "Delete the target EC2, EIP, peering, and managed target VPC?" no || die "operation cancelled"
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
