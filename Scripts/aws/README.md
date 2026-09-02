# AWS 跨区域中转与落地节点脚本

更新日期：2026-09-02

这组脚本用于在 AWS 上建立一条可重复创建、检查和清理的跨区域网络链路，并在服务器上部署中转转发与 Shadowsocks 落地服务。

项目将职责拆成两层：

- **云资源层**：通过 AWS CLI 创建新加坡中转 EC2、目标区域落地 EC2、VPC、子网、路由、VPC Peering、Elastic IP 和安全组。
- **服务器层**：在中转机配置 nftables DNAT，在落地机安装 sing-box 并运行 Shadowsocks 服务。

服务器层脚本不会调用 AWS CLI、AWS API 或 EC2 Metadata。安全组、Source/Destination Check 和 VPC 路由仍由云资源脚本或 AWS 控制台负责。

## 链路结构

```text
客户端
  |
  | TCP/UDP 公网访问
  v
新加坡中转 EC2
  |  nftables DNAT + MASQUERADE
  |  跨区域 VPC Peering
  v
目标区域落地 EC2
  |  sing-box Shadowsocks
  v
目标区域互联网出口
```

典型场景是先在新加坡区域创建中转 EC2，再在目标 Region、标准可用区或 Local Zone 创建落地 EC2，最后分别执行服务器配置脚本。

## 目录结构

```text
Scripts/aws/
├── README.md
├── quick-run.sh                  # curl | bash 统一入口
├── cloud/
│   ├── aws-route-common.sh       # AWS CLI 公共函数
│   ├── aws-route-ec2-sg.sh       # 新加坡中转 EC2
│   └── aws-route-edge-node.sh    # 跨区域落地 EC2 与网络
├── server/
│   ├── route-local-common.sh     # 服务器配置公共函数
│   ├── deploy-transit.sh         # 中转机 DNAT
│   └── deploy-landing-ss.sh      # 落地机 sing-box Shadowsocks
└── tests/
    ├── run.sh
    ├── aws-route-common-test.sh
    ├── route-local-test.sh
    └── quick-run-test.sh
```

两个 `common.sh` 都是被其他脚本加载的公共库，不应单独执行。

## 安全须知

1. 云资源脚本的默认 `INGRESS_CIDR=0.0.0.0/0` 会向整个互联网开放所有协议，只适合临时验证。正式使用前必须改成可信来源 CIDR，并在 AWS 安全组中只保留实际需要的端口和协议。
2. `curl | bash` 会直接执行远程代码。长期使用时应将 `AWS_ROUTE_REF` 固定到已审查的 Git commit，而不是一直跟随 `main`。
3. 私有仓库访问令牌只需要目标仓库的 Contents 只读权限，不要使用具有写权限或无关仓库权限的令牌。入口脚本下载完成后会清除令牌，不会把令牌传给 AWS 或服务器部署脚本。
4. 所有创建、安装、删除和重新生成节点等变更操作，通过 `quick-run.sh` 执行时都必须显式加 `--yes` 或设置 `AUTO_APPROVE=1`。
5. 不要提交 PEM、密码、节点链接、凭据文件或生成后的 `ss://` 地址。本目录的 `.gitignore` 已排除常见敏感文件名，但仍应在提交前人工检查。
6. AWS 资源会产生 EC2、EBS、Elastic IP、跨区域流量和 Local Zone 等费用。使用完成后应检查资源状态并执行对应删除命令。
7. 删除脚本只清理带有本项目管理标签的资源，但仍应先运行 `status` 并确认账号、区域和目标名称。

## 前置条件

### 管理机

运行 `cloud/` 脚本需要：

- Bash。
- AWS CLI，并已配置可用的 AWS Profile。
- `ssh-keygen`。
- 有权操作 STS、EC2、VPC、Elastic IP、VPC Peering 和 Lightsail Peering 的 AWS 身份。
- 目标区域和 Local Zone 已允许账号使用；脚本可在需要时尝试启用目标 Zone group。

登录示例：

```bash
aws login --profile personal
aws sts get-caller-identity --profile personal
```

### 中转机和落地机

运行 `server/` 脚本需要：

- Debian 12 或 Debian 13。
- root 权限。
- 可访问 Debian 软件源和 GitHub Releases。
- 中转机已关闭 EC2 Source/Destination Check。
- 中转机和落地机之间的 VPC Peering 与双向路由已经生效。
- 安全组允许选定端口的 TCP 和 UDP 流量。

## 方式一：仓库内直接执行

### 1. 创建新加坡中转 EC2

