#!/bin/bash

# 确保以 root 权限运行
if [ "$EUID" -ne 0 ]; then
    echo "错误：请以 root 权限运行此脚本。"
    exit 1
fi

echo "=========================================="
echo "      1. 开始配置系统环境与 BBR 加速...    "
echo "=========================================="

# 清理已有的重复配置，防止多次运行脚本时重复写入
sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf

echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

# 生效配置
sysctl -p

# 验证 BBR 是否开启成功
if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
    echo "BBR 加速配置应用成功！"
else
    echo "BBR 开启可能未成功，请检查系统内核是否支持（Linux 内核需 4.9 及以上）。"
fi
lsmod | grep bbr

echo "=========================================="
echo "      2. 开始下载与安装 Shadowsocks-Rust  "
echo "=========================================="

echo "正在下载 Shadowsocks-Rust 安装包..."
wget -O ss124.tar.xz https://github.com/darkSuperman/some_shell/raw/refs/heads/main/ss124.tar.xz

if [ ! -f ss124.tar.xz ]; then
    echo "错误：下载安装包失败，请检查网络。"
    exit 1
fi

echo "解压并安装二进制文件..."
tar -xf ss124.tar.xz
cp ssserver /usr/local/bin/
cp ssservice /usr/local/bin/
chmod +x /usr/local/bin/ssserver /usr/local/bin/ssservice

# 清理临时下载文件
rm -f ss124.tar.xz ssserver ssservice

echo "=========================================="
echo "      3. 生成配置与 Systemd 服务        "
echo "=========================================="

mkdir -p /etc/shadowsocks-rust

# 随机端口 (10000 - 19999)
PORT=$((RANDOM % 10000 + 10000))

# 随机 16 位密码（排除可能会破坏 JSON 格式的双引号和反斜杠）
PASSWORD=$(tr -dc 'A-Za-z0-9!@#%^*()_+' < /dev/urandom | head -c 16)

echo "生成配置文件..."
cat <<EOF > /etc/shadowsocks-rust/config.json
{
    "server": "0.0.0.0",
    "server_port": ${PORT},
    "password": "${PASSWORD}",
    "method": "aes-128-gcm",
    "timeout": 300,
    "fast_open": false,
    "mode": "tcp_and_udp"
}
EOF

echo "生成 systemd 服务..."
cat <<EOF > /etc/systemd/system/shadowsocks-rust.service
[Unit]
Description=Shadowsocks-Rust Server Service
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
LimitNOFILE=65535
ExecStart=/usr/local/bin/ssserver -c /etc/shadowsocks-rust/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

echo "启动 Shadowsocks-Rust 服务..."
systemctl daemon-reload
systemctl enable shadowsocks-rust
systemctl start shadowsocks-rust

echo "放行对应的 TCP/UDP 端口 (${PORT})..."
iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT
iptables -I INPUT -p udp --dport ${PORT} -j ACCEPT

echo "=========================================="
echo "      4. 运行恶意端口及垃圾流量封禁...    "
echo "=========================================="

# 下载 ban_iptables.sh
wget -N --no-check-certificate https://raw.githubusercontent.com/darkSuperman/some_shell/refs/heads/main/ban_iptables.sh

if [ -f ban_iptables.sh ]; then
    chmod +x ban_iptables.sh
    echo "正在执行自动封禁 (封禁 BT/PT/SPAM)..."
    # 直接运行 banall，免去手动选择和确认
    bash ban_iptables.sh banall
    rm -f ban_iptables.sh
    echo "恶意端口及流量封禁规则配置完成！"
else
    echo "警告：无法下载 ban_iptables.sh，跳过封禁步骤。"
fi

# 检查服务运行状态
echo "=========================================="
if systemctl is-active --quiet shadowsocks-rust; then
    echo "Shadowsocks-Rust 服务运行状态：正常"
else
    echo "警告：Shadowsocks-Rust 服务未能启动，请手动检查日志 (journalctl -u shadowsocks-rust)。"
fi

# 获取服务器公网 IP
SERVER_IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me || echo "您的服务器公网IP")

# 输出配置信息
echo ""
echo "=========================================="
echo "         Shadowsocks-Rust 配置信息        "
echo "=========================================="
echo " 服务器 IP (Server IP)  : ${SERVER_IP}"
echo " 端口 (Port)            : ${PORT}"
echo " 密码 (Password)        : ${PASSWORD}"
echo " 加密方式 (Method)      : aes-128-gcm"
echo "=========================================="
echo " 提示："
echo "   1. BBR 加速配置已应用。"
echo "   2. BT/PT/SPAM 恶意流量及对应端口已自动通过 iptables 封禁。"
echo "   3. 本机 iptables 已自动放行 Shadowsocks 端口 ${PORT}。"
echo "   4. 如您使用了云服务器厂商的服务（如腾讯云、阿里云等），"
echo "      请记得在云控制台的安全组/防火墙规则中，手动开放外网 TCP 和 UDP 的端口 ${PORT}。"
echo ""
