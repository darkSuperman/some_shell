#!/bin/bash

# ==============================================================================
#  Kcptun-Rust 一键安装/管理及部署服务脚本
#  支持系统: Debian, Ubuntu, CentOS, Rocky Linux, Almalinux (Systemd)
# ==============================================================================

# 颜色控制
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PLAIN='\033[0m'

# 检查是否为 Root 运行
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}"
    exit 1
fi

INSTALL_DIR="/usr/local/bin"
CONF_DIR="/etc/kcptun"
CONF_FILE="${CONF_DIR}/server.json"
CLIENT_OPTS_FILE="${CONF_DIR}/client-options.conf"
SERVICE_FILE="/etc/systemd/system/kcptun-server.service"

show_menu() {
    echo -e "${BLUE}===============================================${PLAIN}"
    echo -e "       ${GREEN}Kcptun-Rust 服务端一键部署工具${PLAIN}"
    echo -e "  目前状态: $(check_status)"
    echo -e "${BLUE}===============================================${PLAIN}"
    echo " 1. 安装/重置服务 (随机配置并注册自启)"
    echo " 2. 启动 Kcptun"
    echo " 3. 停止 Kcptun"
    echo " 4. 查看服务运行状态"
    echo " 5. 查看实时日志"
    echo " 6. 查看当前客户端参数字符串"
    echo " 7. 卸载服务"
    echo " 0. 退出脚本"
    echo -e "${BLUE}===============================================${PLAIN}"
    read -p "请输入选项 [0-7]: " num
    case "$num" in
        1) install_kcptun ;;
        2) start_service ;;
        3) stop_service ;;
        4) show_status ;;
        5) show_logs ;;
        6) show_client_options ;;
        7) uninstall_kcptun ;;
        0) exit 0 ;;
        *) echo -e "${RED}请输入正确的数字！${PLAIN}"; sleep 1; show_menu ;;
    esac
}

check_status() {
    if [ ! -f "${INSTALL_DIR}/kcptun-server" ]; then
        echo -e "${RED}未安装${PLAIN}"
    elif systemctl is-active kcptun-server >/dev/null 2>&1; then
        echo -e "${GREEN}正在运行${PLAIN}"
    else
        echo -e "${YELLOW}已停止${PLAIN}"
    fi
}

get_unused_port() {
    # 随机产生 20000 - 40000 的端口，并检测冲突
    while true; do
        local rand_port=$((RANDOM % 20001 + 20000))
        if ! ss -tuln | grep -q ":$rand_port "; then
            echo "$rand_port"
            break
        fi
    done
}

generate_random_key() {
    # 使用 /dev/urandom 产生安全的随机 16 位大写小写英文字母+数字组成的 Key
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16
}

prompt_uint() {
    local prompt="$1"
    local default_value="$2"
    local min_value="$3"
    local max_value="$4"
    local input_value=""

    read -p "${prompt} [默认: ${default_value}]: " input_value
    if [ -z "${input_value}" ]; then
        echo "${default_value}"
        return
    fi

    if [[ "${input_value}" =~ ^[0-9]+$ ]] && [ "${input_value}" -ge "${min_value}" ] && [ "${input_value}" -le "${max_value}" ]; then
        echo "${input_value}"
    else
        echo -e "${YELLOW}输入不合法，自动回退采用默认值 ${default_value}${PLAIN}" >&2
        echo "${default_value}"
    fi
}

prompt_bool() {
    local prompt="$1"
    local default_value="$2"
    local input_value=""

    read -p "${prompt} [默认: ${default_value}]: " input_value
    if [ -z "${input_value}" ]; then
        echo "${default_value}"
        return
    fi

    case "${input_value,,}" in
        true|1|yes|y|on)
            echo "true"
            ;;
        false|0|no|n|off)
            echo "false"
            ;;
        *)
            echo -e "${YELLOW}输入不合法，自动回退采用默认值 ${default_value}${PLAIN}" >&2
            echo "${default_value}"
            ;;
    esac
}

