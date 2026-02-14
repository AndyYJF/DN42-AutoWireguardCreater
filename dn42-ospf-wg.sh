#!/bin/bash

# DN42 iBGP/OSPF WireGuard隧道自动配置脚本
# 支持使用IPv6 Link-Local地址传递IPv4 OSPF数据

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# DN42网络配置
DN42_IPV4_RANGE="172.20.0.0/14"
DN42_IPV6_RANGE="fd00::/8"
DEFAULT_MTU="1420"
BIRD_MIN_VERSION="2.16"

# 打印函数
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_note() {
    echo -e "${BLUE}[NOTE]${NC} $1"
}

# 检查是否为root用户
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "请使用root权限运行此脚本"
        exit 1
    fi
}

# 检查WireGuard是否已安装
check_wireguard() {
    if ! command -v wg &> /dev/null; then
        print_warning "WireGuard未安装，正在尝试安装..."
        install_wireguard
    else
        print_info "WireGuard已安装"
    fi
}

# 安装WireGuard
install_wireguard() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case $ID in
            ubuntu|debian)
                apt-get update
                apt-get install -y wireguard wireguard-tools iproute2
                ;;
            centos|rhel|fedora)
                yum install -y epel-release
                yum install -y wireguard-tools iproute
                ;;
            arch)
                pacman -S --noconfirm wireguard-tools iproute2
                ;;
            *)
                print_error "不支持的操作系统: $ID"
                exit 1
                ;;
        esac
        print_info "WireGuard安装完成"
    fi
}

# 检查Bird版本
check_bird_version() {
    if command -v bird &> /dev/null; then
        local version=$(bird --version 2>&1 | grep -oP 'version \K[0-9.]+' | head -1)
        print_info "当前Bird版本: ${version}"

        # 简单版本比较
        if [ "$(printf '%s\n' "$BIRD_MIN_VERSION" "$version" | sort -V | head -n1)" = "$BIRD_MIN_VERSION" ]; then
            print_info "Bird版本满足要求 (>= ${BIRD_MIN_VERSION})"
            return 0
        else
            print_warning "Bird版本过低 (< ${BIRD_MIN_VERSION})，不支持IPv6 LLA传递IPv4 OSPF"
            return 1
        fi
    else
        print_warning "Bird未安装"
        return 1
    fi
}

# 安装最新版Bird2
install_bird2() {
    print_info "开始安装Bird 2.16+..."

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case $ID in
            ubuntu|debian)
                apt update && apt -y install apt-transport-https ca-certificates wget lsb-release

                # 下载GPG密钥
                wget -O /usr/share/keyrings/cznic-labs-pkg.gpg https://pkg.labs.nic.cz/gpg

                # 添加仓库
                echo "deb [signed-by=/usr/share/keyrings/cznic-labs-pkg.gpg] https://pkg.labs.nic.cz/bird2 $(lsb_release -sc) main" | tee /etc/apt/sources.list.d/cznic-labs-bird2.list

                # 安装Bird2
                apt update && apt install bird2 -y

                print_info "Bird2安装完成"
                bird --version
                ;;
            *)
                print_error "自动安装仅支持Ubuntu/Debian，请手动安装Bird 2.16+"
                return 1
                ;;
        esac
    fi
}

