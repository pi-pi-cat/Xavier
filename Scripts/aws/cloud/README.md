# 云资源脚本说明

本目录负责通过 AWS CLI 创建、查询和删除 AWS 云资源。第一次使用请先阅读上级目录的[最短执行顺序](../README.md)。

## 文件

```text
cloud/
├── aws-route-common.sh       # 公共 AWS CLI、CIDR、AMI 和实例选择函数
├── aws-route-ec2-sg.sh       # 新加坡中转 EC2
└── aws-route-edge-node.sh    # 跨区域落地节点与网络
```

`aws-route-common.sh` 是公共库，不应单独执行。

## 前置条件

- Bash、AWS CLI 和 `ssh-keygen`。
- 已配置可用的 AWS Profile。
- AWS 身份有权操作 STS、EC2、VPC、Elastic IP、VPC Peering 和 Lightsail Peering。
- 目标区域或 Local Zone 已允许当前账号使用。

```bash
aws login --profile personal
aws sts get-caller-identity --profile personal
```

## 新加坡中转 EC2

`aws-route-ec2-sg.sh` 在 Lightsail 所在的新加坡区域创建或复用一台中转 EC2，并确保 Lightsail VPC Peering 已启用。

### 直接执行

```bash
PUBLIC_IP="$(curl -fsSL https://checkip.amazonaws.com)"

AWS_PROFILE=personal \
INGRESS_CIDR="${PUBLIC_IP}/32" \
./aws-route-ec2-sg.sh create
```

查看和删除：

```bash
AWS_PROFILE=personal ./aws-route-ec2-sg.sh status
AWS_PROFILE=personal ./aws-route-ec2-sg.sh delete
```

### 自动处理内容

脚本会：

1. 验证 AWS 身份并启用 Lightsail VPC Peering。
2. 解析默认 VPC 和可用默认子网。
3. 查询最新官方 Debian AMI。
4. 查询目标 AZ 实际提供的 x86_64 EC2 机型。
5. 根据 vCPU、内存和实例家族生成小规格候选列表。
6. 依次尝试兼容的 EBS 类型并执行 `run-instances --dry-run`。
7. 容量不足时自动尝试下一种机型。
8. 等待实例运行和健康检查完成。

已有实例通过 `Name`、`Role` 和 `ManagedBy` 标签重新发现。脚本不会接管只有同名但没有管理标签的资源。

### 常用变量

```text
AWS_PROFILE=personal
REGION=ap-southeast-1
AZ=ap-southeast-1a
INSTANCE_TYPE=auto
MIN_VCPUS=1
MIN_MEMORY_MIB=512
ROOT_VOLUME_TYPE=auto
ROOT_VOLUME_SIZE_GIB=
KEY_NAME=aws-route
PEM_PATH=$HOME/.ssh/aws-route.pem
INGRESS_CIDR=可信来源CIDR
AUTO_APPROVE=1
INTERACTIVE=0
```

显式指定机型和磁盘类型：

```bash
INSTANCE_TYPE=t3.micro ROOT_VOLUME_TYPE=gp3 \
  ./aws-route-ec2-sg.sh create
```

## 跨区域落地节点

`aws-route-edge-node.sh` 在目标 Region、标准 AZ 或 Local Zone 创建落地 EC2，并通过跨区域 VPC Peering 连接新加坡中转 VPC。

### 直接执行

Lagos Local Zone：

```bash
SOURCE_VPC_CIDR=172.31.0.0/16 # 替换为中转 VPC CIDR

AWS_PROFILE=personal \
INGRESS_CIDR="$SOURCE_VPC_CIDR" \
./aws-route-edge-node.sh create af-south-1 af-south-1-los-1a
```

欧洲标准 AZ：

```bash
SOURCE_VPC_CIDR=172.31.0.0/16 # 替换为中转 VPC CIDR

AWS_PROFILE=personal \
INGRESS_CIDR="$SOURCE_VPC_CIDR" \
./aws-route-edge-node.sh create eu-west-1 eu-west-1a
```

查看和删除：

```bash
./aws-route-edge-node.sh status af-south-1 af-south-1-los-1a
./aws-route-edge-node.sh delete af-south-1 af-south-1-los-1a
```

### 自动处理内容

脚本会：

1. 定位新加坡源 EC2、VPC、私网 IP 和路由表。
2. 检查目标 Region 与 AZ，自动选择不冲突的 VPC `/16` 和子网 `/24`。
3. 查询目标 AZ 实际可用的 AMI、实例类型和 EBS 类型。
4. 必要时启用 Local Zone group。
5. 创建或复用目标 VPC、子网、Internet Gateway 和路由表。
6. 创建跨区域 VPC Peering 并写入双向路由。
7. 导入区域 SSH Key Pair，创建安全组和 EC2。
8. 在正确的 network border group 分配并绑定 Elastic IP。

已有 stack 会复用原来的 VPC 和子网 CIDR。新 stack 从 `10.20.0.0/16` 开始选择未使用网段。

### 常用变量

```text
AWS_PROFILE=personal
SOURCE_REGION=ap-southeast-1
SOURCE_INSTANCE_NAME=ec2-sg-route
SOURCE_ROLE_TAG=sg-transit
SOURCE_MANAGED_BY=aws-route-script
INSTANCE_TYPE=auto
MIN_VCPUS=1
MIN_MEMORY_MIB=512
ROOT_VOLUME_TYPE=auto
ROOT_VOLUME_SIZE_GIB=
DEBIAN_RELEASE=13
KEY_NAME=aws-route
PEM_PATH=$HOME/.ssh/aws-route.pem
INGRESS_CIDR=中转VPC的CIDR
AUTO_APPROVE=1
INTERACTIVE=0
```

## 安全组说明

两个脚本默认的 `INGRESS_CIDR=0.0.0.0/0` 会开放所有协议，不适合长期使用。

- 新加坡中转 EC2：通常设置为管理员或客户端公网 IP `/32`。
- 落地 EC2：通常设置为新加坡中转 VPC 的 CIDR。
- 落地机公网 SSH 不在上述范围内时，应通过新加坡中转机使用 SSH 跳板访问。

## 删除范围

### 新加坡中转

删除带管理标签的中转 EC2、残留根 EBS 卷和专用安全组。保留：

- 区域 Key Pair 和本地 PEM。
- 默认 VPC、子网和路由表。
- Lightsail VPC Peering。
- 已绑定的 Elastic IP，脚本仅告警。

### 跨区域落地

按依赖顺序删除受管的 EC2、Elastic IP、残留 EBS、安全组、Peering 路由、VPC Peering、路由表、子网、Internet Gateway 和目标 VPC。保留：

- 新加坡源资源。
- 目标 Zone opt-in。
- 区域 Key Pair 和本地 PEM。

删除前应先运行 `status`，确认 AWS 账号、区域、AZ 和资源名称。
