wget -O sf.sh https://raw.githubusercontent.com/wj6019/alpine-singbox-cloudflared/main/sf.sh && chmod +x sf.sh && sh sf.sh

curl -L -o sf.sh https://raw.githubusercontent.com/wj6019/alpine-singbox-cloudflared/main/sf.sh && chmod +x sf.sh && sh sf.sh

如果 DNS 还没配置，先执行这一条修 DNS：然后再运行下载命令。
echo "nameserver 1.1.1.1" > /etc/resolv.conf && echo "nameserver 8.8.8.8" >> /etc/resolv.conf