json_value() {
    local key="$1"
    local default_value="$2"

    if [ ! -f "${CONF_FILE}" ]; then
        echo "${default_value}"
        return
    fi

    local value
    value=$(grep -m1 -oE '"'"${key}"'"[[:space:]]*:[[:space:]]*("[^"]*"|true|false|[0-9]+)' "${CONF_FILE}" \
        | sed -E 's/^[^:]+:[[:space:]]*"?//; s/"$//')

    if [ -n "${value}" ]; then
        echo "${value}"
    else
        echo "${default_value}"
    fi
}

client_only_value() {
    local key="$1"
    local default_value="$2"

    if [ ! -f "${CLIENT_OPTS_FILE}" ]; then
        echo "${default_value}"
        return
    fi

    local value
    value=$(grep -m1 -E '^'"${key}"'=' "${CLIENT_OPTS_FILE}" | cut -d= -f2-)
    if [ -n "${value}" ]; then
        echo "${value}"
    else
        echo "${default_value}"
    fi
}

bool_to_plugin_flag() {
    if [ "$1" = "true" ]; then
        echo "1"
    else
        echo "0"
    fi
}

build_client_options_string() {
    local r_key=$(json_value key "it's a secrect")
    local r_crypt=$(json_value crypt aes)
    local r_mode=$(json_value mode fast)
    local r_mtu=$(json_value mtu 1250)
    local r_sndwnd=$(json_value sndwnd 512)
    local r_rcvwnd=$(json_value rcvwnd 512)
    local r_datashard=$(json_value datashard 10)
    local r_parityshard=$(json_value parityshard 3)
    local r_dscp=$(json_value dscp 0)
    local r_acknodelay=$(bool_to_plugin_flag "$(json_value acknodelay false)")
    local r_sockbuf=$(json_value sockbuf 4194304)
    local r_smuxver=$(json_value smuxver 2)
    local r_smuxbuf=$(json_value smuxbuf 4194304)
    local r_framesize=$(json_value framesize 8192)
    local r_streambuf=$(json_value streambuf 2097152)
    local r_keepalive=$(json_value keepalive 15)
    local r_conn=$(client_only_value conn 1)
    local r_autoexpire=$(client_only_value autoexpire 0)

    local options="key=${r_key};crypt=${r_crypt};mode=${r_mode};conn=${r_conn};autoexpire=${r_autoexpire};mtu=${r_mtu};sndwnd=${r_sndwnd};rcvwnd=${r_rcvwnd};datashard=${r_datashard};parityshard=${r_parityshard};dscp=${r_dscp};acknodelay=${r_acknodelay};sockbuf=${r_sockbuf};smuxver=${r_smuxver};smuxbuf=${r_smuxbuf};framesize=${r_framesize};streambuf=${r_streambuf};keepalive=${r_keepalive}"
    echo "${options}"
}

