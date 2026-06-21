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
SERVICE_FILE="/etc/systemd/system/kcptun-server.service"

show_menu() {
    echo -e "${BLUE}===============================================${PLAIN}"
    echo -e "       ${GREEN}Kcptun-Rust 服务端一键部署工具${PLAIN}"
    echo -e "  目前状态: $(check_status)"
    echo -e "${BLUE}===============================================${PLAIN}"
    echo " 1. 安装/重置服务 (随机配置并注册自启)"
    echo " 2. 修改代理目标地址(SS后端)并重启"
    echo " 3. 启动 Kcptun"
    echo " 4. 停止 Kcptun"
    echo " 5. 重启 Kcptun"
    echo " 6. 查看服务运行状态"
    echo " 7. 查看实时日志"
    echo " 8. 卸载服务"
    echo " 0. 退出脚本"
    echo -e "${BLUE}===============================================${PLAIN}"
    read -p "请输入选项 [0-8]: " num
    case "$num" in
        1) install_kcptun ;;
        2) modify_target ;;
        3) start_service ;;
        4) stop_service ;;
        5) restart_service ;;
        6) show_status ;;
        7) show_logs ;;
        8) uninstall_kcptun ;;
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

install_kcptun() {
    echo -e "${BLUE}[1/5] 下发二进制文件...${PLAIN}"
    
    # 检测同目录下是否有解压好的 kcptun-server 二进制
    if [ -f "./kcptun-server" ]; then
        cp ./kcptun-server "${INSTALL_DIR}/kcptun-server"
        chmod +x "${INSTALL_DIR}/kcptun-server"
    elif [ -f "${INSTALL_DIR}/kcptun-server" ]; then
        echo -e "${YELLOW}已检测到系统内存在 kcptun-server，准备重新配置${PLAIN}"
    else
        echo -e "${RED}缺失安装文件！请保证 kcptun-server 存在于脚本相同目录。${PLAIN}"
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

    # 2. 动态生成
    local r_port=$(get_unused_port)
    local r_key=$(generate_random_key)
    
    # 3. 我们采用优化的配置模版：
    # - mode 使用高性能的 fast2 
    # - dscp 设为 46 (高优先级，网通节点优化)
    # - nocomp 生产环境建议设为 false (在多文本或重复包场景下能节约 30%+ 流量带宽)
    # - acknodelay 全面加快 KCP 确认包反馈，大幅度提升大流量吞吐
    cat > "${CONF_FILE}" <<EOF
{
  "listen": "0.0.0.0:${r_port}",
  "target": "${ss_target}",
  "key": "${r_key}",
  "crypt": "aes",
  "mode": "fast2",
  "mtu": 1350,
  "sndwnd": 1024,
  "rcvwnd": 1024,
  "datashard": 10,
  "parityshard": 3,
  "dscp": 46,
  "nocomp": false,
  "acknodelay": true,
  "sockbuf": 4194304,
  "smuxver": 2,
  "smuxbuf": 4194304,
  "framesize": 8192,
  "streambuf": 2097152,
  "keepalive": 10,
  "quiet": false
}
EOF

    echo -e "${GREEN}配置文件已生成至: ${CONF_FILE}${PLAIN}"

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
    systemctl start kcptun-server

    echo -e "${BLUE}[5/5] 获取当前主机公网 IP，为您生成连接卡片...${PLAIN}"
    local public_ip=$(curl -s -4 ip.sb || curl -s -4 ifconfig.me || echo "VPS_IP")

    echo -e "${GREEN}==================================================================${PLAIN}"
    echo -e "                     🎉 部署并运行成功 🎉"
    echo -e "${GREEN}==================================================================${PLAIN}"
    echo -e " ${BLUE}服务端端口 (UDP):${PLAIN}  ${YELLOW}${r_port}${PLAIN}"
    echo -e " ${BLUE}通信连接密钥 (Key):${PLAIN} ${YELLOW}${r_key}${PLAIN}"
    echo -e " ${BLUE}加速响应模式 (Mode):${PLAIN} ${YELLOW}fast2${PLAIN}"
    echo -e " ${BLUE}多用户支持:${PLAIN}         ${YELLOW}是 (高并发多路复用已激活)${PLAIN}"
    echo -e " ${BLUE}服务目标地址 (SS):${PLAIN}  ${YELLOW}${ss_target}${PLAIN}"
    echo -e "${GREEN}==================================================================${PLAIN}"
    echo -e " ${GREEN}客户端对应参数卡片 (直接对照 Android 端填入即可):${PLAIN}"
    echo -e " 协议机制 (Protocol): KCP"
    echo -e " 服务器地址:        ${public_ip}"
    echo -e " 端口:              ${r_port}"
    echo -e " 密码:              ${r_key}"
    echo -e " 加密:              aes"
    echo -e " 加速模式 (mode):   fast2"
    echo -e " 前向纠错 (FEC):    datashard=10, parityshard=3"
    echo -e " 接收窗口 (rcvwnd): 1024"
    echo -e " 发送窗口 (sndwnd): 1024"
    echo -e " 报文压缩 (nocomp): false (启用压缩)"
    echo -e "${GREEN}==================================================================${PLAIN}"
    echo -e " ${GREEN}一键复制配置字符串 (适合复制粘贴到 SS 软件/控制台插件配置中):${PLAIN}"
    echo -e "${YELLOW}key=${r_key};crypt=aes;mode=fast2;mtu=1350;sndwnd=1024;rcvwnd=1024;datashard=10;parityshard=3;acknodelay=1;sockbuf=4194304;smuxver=2;smuxbuf=4194304;framesize=8192;streambuf=2097152;keepalive=10${PLAIN}"
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