先限制安全组来源。下面示例只允许当前公网 IPv4：

```bash
cd Scripts/aws/cloud

PUBLIC_IP="$(curl -fsSL https://checkip.amazonaws.com)"
AWS_PROFILE=personal \
INGRESS_CIDR="${PUBLIC_IP}/32" \
./aws-route-ec2-sg.sh create
```

查看状态与删除：

```bash
AWS_PROFILE=personal ./aws-route-ec2-sg.sh status
AWS_PROFILE=personal ./aws-route-ec2-sg.sh delete
```

常用覆盖变量：

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
```

脚本会启用 Lightsail VPC Peering，解析默认 VPC 与子网，选择最新官方 Debian AMI，并根据目标 AZ 实际供应情况尝试小规格实例和可用 EBS 类型。

### 2. 创建跨区域落地 EC2

Lagos Local Zone 示例：

```bash
cd Scripts/aws/cloud

SOURCE_VPC_CIDR=172.31.0.0/16 # 替换为中转 EC2 所在 VPC 的 CIDR

AWS_PROFILE=personal \
INGRESS_CIDR="$SOURCE_VPC_CIDR" \
./aws-route-edge-node.sh create af-south-1 af-south-1-los-1a
```

欧洲标准 AZ 示例：

```bash
SOURCE_VPC_CIDR=172.31.0.0/16 # 替换为中转 EC2 所在 VPC 的 CIDR

AWS_PROFILE=personal \
INGRESS_CIDR="$SOURCE_VPC_CIDR" \
./aws-route-edge-node.sh create eu-west-1 eu-west-1a
```

可以先运行 `aws-route-ec2-sg.sh status`，从输出中的 `CIDR` 取得中转 VPC CIDR。`INGRESS_CIDR` 应至少覆盖中转 EC2 的私网来源，以便转发流量经过 VPC Peering 到达落地机。若还需要从公网直接 SSH，应在 AWS 安全组中额外添加管理员公网 IP 的 TCP 22 规则，而不是扩大所有协议的来源范围。

查看状态与删除：

```bash
./aws-route-edge-node.sh status af-south-1 af-south-1-los-1a
./aws-route-edge-node.sh delete af-south-1 af-south-1-los-1a
```

脚本默认自动选择不冲突的 VPC `/16` 和子网 `/24`，并创建或复用目标 VPC、子网、Internet Gateway、路由表、跨区域 VPC Peering、EC2、安全组和 Elastic IP。

### 3. 在落地机部署 Shadowsocks

登录目标区域落地 EC2，在 `Scripts/aws/server/` 中执行：

```bash
TRANSIT_PUBLIC_IP=203.0.113.10 # 替换为中转机公网 IP 或域名

sudo env NODE_ADDRESS="$TRANSIT_PUBLIC_IP" \
  NODE_PORT=8388 \
  NODE_NAME=Lagos-SS \
  ./deploy-landing-ss.sh install
```

脚本会：

- 安装最新稳定版 sing-box Debian 包。
- 校验下载包的 SHA256。
- 生成 48 位十六进制密码，或复用已有受管密码。
- 配置 `aes-128-gcm`、TCP 和 UDP，默认监听 `8388`。
- 创建并启动 `sing-box.service`。
- 输出通用 `ss://` 节点和 Surge policy。

敏感文件写入：

```text
/etc/sing-box/config.json
/root/aws-route-ss-credentials.env
/root/aws-route-ss-node.txt
```

这些文件均使用 `root:root` 和 `600` 权限。

### 4. 在中转机部署转发

先从落地 EC2 状态中取得私网 IPv4，然后在新加坡中转 EC2 执行：

```bash
cd Scripts/aws/server

LANDING_PRIVATE_IP=10.20.1.10 # 替换为落地机私网 IPv4

sudo env LANDING_PRIVATE_IP="$LANDING_PRIVATE_IP" \
  FORWARD_PORT=8388 \
  ./deploy-transit.sh install
```

脚本会启用 `net.ipv4.ip_forward=1`，并通过 nftables 将中转机指定端口的 TCP/UDP 流量 DNAT 到落地机私网地址。若检测到已有的非受管 FORWARD 防火墙规则，脚本会停止且不修改系统。

### 5. 检查服务器状态

```bash
sudo ./deploy-transit.sh status
sudo ./deploy-landing-ss.sh status
sudo ./deploy-landing-ss.sh show-credentials
```

`show-credentials` 会输出完整密码，只应在受控终端中使用。

## 方式二：curl | bash 一键执行