install_kcptun() {
    echo -e "${BLUE}[1/5] 下发二进制文件...${PLAIN}"
    
    # 只要检测脚本当前目录有没有 kcptun-server 二进制文件就够了
    if [ -f "./kcptun-server" ]; then
        echo -e "${GREEN}检测到当前目录下的 kcptun-server 二进制文件，正在安装...${PLAIN}"
        cp ./kcptun-server "${INSTALL_DIR}/kcptun-server"
        chmod +x "${INSTALL_DIR}/kcptun-server"
    elif [ -f "./target/x86_64-unknown-linux-musl/release/kcptun-server" ]; then
        echo -e "${GREEN}检测到完全静态链接编译的 target/x86_64-unknown-linux-musl/release/kcptun-server，正在安装...${PLAIN}"
        cp "./target/x86_64-unknown-linux-musl/release/kcptun-server" "${INSTALL_DIR}/kcptun-server"
        chmod +x "${INSTALL_DIR}/kcptun-server"
    elif [ -f "./target/release/kcptun-server" ]; then
        echo -e "${GREEN}检测到本地编译生成的 target/release/kcptun-server，正在安装...${PLAIN}"
        cp ./target/release/kcptun-server "${INSTALL_DIR}/kcptun-server"
        chmod +x "${INSTALL_DIR}/kcptun-server"
    elif [ -f "${INSTALL_DIR}/kcptun-server" ]; then
        echo -e "${YELLOW}已检测到系统内存在 kcptun-server，准备重新配置${PLAIN}"
    else
        echo -e "${RED}错误: 无法找到安装源！请将编译好的 \`kcptun-server\` 放入脚本当前目录。${PLAIN}"
        exit 1
    fi

    echo -e "${BLUE}[2/5] 动态组装 KCP 服务端最合理配置文件...${PLAIN}"
    mkdir -p "${CONF_DIR}"

    # 1. 用户输入 Shadowsocks 监听端口，并进行检测
    local default_ss="127.0.0.1:12948"
    echo -e "请输入服务器本地 Shadowsocks (SS) 的 TCP 连接地址或端口。"
    echo -e "可以输入纯端口号（例如 ${YELLOW}12948${PLAIN}，会自动对应 127.0.0.1:12948）"
    read -p "请输入 [默认: 12948]: " ss_input
    
    local ss_target=""
    local check_port=""

    if [ -z "$ss_input" ]; then
        ss_target="127.0.0.1:12948"
        check_port="12948"
    elif [[ "$ss_input" =~ ^[0-9]+$ ]]; then
        ss_target="127.0.0.1:${ss_input}"
        check_port="${ss_input}"
    else
        ss_target="${ss_input}"
        if [[ "$ss_input" =~ :([0-9]+)$ ]]; then
            check_port="${BASH_REMATCH[1]}"
        fi
    fi

    # 检测本地 TCP 端口是否在监听
    if [ -n "$check_port" ]; then
        echo -e "${YELLOW}正在检测本地 TCP 端口 ${check_port} 的状态...${PLAIN}"
        if ! ss -tln | grep -q -E "(^|:)${check_port}([[:space:]]|$)"; then
            echo -e "${RED}警告: 未检测到本地 TCP 端口 ${check_port} 处于监听状态！${PLAIN}"
            echo -e "${YELLOW}这通常意味着您的 Shadowsocks (SS) 服务尚未启动，或者配置的端口不正确。${PLAIN}"
            read -p "是否忽略此警告并继续部署？[y/N]: " ignore_warn
            if [[ ! "$ignore_warn" =~ ^[Yy]$ ]]; then
                echo -e "${RED}部署已被用户终止，请先开启 Shadowsocks 并确保端口处于监听状态。${PLAIN}"
                sleep 1
                show_menu
                return
            fi
        else
            echo -e "${GREEN}检测通过: 本地 TCP 端口 ${check_port} 正在监听中。${PLAIN}"
        fi
    fi

    # 2. 动态随机生成备用参数，并提供交互式配置
    local random_port=$(get_unused_port)
    local r_key=$(generate_random_key)

    echo -e "\n接下来配置 KCP 服务端监听设置（直接回车采用推荐默认值）："
    
    # 用户自定义监听端口
    read -p "请输入 KCP 监听端口 [默认随机: ${random_port}]: " input_port
    local r_port="${random_port}"
    if [ -n "${input_port}" ]; then
        if [[ "${input_port}" =~ ^[0-9]+$ ]] && [ "${input_port}" -ge 1 ] && [ "${input_port}" -le 65535 ]; then
            r_port="${input_port}"
        else
            echo -e "${YELLOW}输入端口不合法，自动回退采用随机端口 ${random_port}${PLAIN}"
        fi
    fi

    # 用户选择加密方式
    echo -e "请选择加密算法 (crypt) [可选项: aes, aes-192, aes-256, tea, xtea, blowfish, none]"
    read -p "请输入 [默认: aes]: " input_crypt
    local r_crypt="aes"
    if [ -n "${input_crypt}" ]; then
        r_crypt="${input_crypt}"
    fi

    # 用户选择加速模式
    echo -e "请选择 KCP 工作模式 (mode) [可选项: fast3, fast2, fast, normal]"
    read -p "请输入 [默认: fast2]: " input_mode
    local r_mode="fast2"
    if [ -n "${input_mode}" ]; then
        r_mode="${input_mode}"
    fi

    echo -e "\n接下来配置 KCP 传输参数（移动网络/VPN 场景建议从保守值开始）："
    local r_mtu=$(prompt_uint "请输入 MTU" 1350 576 1500)
    local r_sndwnd=$(prompt_uint "请输入发送窗口 sndwnd" 512 1 65535)
    local r_rcvwnd=$(prompt_uint "请输入接收窗口 rcvwnd" 512 1 65535)
    local r_dscp=$(prompt_uint "请输入 DSCP/TOS 标记" 0 0 63)
    local r_acknodelay=$(prompt_bool "是否开启 acknodelay？(输入 true 开启 / false 关闭)" false)
    local r_keepalive=$(prompt_uint "请输入 smux keepalive 秒数(Go版默认为10s，生产建议10s-30s)" 10 1 300)
    local r_bandwidth_mbps=$(prompt_uint "请输入服务器总带宽 Mbps，用于计算负载" 200 1 100000)
    
    # 自动探测系统当前的默认网卡，防止写死 eth0 导致非 eth0 命名网卡的机器上采样报错
    local autodetect_iface=$(ip route show | grep '^default' | awk '{print $5}' | head -n1)
    if [ -z "${autodetect_iface}" ]; then
        autodetect_iface="eth0"
    fi
    read -p "请输入出口网卡名 [默认: ${autodetect_iface}]: " r_bandwidth_iface
    if [ -z "${r_bandwidth_iface}" ]; then
        r_bandwidth_iface="${autodetect_iface}"
    fi
    
    # 提前获取当前推荐的公网 IP 供默认输入
    local detected_ip=$(curl -s -4 ip.sb || curl -s -4 ifconfig.me || echo "127.0.0.1")
    read -p "请输入当前节点的公网 IP 地址 (用于向接口提交和生成参数) [默认: ${detected_ip}]: " r_host
    if [ -z "${r_host}" ]; then
        r_host="${detected_ip}"
    fi

    read -p "请输入负载信息同步接口 API 地址 (status_url) [默认: https://tauri.vip]: " r_status_url
    if [ -z "${r_status_url}" ]; then
        r_status_url="https://tauri.vip"
    fi
    local r_conn=$(prompt_uint "请输入客户端 KCP 连接数 conn（仅写入 Android 插件参数）" 1 1 16)
    local r_autoexpire=$(prompt_uint "请输入客户端自动重建连接秒数 autoexpire，0 表示关闭（仅写入 Android 插件参数）" 60 0 86400)
    local r_acknodelay_opt=0
    if [ "${r_acknodelay}" = "true" ]; then
        r_acknodelay_opt=1
    fi
    
    # 3. 我们采用优化的配置模版：
    # - mode 使用选定工作模式
    # - dscp 默认 0，避免运营商或 VPS 网络对 high 优先级标记做限速/丢弃
    # - nocomp 生产环境建议设为 false (在多文本或重复包场景下能节约 30%+ 流量带宽)
    # - acknodelay 默认关闭，弱网下更稳；需要更低延迟时可手动开启
    cat > "${CONF_FILE}" <<EOF
{
    "listen": "0.0.0.0:${r_port}",
    "target": "${ss_target}",
    "key": "${r_key}",
    "crypt": "${r_crypt}",
    "mode": "${r_mode}",
    "mtu": ${r_mtu},
    "sndwnd": ${r_sndwnd},
    "rcvwnd": ${r_rcvwnd},
    "datashard": 10,
    "parityshard": 3,
    "dscp": ${r_dscp},
    "nocomp": false,
    "acknodelay": ${r_acknodelay},
    "sockbuf": 4194304,
    "smuxver": 2,
    "smuxbuf": 4194304,
    "framesize": 8192,
    "streambuf": 2097152,
    "keepalive": ${r_keepalive},
    "bandwidth_mbps": ${r_bandwidth_mbps},
    "bandwidth_iface": "${r_bandwidth_iface}",
    "per_conn_limit_mbps": 40,
    "status_url": "${r_status_url}",
    "host": "${r_host}",
    "quiet": false
}
EOF

    cat > "${CLIENT_OPTS_FILE}" <<EOF
conn=${r_conn}
autoexpire=${r_autoexpire}
EOF

    echo -e "${GREEN}配置文件已生成至: ${CONF_FILE}${PLAIN}"
    echo -e "${GREEN}客户端附加参数已保存至: ${CLIENT_OPTS_FILE}${PLAIN}"

    echo -e "${BLUE}[3/5] 注册并建立 Systemd 服务守护监控...${PLAIN}"
    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Kcptun Rust Server Service
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${CONF_DIR}
ExecStart=${INSTALL_DIR}/kcptun-server -c ${CONF_FILE}
Restart=always
RestartSec=5
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    echo -e "${BLUE}[4/5] 启用并开启开机服务初始化...${PLAIN}"
    systemctl daemon-reload
    systemctl enable kcptun-server
    systemctl restart kcptun-server

    echo -e "${BLUE}[5/5] 配置防火墙开放端口...${PLAIN}"
    if command -v iptables >/dev/null 2>&1; then
        echo -e "正在使用 ${YELLOW}iptables${PLAIN} 开放 UDP 端口 ${YELLOW}${r_port}${PLAIN}..."
        iptables -I INPUT -p udp --dport "${r_port}" -j ACCEPT
        # 保存 iptables 规则以防止重启失效
        if command -v iptables-save >/dev/null 2>&1; then
            if [ -d "/etc/iptables" ]; then
                iptables-save > /etc/iptables/rules.v4
            elif [ -f "/etc/sysconfig/iptables" ]; then
                iptables-save > /etc/sysconfig/iptables
            fi
        fi
    fi

    if command -v ufw >/dev/null 2>&1 && systemctl is-active ufw >/dev/null 2>&1; then
        echo -e "正在使用 ${YELLOW}ufw${PLAIN} 开放 UDP 端口 ${YELLOW}${r_port}${PLAIN}..."
        ufw allow "${r_port}"/udp >/dev/null 2>&1
    fi

    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
        echo -e "正在使用 ${YELLOW}firewalld${PLAIN} 开放 UDP 端口 ${YELLOW}${r_port}${PLAIN}..."
        firewall-cmd --zone=public --add-port="${r_port}"/udp --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi

    echo -e "${BLUE}部署成功 🎉${PLAIN}"

    echo -e "${GREEN}==================================================================${PLAIN}"
    echo -e "                     🎉 部署并运行成功 🎉"
    echo -e "${GREEN}==================================================================${PLAIN}"
    echo -e " ${GREEN}客户端对应参数卡片 (直接对照 Android 端填入即可):${PLAIN}"
    echo -e " 服务器地址:        ${r_host}:${r_port}"
    echo -e " 密码:              ${r_key}"
    echo -e " 加密:              ${r_crypt}"
    echo -e " 加速模式 (mode):   ${r_mode}"
    echo -e " MTU:               ${r_mtu}"
    echo -e " 前向纠错 (FEC):    datashard=10, parityshard=3"
    echo -e " 接收窗口 (rcvwnd): ${r_rcvwnd}"
    echo -e " 发送窗口 (sndwnd): ${r_sndwnd}"
    echo -e " DSCP:              ${r_dscp}"
    echo -e " ACK NoDelay:       ${r_acknodelay}"
    echo -e " KeepAlive:         ${r_keepalive}s"
    echo -e " 总带宽 Mbps:       ${r_bandwidth_mbps}"
    echo -e " 出口网卡:          ${r_bandwidth_iface:-自动检测}"
    echo -e " 客户端连接数 conn: ${r_conn}"
    echo -e " 自动重建 autoexpire: ${r_autoexpire}s"
    echo -e " 报文压缩 (nocomp): false (启用压缩)"
    echo -e "${GREEN}==================================================================${PLAIN}"
    echo -e " ${GREEN}一键复制配置字符串 (适合复制粘贴到 SS 软件/控制台插件配置中):${PLAIN}"
    echo -e "${YELLOW}$(build_client_options_string)${PLAIN}"
    echo -e "${GREEN}==================================================================${PLAIN}"
    read -n 1 -s -r -p "按任意键返回主菜单"
    show_menu
}