# 检测已有的WireGuard密钥
detect_existing_keys() {
    local key_dir="/etc/wireguard"
    local found_keys=()

    if [ -d "$key_dir" ]; then
        # 查找所有私钥文件
        while IFS= read -r -d '' keyfile; do
            if [ -f "$keyfile" ]; then
                local private_key=$(cat "$keyfile" 2>/dev/null)
                # 验证是否是有效的WireGuard私钥（44个字符的base64）
                if [[ ${#private_key} -eq 44 ]] && [[ "$private_key" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
                    local public_key=$(echo "$private_key" | wg pubkey 2>/dev/null)
                    if [ -n "$public_key" ]; then
                        found_keys+=("$keyfile|$private_key|$public_key")
                    fi
                fi
            fi
        done < <(find "$key_dir" -type f \( -name "*.key" -o -name "privatekey" -o -name "private.key" \) -print0 2>/dev/null)

        # 也检查现有配置文件中的私钥
        while IFS= read -r -d '' conffile; do
            if [ -f "$conffile" ]; then
                local private_key=$(grep "^PrivateKey" "$conffile" | awk '{print $3}' | tr -d ' ')
                if [ -n "$private_key" ] && [[ ${#private_key} -eq 44 ]]; then
                    local public_key=$(echo "$private_key" | wg pubkey 2>/dev/null)
                    if [ -n "$public_key" ]; then
                        found_keys+=("$conffile|$private_key|$public_key")
                    fi
                fi
            fi
        done < <(find "$key_dir" -type f -name "*.conf" -print0 2>/dev/null)
    fi

    # 返回找到的密钥数量
    echo "${#found_keys[@]}"
    # 将密钥信息保存到临时文件
    if [ ${#found_keys[@]} -gt 0 ]; then
        printf '%s\n' "${found_keys[@]}" > /tmp/wg_detected_keys.tmp
    fi
}

# 显示已有密钥供用户选择
show_existing_keys() {
    if [ ! -f /tmp/wg_detected_keys.tmp ]; then
        return 1
    fi

    echo "" >&2
    print_info "检测到以下WireGuard密钥:" >&2
    echo "" >&2

    local index=1
    while IFS='|' read -r source private_key public_key; do
        echo "[$index] 来源: $source" >&2
        echo "    公钥: $public_key" >&2
        echo "" >&2
        ((index++))
    done < /tmp/wg_detected_keys.tmp

    return 0
}

# 选择已有密钥
select_existing_key() {
    local selection=$1
    local index=1

    while IFS='|' read -r source private_key public_key; do
        if [ "$index" -eq "$selection" ]; then
            echo "$private_key|$public_key"
            return 0
        fi
        ((index++))
    done < /tmp/wg_detected_keys.tmp

    return 1
}

# 生成密钥对
generate_keys() {
    local private_key=$(wg genkey)
    local public_key=$(echo "$private_key" | wg pubkey)
    echo "$private_key|$public_key"
}

# 获取或生成密钥
get_or_generate_keys() {
    local key_count=$(detect_existing_keys)

    if [ "$key_count" -gt 0 ]; then
        print_info "检测到 $key_count 个已有的WireGuard密钥" >&2
        echo "" >&2
        read -p "是否使用已有密钥? [Y/n]: " use_existing >&2
        use_existing=${use_existing:-Y}

        if [[ "$use_existing" =~ ^[Yy]$ ]]; then
            show_existing_keys

            while true; do
                read -p "请选择密钥编号 (1-$key_count) 或输入 0 生成新密钥: " key_selection >&2

                if [ "$key_selection" -eq 0 ] 2>/dev/null; then
                    print_info "生成新密钥..." >&2
                    generate_keys
                    rm -f /tmp/wg_detected_keys.tmp
                    return 0
                elif [ "$key_selection" -ge 1 ] 2>/dev/null && [ "$key_selection" -le "$key_count" ] 2>/dev/null; then
                    local keys=$(select_existing_key "$key_selection")
                    if [ -n "$keys" ]; then
                        print_info "使用已选择的密钥" >&2
                        echo "$keys"
                        rm -f /tmp/wg_detected_keys.tmp
                        return 0
                    fi
                fi

                print_error "无效的选择，请重试" >&2
            done
        fi
    fi

    # 生成新密钥
    print_info "生成新密钥..." >&2
    generate_keys
    rm -f /tmp/wg_detected_keys.tmp
}

# 生成IPv6 Link-Local地址
generate_link_local() {
    # 生成一个随机的link-local地址
    local random_part=$(openssl rand -hex 8)
    echo "fe80::${random_part:0:4}:${random_part:4:4}:${random_part:8:4}:${random_part:12:4}"
}

# 配置DN42 OSPF节点（使用IPv6 LLA）
configure_dn42_ospf_node() {
    local interface_name=$1
    local link_local=$2
    local listen_port=$3
    local peer_public_key=$4
    local peer_endpoint=$5
    local private_key=$6
    local mtu=$7
    local use_ipv4_addr=$8  # 是否使用IPv4地址（Bird < 2.16）

    print_info "配置DN42 OSPF节点（使用IPv6 Link-Local）..."

    # 创建配置文件
    cat > /etc/wireguard/${interface_name}.conf <<EOF
# DN42 OSPF WireGuard配置
# 使用IPv6 Link-Local地址传递IPv4 OSPF数据
# 生成时间: $(date)

[Interface]
PrivateKey = ${private_key}
ListenPort = ${listen_port}
MTU = ${mtu}
Table = off

# IPv6 Link-Local地址
Address = ${link_local}/64

# 禁用IPv6自动配置
PostUp = sysctl -w net.ipv6.conf.%i.autoconf=0
EOF

    # 如果需要IPv4地址（Bird < 2.16）
    if [ "$use_ipv4_addr" = "yes" ]; then
        echo "Address = 169.254.${RANDOM:0:2}.${RANDOM:0:2}/30" >> /etc/wireguard/${interface_name}.conf
        print_note "已添加IPv4地址（用于Bird < 2.16）"
    fi

    # 添加Peer配置
    if [ -n "$peer_public_key" ]; then
        cat >> /etc/wireguard/${interface_name}.conf <<EOF

[Peer]
PublicKey = ${peer_public_key}
EOF

        # 如果提供了endpoint，添加它
        if [ -n "$peer_endpoint" ]; then
            echo "Endpoint = ${peer_endpoint}" >> /etc/wireguard/${interface_name}.conf
            echo "PersistentKeepalive = 25" >> /etc/wireguard/${interface_name}.conf
        fi

        # 配置AllowedIPs - 包含DN42网段和OSPF组播地址
        cat >> /etc/wireguard/${interface_name}.conf <<EOF
AllowedIPs = 10.0.0.0/8, 172.20.0.0/14, 172.31.0.0/16, fd00::/8, fe80::/10, ff02::5
EOF
    fi

    # 设置权限
    chmod 600 /etc/wireguard/${interface_name}.conf

    print_info "配置文件已创建: /etc/wireguard/${interface_name}.conf"
    print_note "Link-Local IPv6地址: ${link_local}"
}

# 启动WireGuard接口
start_interface() {
    local interface_name=$1

    print_info "启动WireGuard接口: ${interface_name}"

    # 停止已存在的接口
    wg-quick down ${interface_name} 2>/dev/null || true

    # 启动接口
    if wg-quick up ${interface_name}; then
        print_info "WireGuard接口已启动"

        # 启用开机自启
        if command -v systemctl &> /dev/null; then
            systemctl enable wg-quick@${interface_name} 2>/dev/null || true
            print_info "已设置开机自启"
        fi
    else
        print_error "启动接口失败"
        return 1
    fi
}

# 显示接口状态
show_status() {
    local interface_name=$1
    echo ""
    print_info "WireGuard接口状态:"
    wg show ${interface_name}
    echo ""
    print_info "接口IP地址:"
    ip addr show ${interface_name} 2>/dev/null || true
}

# 生成OSPF配置示例
generate_ospf_example() {
    local interface_name=$1
    local asn=$2
    local router_id=$3

    echo ""
    print_info "=== BIRD OSPF配置示例 ==="
    cat <<EOF

# 在 /etc/bird/bird.conf 中添加:

# 定义Router ID
router id ${router_id};

# OSPFv2 (IPv4)
protocol ospf v2 ospf_dn42 {
    ipv4 {
        import all;
        export all;
    };

    area 0 {
        interface "${interface_name}" {
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
        interface "${interface_name}" {
            type pointopoint;
            cost 10;
            hello 5;
            dead 20;
        };
    };
}

# 如果需要BGP，可以重分发OSPF路由
protocol bgp ibgp_peer {
    local as ${asn};
    neighbor <对端IP> as ${asn};

    ipv4 {
        import all;
        export where source = RTS_OSPF;
    };

    ipv6 {
        import all;
        export where source = RTS_OSPF;
    };
}

EOF
}

# 交互式配置
interactive_setup() {
    echo "=========================================="
    echo "  DN42 OSPF WireGuard隧道配置向导"
    echo "=========================================="
    echo ""
    print_note "此脚本用于配置使用IPv6 Link-Local地址的OSPF隧道"
    echo ""

    # 检查Bird版本
    local bird_ok=false
    if check_bird_version; then
        bird_ok=true
    else
        echo ""
        read -p "是否安装Bird 2.16+? (需要支持IPv6 LLA传递IPv4 OSPF) [Y/n]: " install_bird
        install_bird=${install_bird:-Y}

        if [[ "$install_bird" =~ ^[Yy]$ ]]; then
            install_bird2
            if check_bird_version; then
                bird_ok=true
            fi
        fi
    fi

    # 获取节点信息
    echo ""
    read -p "节点名称 (例如: node1, hk, us): " NODE_NAME
    if [ -z "$NODE_NAME" ]; then
        print_error "节点名称不能为空"
        exit 1
    fi

    # 接口名称
    INTERFACE_NAME="dn42-${NODE_NAME}"
    print_info "接口名称: ${INTERFACE_NAME}"

    # 生成Link-Local地址
    LINK_LOCAL=$(generate_link_local)
    print_info "生成的Link-Local地址: ${LINK_LOCAL}"

    # 监听端口
    read -p "WireGuard监听端口 [默认: 51820]: " LISTEN_PORT
    LISTEN_PORT=${LISTEN_PORT:-51820}

    # MTU设置
    read -p "MTU大小 [默认: ${DEFAULT_MTU}]: " MTU
    MTU=${MTU:-${DEFAULT_MTU}}

    # 是否需要IPv4地址
    USE_IPV4_ADDR="no"
    if [ "$bird_ok" = false ]; then
        print_warning "Bird版本 < 2.16，需要配置IPv4地址"
        USE_IPV4_ADDR="yes"
    else
        read -p "是否添加IPv4地址? (Bird 2.16+不需要) [y/N]: " add_ipv4
        if [[ "$add_ipv4" =~ ^[Yy]$ ]]; then
            USE_IPV4_ADDR="yes"
        fi
    fi

    # 获取或生成密钥
    echo ""
    keys=$(get_or_generate_keys)
    PRIVATE_KEY=$(echo "$keys" | cut -d'|' -f1)
    PUBLIC_KEY=$(echo "$keys" | cut -d'|' -f2)

    echo ""
    echo "=========================================="
    print_info "本节点公钥:"
    echo "${PUBLIC_KEY}"
    echo ""
    print_info "本节点Link-Local地址:"
    echo "${LINK_LOCAL}"
    echo "=========================================="
    print_warning "请将公钥和Link-Local地址发送给对端节点"
    echo ""
    read -p "按回车继续..." dummy

    # 对端节点配置
    echo ""
    print_note "现在配置对端节点信息"

    read -p "对端节点公钥: " PEER_PUBLIC_KEY
    if [ -z "$PEER_PUBLIC_KEY" ]; then
        print_error "对端公钥不能为空"
        exit 1
    fi

    read -p "对端节点地址 (例如: peer.example.com:51820，留空表示被动连接): " PEER_ENDPOINT

    # 配置节点
    configure_dn42_ospf_node "$INTERFACE_NAME" "$LINK_LOCAL" "$LISTEN_PORT" \
                             "$PEER_PUBLIC_KEY" "$PEER_ENDPOINT" \
                             "$PRIVATE_KEY" "$MTU" "$USE_IPV4_ADDR"

    # 询问是否启动
    echo ""
    read -p "是否立即启动WireGuard接口? [Y/n]: " start_now
    start_now=${start_now:-Y}

    if [[ "$start_now" =~ ^[Yy]$ ]]; then
        start_interface "$INTERFACE_NAME"
        show_status "$INTERFACE_NAME"
    fi

    # 询问是否显示OSPF配置示例
    echo ""
    read -p "是否显示BIRD OSPF配置示例? [Y/n]: " show_ospf
    show_ospf=${show_ospf:-Y}

    if [[ "$show_ospf" =~ ^[Yy]$ ]]; then
        read -p "你的DN42 ASN (例如: 4242421234): " ASN
        read -p "你的Router ID (例如: 172.20.1.1): " ROUTER_ID
        if [ -n "$ASN" ] && [ -n "$ROUTER_ID" ]; then
            generate_ospf_example "$INTERFACE_NAME" "$ASN" "$ROUTER_ID"
        fi
    fi

    echo ""
    print_info "配置完成！"
    echo ""
    print_note "下一步操作:"
    echo "1. 在对端节点运行相同的脚本进行配置"
    echo "2. 配置BIRD进行OSPF路由"
    echo "3. 使用 'birdc show protocols' 检查OSPF状态"
    echo "4. 使用 'birdc show ospf neighbors' 查看OSPF邻居"
    echo "5. 使用 'birdc show route' 查看路由表"
}

# 主函数
main() {
    check_root
    check_wireguard
    interactive_setup
}

# 运行主函数
main