当前远程仓库是私有仓库，匿名访问 `raw.githubusercontent.com` 会返回 `404`。应使用 Fine-grained personal access token，并只授予 `pi-pi-cat/Xavier` 仓库的 Contents 只读权限。

### 准备私有仓库读取

在当前终端中隐藏输入令牌，并定义下载函数：

```bash
read -rsp "GitHub read-only token: " AWS_ROUTE_GITHUB_TOKEN
printf '\n'
export AWS_ROUTE_GITHUB_TOKEN
export AWS_ROUTE_REF=main

AWS_ROUTE_CONTENT_API=https://api.github.com/repos/pi-pi-cat/Xavier/contents/Scripts/aws/quick-run.sh

fetch_aws_route() {
  curl -fsSL \
    --proto '=https' \
    --proto-redir '=https' \
    --tlsv1.2 \
    -H 'Accept: application/vnd.github.raw+json' \
    -H "Authorization: Bearer $AWS_ROUTE_GITHUB_TOKEN" \
    -H 'X-GitHub-Api-Version: 2026-03-10' \
    --get \
    --data-urlencode "ref=$AWS_ROUTE_REF" \
    "$AWS_ROUTE_CONTENT_API"
}

fetch_aws_route | bash -s -- help
```

`quick-run.sh` 会使用同一个只读令牌和 `AWS_ROUTE_REF` 下载所需的两个脚本。执行服务器组件时，它会先完成下载并清除令牌，再自动通过 `sudo` 运行部署脚本。

### 云资源命令

创建新加坡中转 EC2：

```bash
PUBLIC_IP="$(curl -fsSL https://checkip.amazonaws.com)"
fetch_aws_route | \
  env AWS_PROFILE=personal INGRESS_CIDR="${PUBLIC_IP}/32" \
  bash -s -- sg create --yes
```

查看或删除新加坡中转 EC2：

```bash
fetch_aws_route | env AWS_PROFILE=personal bash -s -- sg status
fetch_aws_route | env AWS_PROFILE=personal bash -s -- sg delete --yes
```

创建、查看或删除目标落地节点：

```bash
SOURCE_VPC_CIDR=172.31.0.0/16 # 替换为中转 EC2 所在 VPC 的 CIDR

fetch_aws_route | \
  env AWS_PROFILE=personal INGRESS_CIDR="$SOURCE_VPC_CIDR" \
  bash -s -- edge create af-south-1 af-south-1-los-1a --yes

fetch_aws_route | \
  env AWS_PROFILE=personal \
  bash -s -- edge status af-south-1 af-south-1-los-1a

fetch_aws_route | \
  env AWS_PROFILE=personal \
  bash -s -- edge delete af-south-1 af-south-1-los-1a --yes
```

### 服务器命令

在落地机安装 Shadowsocks：

```bash
TRANSIT_PUBLIC_IP=203.0.113.10 # 替换为中转机公网 IP 或域名

fetch_aws_route | \
  env NODE_ADDRESS="$TRANSIT_PUBLIC_IP" NODE_PORT=8388 NODE_NAME=Lagos-SS \
  bash -s -- landing install --yes
```

入口脚本会在下载完成后自动调用 `sudo`。首次运行时，终端可能要求输入服务器的 sudo 密码。

在中转机安装转发：

```bash
LANDING_PRIVATE_IP=10.20.1.10 # 替换为落地机私网 IPv4

fetch_aws_route | \
  env LANDING_PRIVATE_IP="$LANDING_PRIVATE_IP" FORWARD_PORT=8388 \
  bash -s -- transit install --yes
```

状态、凭据与节点重新生成：

```bash
fetch_aws_route | bash -s -- transit status
fetch_aws_route | bash -s -- landing status
fetch_aws_route | bash -s -- landing show-credentials

TRANSIT_PUBLIC_IP=203.0.113.10 # 替换为新的中转机公网 IP 或域名

fetch_aws_route | \
  env NODE_ADDRESS="$TRANSIT_PUBLIC_IP" NODE_PORT=8388 NODE_NAME=Lagos-SS \
  bash -s -- landing generate-node --yes
```

移除服务器配置：

```bash
fetch_aws_route | bash -s -- transit remove --yes
fetch_aws_route | bash -s -- landing remove --yes
```

移除操作会备份并删除脚本管理的配置与 systemd unit，但保留已安装的软件包。备份目录位于 `/var/backups/aws-route/`。

使用完成后清除当前终端中的令牌：

```bash
unset AWS_ROUTE_GITHUB_TOKEN
unset -f fetch_aws_route
```