modify_target() {
    if [ ! -f "${CONF_FILE}" ]; then
        echo -e "${RED}未检测到配置文件，请先完成安装！${PLAIN}"
        sleep 1
        show_menu
        return
    fi
    local current_target=$(grep -po '"target":\s*"\K[^"]+' "${CONF_FILE}")
    echo -e "当前映射的代理后端目标为: ${YELLOW}${current_target}${PLAIN}"
    read -p "请输入新的 Shadowsocks 后端监听地址（格式如 127.0.0.1:12948）: " new_target
    if [ -z "$new_target" ]; then
        echo "输入为空，取消修改。"
    else
        sed -i "s/\"target\":\s*\"[^\"]*\"/\"target\": \"$new_target\"/g" "${CONF_FILE}"
        echo -e "${GREEN}修改成功！正在重新启动服务生效...${PLAIN}"
        systemctl restart kcptun-server
    fi
    sleep 1
    show_menu
}

start_service() {
    systemctl start kcptun-server
    echo -e "${GREEN}服务启动命令已下发。${PLAIN}"
    sleep 1
    show_menu
}

stop_service() {
    systemctl stop kcptun-server
    echo -e "${YELLOW}服务已停止。${PLAIN}"
    sleep 1
    show_menu
}

restart_service() {
    systemctl restart kcptun-server
    echo -e "${GREEN}服务重启中...${PLAIN}"
    sleep 1
    show_menu
}

