# DN42 OSPF WireGuard隧道配置脚本

专门用于DN42网络中使用IPv6 Link-Local地址传递IPv4 OSPF数据的WireGuard隧道配置脚本。

## 核心特性

- **使用IPv6 Link-Local地址传递IPv4 OSPF数据**
- 自动检测并安装Bird 2.16+（支持IPv6 LLA over IPv4 OSPF）
- 配置`Table = off`以支持OSPF路由协议
- 自动添加OSPF组播地址（ff02::5）到AllowedIPs
- 禁用IPv6自动配置（autoconf=0）

## 为什么使用IPv6 Link-Local？

在DN42网络中，使用IPv6 Link-Local地址传递OSPF数据有以下优势：

1. **节省IP地址**：不需要为每个隧道分配DN42 IP地址
2. **简化配置**：Link-Local地址自动生成，无需手动规划
3. **更好的隔离**：OSPF流量与数据流量分离
4. **符合最佳实践**：现代网络推荐的做法

## Bird版本要求

- **Bird 2.16+**：完全支持IPv6 LLA传递IPv4 OSPF
- **Bird < 2.16**：需要额外配置IPv4地址（脚本会自动处理）

## 安装Bird 2.16+

脚本会自动提示安装，也可以手动安装：

```bash
sudo apt update && sudo apt -y install apt-transport-https ca-certificates wget lsb-release

sudo wget -O /usr/share/keyrings/cznic-labs-pkg.gpg https://pkg.labs.nic.cz/gpg

echo "deb [signed-by=/usr/share/keyrings/cznic-labs-pkg.gpg] https://pkg.labs.nic.cz/bird2 $(lsb_release -sc) main" | sudo tee /etc/apt/sources.list.d/cznic-labs-bird2.list

sudo apt update && sudo apt install bird2 -y
```

验证版本：

```bash
bird --version
```

## 使用步骤

### 1. 在第一个节点上运行

```bash
chmod +x dn42-ospf-wg.sh
sudo ./dn42-ospf-wg.sh
```

按照提示输入：
- 节点名称（例如：hk）
- WireGuard监听端口（默认51820）
- MTU大小（默认1420）
- 是否安装Bird 2.16+（推荐）

脚本会生成：
- WireGuard密钥对
- IPv6 Link-Local地址（例如：fe80::1234:5678:9abc:def0）

**记录显示的公钥和Link-Local地址**，发送给对端节点。

### 2. 在第二个节点上运行

```bash
sudo ./dn42-ospf-wg.sh
```

输入相应配置，使用第一个节点的公钥作为对端公钥。

### 3. 测试连接

```bash
# 查看WireGuard状态
sudo wg show

# 查看接口信息
ip addr show dn42-hk

# Ping对端Link-Local地址（需要指定接口）
ping6 fe80::xxxx:xxxx:xxxx:xxxx%dn42-hk
```

### 4. 配置BIRD OSPF

编辑 `/etc/bird/bird.conf`：

```conf
# 定义Router ID（使用你的DN42 IPv4地址）
router id 172.20.1.1;

# OSPFv2 (IPv4) - 使用IPv6 Link-Local地址
protocol ospf v2 ospf_dn42 {
    ipv4 {
        import all;
        export all;
    };

    area 0 {
        interface "dn42-hk" {
            type pointopoint;
            cost 10;
            hello 5;
            dead 20;
        };
    };
}

# OSPFv3 (IPv6)
protocol ospf v3 ospf_dn42_v6 {
    ipv6 {
        import all;
        export all;
    };

    area 0 {
        interface "dn42-hk" {
            type pointopoint;
            cost 10;
            hello 5;
            dead 20;
        };
    };
}

# 静态路由（如果需要）
protocol static {
    ipv4;
    route 172.20.1.0/24 via "lo";
}

protocol static {
    ipv6;
    route fd42:1234:5678::/48 via "lo";
}
```

重启BIRD：

```bash
sudo systemctl restart bird
```

### 5. 验证OSPF

```bash
# 查看BIRD状态
sudo birdc show protocols

# 查看OSPF邻居
sudo birdc show ospf neighbors

# 查看路由表
sudo birdc show route

# 查看OSPF接口
sudo birdc show ospf interface
```

## 配置文件示例

### 节点1配置 (/etc/wireguard/dn42-hk.conf)

```ini
# DN42 OSPF WireGuard配置
# 使用IPv6 Link-Local地址传递IPv4 OSPF数据

[Interface]
PrivateKey = <节点1私钥>
ListenPort = 51820
MTU = 1420
Table = off

# IPv6 Link-Local地址
Address = fe80::1234:5678:9abc:def0/64

# 禁用IPv6自动配置
PostUp = sysctl -w net.ipv6.conf.%i.autoconf=0

[Peer]
PublicKey = <节点2公钥>
Endpoint = node2.example.com:51820
PersistentKeepalive = 25
AllowedIPs = 10.0.0.0/8, 172.20.0.0/14, 172.31.0.0/16, fd00::/8, fe80::/10, ff02::5
```

### 节点2配置 (/etc/wireguard/dn42-us.conf)

