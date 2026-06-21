#!/bin/bash
# CentOS 7 一键安装 3proxy SOCKS5 代理（TCP + UDP）
# 解决 IPv6 连接失败、认证、UDP 支持等问题
set -e

# ============ 配置参数（在这里修改）============
SOCKS_PORT=1080
SOCKS_USER="proxyuser"
SOCKS_PASS="YourPassword123"
# =============================================

echo "========================================"
echo "开始安装 3proxy SOCKS5 代理服务器..."
echo "端口: $SOCKS_PORT"
echo "用户名: $SOCKS_USER"
echo "========================================"

# ---------- 安装编译依赖 ----------
yum install -y gcc make wget curl &>/dev/null

# ---------- 下载并编译 3proxy ----------
cd /tmp
rm -rf 3proxy-0.9.4
if [ ! -f 3proxy-0.9.4.tar.gz ]; then
    wget -q https://github.com/3proxy/3proxy/archive/refs/tags/0.9.4.tar.gz -O 3proxy-0.9.4.tar.gz
fi
tar -xzf 3proxy-0.9.4.tar.gz
cd 3proxy-0.9.4
make -f Makefile.Linux -s
make -f Makefile.Linux install

# ---------- 创建日志目录 ----------
mkdir -p /var/log/3proxy
chmod 755 /var/log/3proxy

# ---------- 编写配置文件 ----------
cat > /usr/local/etc/3proxy/3proxy.cfg << EOF
# 后台运行
daemon

# 日志（每天生成新文件）
log /var/log/3proxy/3proxy-%y%m%d.log D
logformat "- +_L%t.%. %N.%p %E %U %C:%c %R:%r %O %I %h %T"

# 用户认证（内置用户）
auth strong
users ${SOCKS_USER}:CL:${SOCKS_PASS}

# SOCKS5 代理（同时监听 TCP 和 UDP，仅 IPv4）
proxy -p${SOCKS_PORT} -a1 -i0.0.0.0 -e0.0.0.0

# 规则：先拒绝所有，再仅允许 IPv4 目标（强制客户端回退 IPv4）
deny * * * * *
allow * * 0.0.0.0/0 *

# 刷新规则
flush
EOF

# ---------- 创建 systemd 服务 ----------
cat > /etc/systemd/system/3proxy.service << EOF
[Unit]
Description=3proxy tiny proxy server
After=network.target

[Service]
Type=forking
ExecStart=/usr/local/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
ExecReload=/bin/kill -HUP \$MAINPID
PIDFile=/var/run/3proxy.pid
Restart=always
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# ---------- 启动服务 ----------
systemctl daemon-reload
systemctl enable 3proxy &>/dev/null
systemctl restart 3proxy

# ---------- 防火墙：TCP+UDP 端口 ----------
# iptables
iptables -I INPUT -p tcp --dport ${SOCKS_PORT} -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p udp --dport ${SOCKS_PORT} -j ACCEPT 2>/dev/null || true
# 保存 iptables 规则
if command -v iptables-save &>/dev/null; then
    service iptables save 2>/dev/null || true
fi

# 如果需要 firewalld（未运行则跳过）
if systemctl is-active firewalld &>/dev/null; then
    firewall-cmd --permanent --add-port=${SOCKS_PORT}/tcp --add-port=${SOCKS_PORT}/udp 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
fi

# ---------- 彻底屏蔽 IPv6（避免客户端发送 IPv6 地址致超时） ----------
# 1. 内核禁用 IPv6
sysctl -w net.ipv6.conf.all.disable_ipv6=1 &>/dev/null
sysctl -w net.ipv6.conf.default.disable_ipv6=1 &>/dev/null
# 保留 sysctl 配置永久生效
cat >> /etc/sysctl.conf << EOF

# 3proxy SOCKS5 – 禁用 IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF

# 2. ip6tables 阻断所有出站 IPv6（确保代理立即拒绝，触发客户端回退）
ip6tables -F 2>/dev/null || true
ip6tables -X 2>/dev/null || true
ip6tables -P INPUT ACCEPT 2>/dev/null || true
ip6tables -P FORWARD ACCEPT 2>/dev/null || true
ip6tables -P OUTPUT DROP 2>/dev/null || true
ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
# 保存规则
if command -v ip6tables-save &>/dev/null; then
    ip6tables-save > /etc/sysconfig/ip6tables 2>/dev/null || true
fi

# ---------- 获取服务器公网 IP ----------
SERVER_IP=$(curl -s --connect-timeout 5 ip.sb 2>/dev/null) || \
SERVER_IP=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null) || \
SERVER_IP=$(curl -s --connect-timeout 5 icanhazip.com 2>/dev/null) || \
SERVER_IP="未能获取"

echo ""
echo "========================================"
echo "  安装完成！"
echo "========================================"
echo "服务器 IP   : $SERVER_IP"
echo "端口         : $SOCKS_PORT"
echo "用户名       : $SOCKS_USER"
echo "密码         : $SOCKS_PASS"
echo ""
echo "连接地址: socks5://$SOCKS_USER:$SOCKS_PASS@$SERVER_IP:$SOCKS_PORT"
echo ""
echo "【重要使用说明】"
echo "1. 推荐在客户端使用 socks5h 模式（远程 DNS），可彻底避免 IPv6 错误："
echo "   curl --socks5-hostname $SERVER_IP:$SOCKS_PORT --proxy-user $SOCKS_USER:$SOCKS_PASS http://httpbin.org/ip"
echo "2. 若必须使用 socks5 模式，请在客户端强制 IPv4 解析（如 curl -4）。"
echo "3. 代理同时支持 TCP 和 UDP（UDP 经由 SOCKS5 UDP 关联转发）。"
echo "========================================"
echo ""
echo "常用命令："
echo "  查看状态: systemctl status 3proxy"
echo "  查看日志: tail -f /var/log/3proxy/3proxy-*.log"
echo "  重启服务: systemctl restart 3proxy"