show_status() {
    echo -e "${BLUE}=== Kcptun-Server 运行状态 ===${PLAIN}"
    systemctl status kcptun-server
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单"
    show_menu
}

show_logs() {
    echo -e "${BLUE}=== Kcptun-Server 实时运行日志 (Ctrl + C 退出) ===${PLAIN}"
    journalctl -u kcptun-server -f -n 50
    show_menu
}

show_client_options() {
    if [ ! -f "${CONF_FILE}" ]; then
        echo -e "${RED}未检测到配置文件，请先完成安装！${PLAIN}"
    else
        echo -e "${BLUE}=== 当前客户端插件参数字符串 ===${PLAIN}"
        echo -e "${YELLOW}$(build_client_options_string)${PLAIN}"
    fi
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单"
    show_menu
}

uninstall_kcptun() {
    read -p "确认要卸载服务并删除配置文件吗？[y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        systemctl stop kcptun-server
        systemctl disable kcptun-server
        rm -f "${SERVICE_FILE}"
        rm -rf "${CONF_DIR}"
        rm -f "${INSTALL_DIR}/kcptun-server"
        systemctl daemon-reload
        echo -e "${GREEN}服务已干净卸载！${PLAIN}"
    else
        echo "已取消卸载。"
    fi
    sleep 1
    show_menu
}

# 脚本入口
show_menu