```ini
# DN42 OSPF WireGuard配置

[Interface]
PrivateKey = <节点2私钥>
ListenPort = 51820
MTU = 1420
Table = off

Address = fe80::abcd:ef01:2345:6789/64

PostUp = sysctl -w net.ipv6.conf.%i.autoconf=0

[Peer]
PublicKey = <节点1公钥>
AllowedIPs = 10.0.0.0/8, 172.20.0.0/14, 172.31.0.0/16, fd00::/8, fe80::/10, ff02::5
```

## 关键配置说明

### Table = off

禁用WireGuard自动路由管理，让OSPF协议完全控制路由。

### AllowedIPs详解

```ini
AllowedIPs = 10.0.0.0/8,        # 私有网络
             172.20.0.0/14,     # DN42 IPv4主网段
             172.31.0.0/16,     # DN42 IPv4扩展网段
             fd00::/8,          # DN42 IPv6网段
             fe80::/10,         # Link-Local地址范围
             ff02::5            # OSPFv3组播地址
```

### PostUp命令

```bash
PostUp = sysctl -w net.ipv6.conf.%i.autoconf=0
```

禁用接口的IPv6自动配置，防止系统自动分配其他地址。

## OSPF配置要点

### 接口类型

```conf
interface "dn42-hk" {
    type pointopoint;  # 点对点类型，适合WireGuard隧道
    cost 10;           # 链路成本
    hello 5;           # Hello间隔（秒）
    dead 20;           # Dead间隔（秒）
}
```

### Router ID

Router ID必须是IPv4地址格式，建议使用你的DN42 IPv4地址：

```conf
router id 172.20.1.1;
```

### 区域配置

```conf
area 0 {  # OSPF Area 0（骨干区域）
    interface "dn42-hk" {
        # 接口配置
    };
}
```

## 多节点拓扑

### 三节点Full Mesh

```
    HK -------- US
     \         /
      \       /
       \     /
         EU
```

每个节点需要配置两个WireGuard接口：

- HK: dn42-us, dn42-eu
- US: dn42-hk, dn42-eu
- EU: dn42-hk, dn42-us

### 星型拓扑（Hub-Spoke）

```
    HK
   /  \
  /    \
US      EU
```

HK作为中心节点，US和EU只连接到HK。

## 常用命令

```bash
# WireGuard管理
sudo wg show
sudo wg-quick up dn42-hk
sudo wg-quick down dn42-hk

# BIRD管理
sudo systemctl status bird
sudo systemctl restart bird
sudo birdc configure  # 重新加载配置

# OSPF调试
sudo birdc show protocols all ospf_dn42
sudo birdc show ospf neighbors
sudo birdc show ospf state
sudo birdc show ospf topology

# 路由查看
sudo birdc show route
sudo birdc show route protocol ospf_dn42
ip route show
ip -6 route show

# 接口信息
ip addr show dn42-hk
ip link show dn42-hk
```

## 故障排查

### 1. OSPF邻居无法建立

检查项：
- WireGuard隧道是否正常：`sudo wg show`
- Link-Local地址是否配置：`ip addr show dn42-hk`
- OSPF组播地址是否在AllowedIPs中：`ff02::5`
- 防火墙是否允许OSPF协议（IP协议号89）

```bash
# 允许OSPF
sudo iptables -A INPUT -p ospf -j ACCEPT
sudo ip6tables -A INPUT -p ospf -j ACCEPT
```

### 2. Bird配置错误

```bash
# 检查配置语法
sudo bird -p -c /etc/bird/bird.conf

# 查看日志
sudo journalctl -u bird -f
```

### 3. 路由未学习

```bash
# 检查OSPF状态
sudo birdc show ospf state

# 检查路由过滤
sudo birdc show route all protocol ospf_dn42
```

### 4. IPv6 Link-Local不可达

```bash
# Ping需要指定接口
ping6 fe80::xxxx:xxxx:xxxx:xxxx%dn42-hk

# 检查邻居发现
ip -6 neigh show dev dn42-hk
```

## Bird < 2.16的配置

如果使用旧版本Bird，需要添加IPv4地址：

```ini
[Interface]
Address = fe80::1234:5678:9abc:def0/64
Address = 169.254.1.1/30  # 添加IPv4地址
```

BIRD配置中使用IPv4地址：

```conf
protocol ospf v2 ospf_dn42 {
    area 0 {
        interface "dn42-hk" {
            neighbors {
                169.254.1.2;  # 对端IPv4地址
            };
        };
    };
}
```

## 性能优化

### MTU调整

```bash
# 测试最佳MTU
ping -M do -s 1400 <对端IP>

# 调整MTU
sudo ip link set dn42-hk mtu 1400
```

### OSPF定时器优化

```conf
interface "dn42-hk" {
    hello 3;      # 更快的Hello间隔
    dead 10;      # 更快的故障检测
    retransmit 2; # 重传间隔
}
```

## 安全建议

1. 定期更新WireGuard密钥
2. 使用强随机密码保护服务器
3. 限制WireGuard端口访问（仅允许对端IP）
4. 启用OSPF认证（如果需要）
5. 监控异常路由通告

## 参考资源

- DN42 Wiki: https://wiki.dn42.eu
- Bird文档: https://bird.network.cz/
- WireGuard文档: https://www.wireguard.com/
- OSPF RFC: RFC 2328 (OSPFv2), RFC 5340 (OSPFv3)
