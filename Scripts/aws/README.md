# AWS 跨区域中转脚本

第一次使用时，直接按下面顺序执行。详细原理和参数放在子目录文档中。

## 最短执行顺序

以下示例使用新加坡作为中转区域、Lagos Local Zone 作为落地区域、AWS CLI Profile `personal`，服务器系统为 Debian。

### 0. 在本地管理机准备

```bash
aws login --profile personal
aws sts get-caller-identity --profile personal

RUN_URL=https://raw.githubusercontent.com/pi-pi-cat/Xavier/main/Scripts/aws/quick-run.sh
KEY_PATH="$HOME/.ssh/aws-route.pem"
```

### 1. 创建新加坡中转 EC2

```bash
CLIENT_IP="$(curl -fsSL https://checkip.amazonaws.com)"

curl -fsSL "$RUN_URL" | \
  env AWS_PROFILE=personal INGRESS_CIDR="${CLIENT_IP}/32" \
  bash -s -- sg create --yes
```

从输出中记录：

```bash
TRANSIT_PUBLIC_IP=203.0.113.10   # 替换为中转机 PublicIP
TRANSIT_VPC_CIDR=172.31.0.0/16  # 替换为输出中的 CIDR
```

### 2. 创建落地 EC2

```bash
curl -fsSL "$RUN_URL" | \
  env AWS_PROFILE=personal INGRESS_CIDR="$TRANSIT_VPC_CIDR" \
  bash -s -- edge create af-south-1 af-south-1-los-1a --yes
```

从输出中记录：

```bash
LANDING_PRIVATE_IP=10.20.1.10 # 替换为落地机 PrivateIP
```

落地安全组只允许中转 VPC 访问，因此下面通过新加坡中转机跳转登录落地机。

### 3. 在落地机安装 Shadowsocks

```bash
LANDING_PROXY="ssh -i '$KEY_PATH' -W %h:%p admin@$TRANSIT_PUBLIC_IP"

ssh -i "$KEY_PATH" \
  -o "ProxyCommand=$LANDING_PROXY" \
  "admin@$LANDING_PRIVATE_IP" \
  "curl -fsSL '$RUN_URL' | env NODE_ADDRESS='$TRANSIT_PUBLIC_IP' NODE_PORT=8388 NODE_NAME=Lagos-SS bash -s -- landing install --yes"
```

安装成功后会输出 `ss://` 节点和 Surge policy。请妥善保存，不要提交到 Git。

### 4. 在中转机安装端口转发

```bash
ssh -i "$KEY_PATH" "admin@$TRANSIT_PUBLIC_IP" \
  "curl -fsSL '$RUN_URL' | env LANDING_PRIVATE_IP='$LANDING_PRIVATE_IP' FORWARD_PORT=8388 bash -s -- transit install --yes"
```

完成后，客户端访问中转机公网 IP 的 `8388` TCP/UDP 端口，流量会转发到落地机。

### 5. 检查状态

云资源状态：

```bash
curl -fsSL "$RUN_URL" | env AWS_PROFILE=personal bash -s -- sg status

curl -fsSL "$RUN_URL" | \
  env AWS_PROFILE=personal \
  bash -s -- edge status af-south-1 af-south-1-los-1a
```

服务器状态：

```bash
ssh -i "$KEY_PATH" "admin@$TRANSIT_PUBLIC_IP" \
  "curl -fsSL '$RUN_URL' | bash -s -- transit status"

ssh -i "$KEY_PATH" \
  -o "ProxyCommand=$LANDING_PROXY" \
  "admin@$LANDING_PRIVATE_IP" \
  "curl -fsSL '$RUN_URL' | bash -s -- landing status"
```

重新查看生成的节点：

```bash
ssh -i "$KEY_PATH" \
  -o "ProxyCommand=$LANDING_PROXY" \
  "admin@$LANDING_PRIVATE_IP" \
  "sudo cat /root/aws-route-ss-node.txt"
```

## 删除顺序

先删除服务器配置，再删除 AWS 资源：

```bash
# 1. 中转机转发配置
ssh -i "$KEY_PATH" "admin@$TRANSIT_PUBLIC_IP" \
  "curl -fsSL '$RUN_URL' | bash -s -- transit remove --yes"

# 2. 落地机 Shadowsocks 配置
ssh -i "$KEY_PATH" \
  -o "ProxyCommand=$LANDING_PROXY" \
  "admin@$LANDING_PRIVATE_IP" \
  "curl -fsSL '$RUN_URL' | bash -s -- landing remove --yes"

# 3. 落地 AWS 资源
curl -fsSL "$RUN_URL" | \
  env AWS_PROFILE=personal \
  bash -s -- edge delete af-south-1 af-south-1-los-1a --yes

# 4. 新加坡中转 EC2
curl -fsSL "$RUN_URL" | \
  env AWS_PROFILE=personal \
  bash -s -- sg delete --yes
```

## 这套脚本做什么

```text
客户端 -> 新加坡中转 EC2 -> 跨区域 VPC Peering -> 落地 EC2 -> 互联网
```

云资源脚本负责 EC2、VPC、路由和安全组；服务器脚本负责中转端口转发与落地 Shadowsocks 服务。

## 安全提醒

- 创建、安装和删除操作必须带 `--yes`。
- 不要把 `INGRESS_CIDR` 长期设置为 `0.0.0.0/0`。
- 不要提交 PEM、密码、节点链接或生成后的 `ss://` 地址。
- AWS 资源会产生 EC2、EBS、Elastic IP、跨区域流量和 Local Zone 费用。
- 正式使用时，建议把 URL 中的 `main` 替换成已审查的 commit SHA。

## 详细文档

- [云资源脚本说明](cloud/README.md)：区域、VPC、EC2、安全组、参数、状态和删除范围。
- [服务器脚本说明](server/README.md)：中转转发、sing-box、配置文件、状态和故障排查。

## 本地测试

```bash
./Scripts/aws/tests/run.sh
```

测试不会创建 AWS 资源，也不会修改当前机器的系统配置。
