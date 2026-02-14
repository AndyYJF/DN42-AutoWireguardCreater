#!/bin/bash

# DN42 iBGP WireGuard隧道自动配置脚本
# 专门用于在DN42网络的多个节点之间建立iBGP连接

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

# 检测已有的WireGuard密钥
detect_existing_keys() {
    local key_dir="/etc/wireguard"
    local found_keys=()
    declare -A seen_public_keys  # 用于去重

    if [ -d "$key_dir" ]; then
        # 优先查找独立的私钥文件
        while IFS= read -r -d '' keyfile; do
            if [ -f "$keyfile" ]; then
                local private_key=$(cat "$keyfile" 2>/dev/null | tr -d '[:space:]')
                # 验证是否是有效的WireGuard私钥（44个字符的base64）
                if [[ ${#private_key} -eq 44 ]] && [[ "$private_key" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
                    local public_key=$(echo "$private_key" | wg pubkey 2>/dev/null)
                    if [ -n "$public_key" ] && [ -z "${seen_public_keys[$public_key]}" ]; then
                        found_keys+=("$keyfile|$private_key|$public_key")
                        seen_public_keys[$public_key]=1
                    fi
                fi
            fi
        done < <(find "$key_dir" -maxdepth 1 -type f \( -name "*.key" -o -name "privatekey" -o -name "private.key" \) -print0 2>/dev/null)

        # 如果没有找到独立密钥文件，再从配置文件中提取（仅提取一次）
        if [ ${#found_keys[@]} -eq 0 ]; then
            while IFS= read -r -d '' conffile; do
                if [ -f "$conffile" ]; then
                    local private_key=$(grep "^PrivateKey" "$conffile" | head -1 | awk '{print $3}' | tr -d '[:space:]')
                    if [ -n "$private_key" ] && [[ ${#private_key} -eq 44 ]]; then
                        local public_key=$(echo "$private_key" | wg pubkey 2>/dev/null)
                        if [ -n "$public_key" ] && [ -z "${seen_public_keys[$public_key]}" ]; then
                            found_keys+=("$conffile|$private_key|$public_key")
                            seen_public_keys[$public_key]=1
                        fi
                    fi
                fi
            done < <(find "$key_dir" -maxdepth 1 -type f -name "*.conf" -print0 2>/dev/null)
        fi
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
    # 基于接口名生成一个确定性的link-local地址
    local interface=$1
    local hash=$(echo -n "$interface" | md5sum | cut -c1-16)
    echo "fe80::${hash:0:4}:${hash:4:4}:${hash:8:4}:${hash:12:4}"
}

# 验证DN42 IP地址
validate_dn42_ip() {
    local ip=$1
    local type=$2  # ipv4 or ipv6

    if [ "$type" = "ipv4" ]; then
        # 检查是否在172.20.0.0/14范围内
        if [[ $ip =~ ^172\.(2[0-3]|1[6-9])\. ]]; then
            return 0
        else
            print_error "IPv4地址不在DN42范围内 (172.20.0.0/14 - 172.23.255.255/14)"
            return 1
        fi
    elif [ "$type" = "ipv6" ]; then
        # 检查是否以fd开头
        if [[ $ip =~ ^fd[0-9a-f]{2}: ]]; then
            return 0
        else
            print_error "IPv6地址不在DN42范围内 (fd00::/8)"
            return 1
        fi
    fi
}

# 配置DN42 iBGP节点
configure_dn42_node() {
    local interface_name=$1
    local local_ipv4=$2
    local local_ipv6=$3
    local listen_port=$4
    local peer_public_key=$5
    local peer_endpoint=$6
    local peer_ipv4=$7
    local peer_ipv6=$8
    local private_key=$9
    local mtu=${10}

    print_info "配置DN42 iBGP节点..."

    # 生成link-local地址
    local link_local=$(generate_link_local "$interface_name")

    # 创建配置文件
    cat > /etc/wireguard/${interface_name}.conf <<EOF
# DN42 iBGP WireGuard配置
# 生成时间: $(date)

[Interface]
PrivateKey = ${private_key}
ListenPort = ${listen_port}
MTU = ${mtu}

# 配置隧道IP地址
Address = ${local_ipv4}
Address = ${local_ipv6}
Address = ${link_local}/64

# 启动后执行的命令
PostUp = ip -6 route add ${DN42_IPV6_RANGE} dev %i || true
PostUp = ip -4 route add ${DN42_IPV4_RANGE} dev %i table 42 || true

# 关闭前执行的命令
PreDown = ip -6 route del ${DN42_IPV6_RANGE} dev %i || true
PreDown = ip -4 route del ${DN42_IPV4_RANGE} dev %i table 42 || true
EOF

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

        # 配置AllowedIPs - 包含对端的隧道IP和DN42网段
        local allowed_ips="${peer_ipv4}"
        if [ -n "$peer_ipv6" ]; then
            allowed_ips="${allowed_ips}, ${peer_ipv6}"
        fi
        # 添加DN42网段以允许路由
        allowed_ips="${allowed_ips}, ${DN42_IPV4_RANGE}, ${DN42_IPV6_RANGE}"

        echo "AllowedIPs = ${allowed_ips}" >> /etc/wireguard/${interface_name}.conf
    fi

    # 设置权限
    chmod 600 /etc/wireguard/${interface_name}.conf

    print_info "配置文件已创建: /etc/wireguard/${interface_name}.conf"

    # 显示link-local地址供BGP配置使用
    print_note "Link-Local IPv6地址: ${link_local}"
    print_note "此地址可用于BGP neighbor配置"
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
            if systemctl enable wg-quick@${interface_name} 2>/dev/null; then
                print_info "已启用开机自启: wg-quick@${interface_name}"
            else
                print_warning "无法启用开机自启，请手动执行: systemctl enable wg-quick@${interface_name}"
            fi
        else
            print_warning "未检测到systemd，无法设置开机自启"
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

# 生成BGP配置示例
generate_bgp_example() {
    local interface_name=$1
    local peer_link_local=$2
    local asn=$3

    echo ""
    print_info "=== BIRD BGP配置示例 ==="
    cat <<EOF

# 在 /etc/bird/bird.conf 中添加:
protocol bgp ibgp_${interface_name} {
    local as ${asn};
    neighbor ${peer_link_local}%${interface_name} as ${asn};

    ipv4 {
        import all;
        export all;
        next hop self;
    };

    ipv6 {
        import all;
        export all;
        next hop self;
    };
}

EOF
}

# 交互式配置
interactive_setup() {
    echo "=========================================="
    echo "  DN42 iBGP WireGuard隧道配置向导"
    echo "=========================================="
    echo ""
    print_note "此脚本用于在你的多个DN42节点之间建立iBGP连接"
    echo ""

    # 获取节点信息
    read -p "节点名称 (例如: node1, hk, us): " NODE_NAME
    if [ -z "$NODE_NAME" ]; then
        print_error "节点名称不能为空"
        exit 1
    fi

    # 接口名称
    INTERFACE_NAME="dn42-${NODE_NAME}"
    print_info "接口名称: ${INTERFACE_NAME}"

    # 本地DN42 IPv4地址
    echo ""
    print_note "请输入本节点的DN42 IPv4地址 (必须在172.20.0.0/14范围内)"
    while true; do
        read -p "本地DN42 IPv4 (例如: 172.20.1.1/32): " LOCAL_IPV4
        if validate_dn42_ip "${LOCAL_IPV4%%/*}" "ipv4"; then
            break
        fi
    done

    # 本地DN42 IPv6地址
    echo ""
    print_note "请输入本节点的DN42 IPv6地址 (必须在fd00::/8范围内)"
    while true; do
        read -p "本地DN42 IPv6 (例如: fdxx:xxxx:xxxx::1/64): " LOCAL_IPV6
        if validate_dn42_ip "${LOCAL_IPV6%%/*}" "ipv6"; then
            break
        fi
    done

    # 监听端口
    read -p "WireGuard监听端口 [默认: 51820]: " LISTEN_PORT
    LISTEN_PORT=${LISTEN_PORT:-51820}

    # MTU设置
    read -p "MTU大小 [默认: ${DEFAULT_MTU}]: " MTU
    MTU=${MTU:-${DEFAULT_MTU}}

    # 获取或生成密钥
    echo ""
    keys=$(get_or_generate_keys)
    PRIVATE_KEY=$(echo "$keys" | cut -d'|' -f1)
    PUBLIC_KEY=$(echo "$keys" | cut -d'|' -f2)

    echo ""
    echo "=========================================="
    print_info "本节点公钥:"
    echo "${PUBLIC_KEY}"
    echo "=========================================="
    print_warning "请将此公钥发送给对端节点"
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

    # 对端DN42 IPv4
    echo ""
    while true; do
        read -p "对端DN42 IPv4 (例如: 172.20.1.2/32): " PEER_IPV4
        if validate_dn42_ip "${PEER_IPV4%%/*}" "ipv4"; then
            break
        fi
    done

    # 对端DN42 IPv6
    while true; do
        read -p "对端DN42 IPv6 (例如: fdxx:xxxx:xxxx::2/128): " PEER_IPV6
        if validate_dn42_ip "${PEER_IPV6%%/*}" "ipv6"; then
            break
        fi
    done

    # 配置节点
    configure_dn42_node "$INTERFACE_NAME" "$LOCAL_IPV4" "$LOCAL_IPV6" "$LISTEN_PORT" \
                        "$PEER_PUBLIC_KEY" "$PEER_ENDPOINT" "$PEER_IPV4" "$PEER_IPV6" \
                        "$PRIVATE_KEY" "$MTU"

    # 询问是否启动
    echo ""
    read -p "是否立即启动WireGuard接口? [Y/n]: " start_now
    start_now=${start_now:-Y}

    if [[ "$start_now" =~ ^[Yy]$ ]]; then
        start_interface "$INTERFACE_NAME"
        show_status "$INTERFACE_NAME"
    fi

    # 询问是否显示BGP配置示例
    echo ""
    read -p "是否显示BIRD BGP配置示例? [Y/n]: " show_bgp
    show_bgp=${show_bgp:-Y}

    if [[ "$show_bgp" =~ ^[Yy]$ ]]; then
        read -p "你的DN42 ASN (例如: 4242421234): " ASN
        if [ -n "$ASN" ]; then
            # 生成对端的link-local地址
            PEER_LINK_LOCAL=$(generate_link_local "dn42-peer")
            print_warning "注意: 对端的link-local地址需要从对端节点获取"
            print_note "在对端节点运行: ip addr show ${INTERFACE_NAME} | grep fe80"
            generate_bgp_example "$INTERFACE_NAME" "fe80::xxxx:xxxx:xxxx:xxxx" "$ASN"
        fi
    fi

    echo ""
    print_info "配置完成！"
    echo ""
    print_note "下一步操作:"
    echo "1. 在对端节点运行相同的脚本进行配置"
    echo "2. 测试连接: ping ${PEER_IPV4%%/*}"
    echo "3. 配置BIRD进行BGP peering"
    echo "4. 使用 'birdc show protocols' 检查BGP状态"
}

# 清除临时文件
cleanup() {
    rm -f /tmp/wg_detected_keys.tmp
}

# 设置退出时清理
trap cleanup EXIT

# 主函数
main() {
    check_root
    check_wireguard
    interactive_setup
}

# 运行主函数
main
