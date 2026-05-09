Cloudflare Tunnel:

登录 Cloudflare Zero Trust 面板。
导航至 Networks -> Tunnels，创建一个新的 Tunnel。
保存生成的 Tunnel Token (即 ARGO_TOKEN)。
为该 Tunnel 配置一个 Public Hostname（例如 proxy.yourdomain.com），并将服务指向 http://localhost:8080。



wget -O sf.sh https://raw.githubusercontent.com/wj6019/alpine-singbox-cloudflared/main/sf.sh && chmod +x sf.sh && sh sf.sh

curl -L -o sf.sh https://raw.githubusercontent.com/wj6019/alpine-singbox-cloudflared/main/sf.sh && chmod +x sf.sh && sh sf.sh

如果 DNS 还没配置，先执行这一条修 DNS：然后再运行下载命令。
echo "nameserver 1.1.1.1" > /etc/resolv.conf && echo "nameserver 8.8.8.8" >> /etc/resolv.conf
