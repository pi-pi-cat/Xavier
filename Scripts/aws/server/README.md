# 服务器配置脚本说明

本目录只配置中转机和落地机的操作系统。它不会调用 AWS CLI、AWS API 或 EC2 Metadata。第一次使用请先阅读上级目录的[最短执行顺序](../README.md)。

## 文件

```text
server/
├── route-local-common.sh  # 系统检查、输入校验、备份和文件写入函数
├── deploy-transit.sh      # 中转机 nftables DNAT
└── deploy-landing-ss.sh   # 落地机 sing-box Shadowsocks
```

`route-local-common.sh` 是公共库，不应单独执行。

## 前置条件

- Debian 12 或 Debian 13。
- root 或 sudo 权限。
- 可访问 Debian 软件源和 GitHub Releases。
- 中转 EC2 已关闭 Source/Destination Check。
- 两端 VPC Peering 和双向路由已生效。
- 中转安全组允许客户端访问所选 TCP/UDP 端口。
- 落地安全组允许中转私网来源访问相同 TCP/UDP 端口。

## 落地机 Shadowsocks

`deploy-landing-ss.sh` 安装 sing-box 并运行 Shadowsocks 服务。

```bash
TRANSIT_PUBLIC_IP=203.0.113.10 # 替换为中转机公网 IP 或域名

sudo env NODE_ADDRESS="$TRANSIT_PUBLIC_IP" \
  NODE_PORT=8388 \
  NODE_NAME=Lagos-SS \
  ./deploy-landing-ss.sh install
```

默认协议参数：

```text
监听地址：0.0.0.0
端口：8388
加密方式：aes-128-gcm
网络：TCP + UDP
UoT：关闭
Multiplex：关闭
```

脚本会选择最新稳定版 sing-box Debian 包并校验 SHA256。已有受管配置存在时复用密码，否则生成 48 位十六进制密码。

### 常用操作

```bash
sudo ./deploy-landing-ss.sh status
sudo ./deploy-landing-ss.sh show-credentials

sudo env NODE_ADDRESS=203.0.113.10 NODE_PORT=8388 NODE_NAME=Lagos-SS \
  ./deploy-landing-ss.sh generate-node

sudo ./deploy-landing-ss.sh remove
```

`show-credentials` 会输出完整密码，只应在受控终端中使用。

### 受管文件

```text
/etc/sing-box/config.json
/root/aws-route-ss-credentials.env
/root/aws-route-ss-node.txt
/etc/systemd/system/sing-box.service
```

配置、凭据和节点文件使用 `root:root` 与 `600` 权限。节点文件第一行是通用 `ss://` 地址，第二行是 Surge policy。

## 中转机端口转发

`deploy-transit.sh` 使用 nftables 将中转机指定端口的 TCP/UDP 流量转发到落地机私网地址。

```bash
LANDING_PRIVATE_IP=10.20.1.10 # 替换为落地机私网 IPv4

sudo env LANDING_PRIVATE_IP="$LANDING_PRIVATE_IP" \
  FORWARD_PORT=8388 \
  ./deploy-transit.sh install
```

脚本配置：

```text
net.ipv4.ip_forward=1
TCP DNAT：中转机端口 -> 落地机端口
UDP DNAT：中转机端口 -> 落地机端口
MASQUERADE：转发流量源地址转换
```

安装前会检查已有 nftables FORWARD hook 和非默认 iptables FORWARD 规则。发现冲突时会停止，不修改系统。

### 常用操作

```bash
sudo ./deploy-transit.sh status
sudo ./deploy-transit.sh remove
```

### 受管文件

```text
/etc/aws-route/transit.env
/etc/aws-route/transit.nft
/usr/local/sbin/aws-route-transit-apply
/etc/systemd/system/aws-route-transit.service
/etc/sysctl.d/99-aws-route-transit.conf
```

## 备份与移除

每次安装、节点重新生成或移除前，脚本都会在以下目录创建时间戳备份：

```text
/var/backups/aws-route/
```

`remove` 只删除脚本管理的配置、systemd unit 和运行规则，不卸载已安装的软件包。

直接执行 `remove` 时需要输入确认短语。通过 `quick-run.sh` 非交互执行时必须提供 `--yes`。

## 更换服务器

### 更换落地机

保留原端口、加密方式和密码，在中转机上重新运行 `deploy-transit.sh install`，把 `LANDING_PRIVATE_IP` 改为新落地机私网 IP。

### 更换中转机

在新中转机重新运行 `deploy-transit.sh install`。然后在落地机执行 `generate-node`，把 `NODE_ADDRESS` 更新为新中转机公网 IP 或域名，无需更换 Shadowsocks 密码。

## 故障排查

中转机无法访问落地端口时，依次检查：

1. 中转 EC2 的 Source/Destination Check 是否关闭。
2. VPC Peering 状态是否为 `active`。
3. 两端路由表是否都有对端 CIDR 路由。
4. 落地安全组是否允许中转私网 IP 或中转 VPC CIDR。
5. `sing-box.service` 是否为 `active`。
6. `aws-route-transit.service` 是否为 `active`。
7. 中转机上的 `aws_route` nftables 表是否存在。

状态命令输出中的 `SOURCE_DEST_CHECK=UNVERIFIED` 和 `SECURITY_GROUP_STATUS=UNVERIFIED` 表示服务器脚本刻意没有访问 AWS，必须在 AWS 控制台或云资源脚本中确认。
