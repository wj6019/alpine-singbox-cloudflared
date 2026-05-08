#!/bin/sh
set -eu

trap 'echo ""; echo "❌ 出错：第 $LINENO 行执行失败。请把错误附近的终端输出发给我。"; exit 1' ERR

info() {
  echo ""
  echo "=================================================="
  echo " $1"
  echo "=================================================="
}

ok() {
  echo "✅ $1"
}

warn() {
  echo "⚠️  $1"
}

fail() {
  echo "❌ $1"
  exit 1
}

info "1. 修复 DNS"

cat > /etc/resolv.conf <<DNS
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 223.5.5.5
nameserver 119.29.29.29
DNS

cat /etc/resolv.conf
ok "DNS 已写入"

info "2. 清理旧文件"

rm -f /swapfile || true
rm -f /tmp/sing-box* /tmp/cloudflared || true
sync

ok "旧文件已清理"

info "3. 显示系统信息"

echo "Alpine 版本："
cat /etc/alpine-release || true

echo ""
echo "内存限制："
cat /sys/fs/cgroup/memory.max 2>/dev/null || echo "无法读取"

echo ""
echo "当前内存占用："
cat /sys/fs/cgroup/memory.current 2>/dev/null || echo "无法读取"

echo ""
echo "磁盘空间："
df -h

info "4. 输入部署参数"

read -p "请输入 UUID，直接回车自动生成：" UUID
if [ -z "$UUID" ]; then
  UUID="$(cat /proc/sys/kernel/random/uuid)"
fi
ok "使用 UUID：$UUID"

echo ""
read -p "请输入 Cloudflare Tunnel Token：" ARGO_TOKEN
[ -z "$ARGO_TOKEN" ] && fail "Token 不能为空"

echo ""
read -p "请输入完整域名，例如 argo.example.com：" DOMAIN
[ -z "$DOMAIN" ] && fail "域名不能为空"

info "5. 更新 Alpine 并安装基础工具"

apk update
apk add --no-cache ca-certificates wget nano openrc net-tools busybox-suid
update-ca-certificates || true

ok "基础工具安装完成"

info "6. 安装 sing-box"

apk add --no-cache \
  --repository=https://dl-cdn.alpinelinux.org/alpine/edge/main \
  --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community \
  sing-box

sing-box version
ok "sing-box 安装完成"

info "7. 安装 cloudflared"

cd /tmp
rm -f cloudflared

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)
    CF_ARCH="amd64"
    ;;
  aarch64|arm64)
    CF_ARCH="arm64"
    ;;
  *)
    fail "暂不支持当前架构：$ARCH"
    ;;
esac

wget -4 -O cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
chmod +x cloudflared
cp cloudflared /usr/local/bin/cloudflared
rm -f cloudflared

cloudflared --version
ok "cloudflared 安装完成"

info "8. 写入 sing-box 配置"

mkdir -p /etc/sing-box

cat > /etc/sing-box/config.json <<JSON
{
  "log": {
    "disabled": true
  },
  "inbounds": [
    {
      "type": "vless",
      "listen": "127.0.0.1",
      "listen_port": 8080,
      "users": [
        {
          "uuid": "$UUID"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/vless"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct"
    }
  ]
}
JSON

sing-box check -c /etc/sing-box/config.json
ok "sing-box 配置检查通过"

info "9. 写入 sing-box OpenRC 服务"

SB_BIN="$(command -v sing-box)"

cat > /etc/init.d/sing-box <<SERVICE
#!/sbin/openrc-run
name="sing-box"
command="$SB_BIN"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=0
pidfile="/run/sing-box.pid"

depend() {
    need net
}
SERVICE

chmod +x /etc/init.d/sing-box
ok "sing-box 服务已写入"

info "10. 写入 cloudflared OpenRC 服务"

cat > /etc/init.d/cloudflared <<SERVICE
#!/sbin/openrc-run
name="cloudflared"
command="/usr/local/bin/cloudflared"
command_args="--no-autoupdate --loglevel error --transport-loglevel error tunnel run --protocol http2 --token $ARGO_TOKEN"
command_background="yes"
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=0
pidfile="/run/cloudflared.pid"

depend() {
    need net
}
SERVICE

chmod +x /etc/init.d/cloudflared
ok "cloudflared 服务已写入"

info "11. 写入 sing-box watchdog"

cat > /root/watch_singbox_loop.sh <<'WATCHDOG'
#!/bin/sh
while true; do
  if ! netstat -tunlp 2>/dev/null | grep -q '127.0.0.1:8080'; then
    rc-service sing-box restart >/dev/null 2>&1
  fi
  sleep 20
done
WATCHDOG

chmod +x /root/watch_singbox_loop.sh

cat > /etc/init.d/singbox-watchdog <<'SERVICE'
#!/sbin/openrc-run
name="singbox-watchdog"
command="/root/watch_singbox_loop.sh"
command_background="yes"
pidfile="/run/singbox-watchdog.pid"

depend() {
    need net
}
SERVICE

chmod +x /etc/init.d/singbox-watchdog
ok "watchdog 已写入"

info "12. 启动服务"

rc-service sing-box restart
rc-update add sing-box default

sleep 2

if netstat -tunlp 2>/dev/null | grep -q "127.0.0.1:8080"; then
  ok "sing-box 已监听 127.0.0.1:8080"
else
  rc-service sing-box status || true
  fail "sing-box 没有监听 8080"
fi

rc-service cloudflared restart
rc-update add cloudflared default

sleep 5

if rc-service cloudflared status | grep -q "started"; then
  ok "cloudflared 已启动"
else
  warn "cloudflared 状态异常"
  echo "可以手动执行下面命令查看日志："
  echo "cloudflared --no-autoupdate tunnel run --protocol http2 --token $ARGO_TOKEN"
  exit 1
fi

rc-service singbox-watchdog restart
rc-update add singbox-watchdog default
ok "watchdog 已启动"

info "13. 最终状态检查"

echo "sing-box 状态："
rc-service sing-box status || true

echo ""
echo "cloudflared 状态："
rc-service cloudflared status || true

echo ""
echo "watchdog 状态："
rc-service singbox-watchdog status || true

echo ""
echo "8080 监听："
netstat -tunlp 2>/dev/null | grep 8080 || true

echo ""
echo "相关进程："
ps -o pid,rss,comm,args | grep -E 'sing-box|cloudflared|watch_singbox' | grep -v grep || true

echo ""
echo "当前内存占用："
cat /sys/fs/cgroup/memory.current 2>/dev/null || true

echo ""
echo "内存上限："
cat /sys/fs/cgroup/memory.max 2>/dev/null || true

echo ""
echo "磁盘空间："
df -h

info "14. 部署完成"

echo "Cloudflare Tunnel 后台 Public Hostname 必须配置为："
echo ""
echo "Hostname: $DOMAIN"
echo "Service Type: HTTP"
echo "Service URL: localhost:8080"

echo ""
echo "客户端参数："
echo "协议：VLESS"
echo "地址：$DOMAIN"
echo "端口：443"
echo "UUID：$UUID"
echo "传输：ws"
echo "路径：/vless"
echo "TLS：开启"
echo "SNI：$DOMAIN"
echo "Host：$DOMAIN"

echo ""
echo "VLESS 链接："
echo "vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=%2Fvless#SingFlare"

echo ""
ok "全部完成。复制上面的 VLESS 链接到 v2rayN 测试。"
warn "128MB 无 swap VPS 非常极限，watchdog 已启用；长期稳定建议 256MB 以上。"
warn "如果 Tunnel Token 曾经暴露，建议在 Cloudflare 里重新生成 Token。"