### 公开仓库或公开镜像

如果以后将这些脚本发布到公开仓库，可以不使用令牌：

```bash
RUN_URL=https://raw.githubusercontent.com/pi-pi-cat/Xavier/main/Scripts/aws/quick-run.sh
curl -fsSL "$RUN_URL" | bash -s -- help
```

当前私有仓库不能直接使用这条匿名 Raw 命令。

## 固定到指定版本

推荐把 `AWS_ROUTE_REF` 设置为已经审查的 commit SHA。下载函数和 `quick-run.sh` 会使用同一个 SHA：

```bash
export AWS_ROUTE_REF=0123456789abcdef0123456789abcdef01234567 # 替换为真实 SHA

fetch_aws_route | env AWS_PROFILE=personal bash -s -- sg status
```

`quick-run.sh` 可用以下变量覆盖下载来源和执行方式：

```text
AWS_ROUTE_REPOSITORY=owner/repository
AWS_ROUTE_REF=branch-tag-or-commit
AWS_ROUTE_RAW_BASE=https://example.com/path
AWS_ROUTE_GITHUB_TOKEN=read-only-token
AWS_ROUTE_GITHUB_API_BASE=https://api.github.com
AWS_ROUTE_GITHUB_API_VERSION=2026-03-10
AWS_ROUTE_USE_SUDO=auto
```

设置令牌时，入口使用 GitHub Contents API；未设置令牌时，入口使用 `AWS_ROUTE_RAW_BASE`。所有自定义下载地址必须使用 HTTPS。服务器组件默认在当前用户不是 root 时自动使用 `sudo`，可设置 `AWS_ROUTE_USE_SUDO=0` 禁用。

## 非交互自动化

直接执行仓库脚本时，可使用：

```bash
AUTO_APPROVE=1 INTERACTIVE=0 KEY=value ./script.sh create
```

通过 `quick-run.sh` 执行变更操作时，必须使用 `--yes` 或 `AUTO_APPROVE=1`。状态和帮助命令不需要确认。

## 清理范围

### 新加坡中转脚本

`aws-route-ec2-sg.sh delete` 删除：

- 带管理标签的中转 EC2。
- 已脱离且带管理标签的根 EBS 卷。
- 专用安全组。

它保留区域 Key Pair、本地 PEM、默认 VPC、默认子网、路由表和 Lightsail VPC Peering。检测到 Elastic IP 时只告警，不自动释放。

### 跨区域落地脚本

`aws-route-edge-node.sh delete` 按依赖顺序删除受管的目标 EC2、EIP、EBS、安全组、Peering 路由、VPC Peering、路由表、子网、Internet Gateway 和目标 VPC。

它保留新加坡源资源、目标 Zone opt-in、区域 Key Pair 和本地 PEM。

### 服务器脚本

`remove` 仅删除对应脚本管理的配置、服务文件和运行规则。每次安装、节点更新或移除前都会在 `/var/backups/aws-route/` 创建时间戳备份。

## 测试

在仓库根目录执行：

```bash
./Scripts/aws/tests/run.sh
```

测试内容包括：

- 所有 Shell 脚本的 `bash -n` 语法检查。
- CIDR、IPv4、端口、密码、节点编码等公共函数测试。
- 云资源和服务器脚本的帮助入口测试。
- `quick-run.sh` 的组件分发、HTTPS 限制和变更操作确认测试。
- 服务器配置脚本不调用 AWS CLI 或 EC2 Metadata 的静态检查。

这些测试不会创建 AWS 资源，也不会修改当前机器的系统配置。

## 常见问题

### 中转机无法访问落地端口

检查：

1. 中转 EC2 的 Source/Destination Check 是否已关闭。
2. 两端 VPC Peering 是否为 `active`。
3. 两端路由表是否都有对端 CIDR 路由。
4. 落地安全组是否允许中转私网 IP 或中转 VPC CIDR 的 TCP/UDP 端口。
5. 落地机 `sing-box.service` 是否为 `active`。
6. 中转机 `aws-route-transit.service` 和 nftables 表是否存在。

### Local Zone 创建失败

确认账号已获准使用该 Local Zone，目标 Zone group 已启用，并检查该区域当前提供的 EC2 实例类型、EBS 类型和 Elastic IP network border group。

### 推送节点配置时地址变化

中转公网 IP 或域名变化后，无需更换 Shadowsocks 密码。只需在落地机重新运行 `generate-node`，更新 `NODE_ADDRESS` 后重新导出节点。
