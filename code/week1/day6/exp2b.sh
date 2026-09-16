#!/bin/sh
# Day 6 · 观察组 2b：重做"绑 80"实验
# 为什么重做：上一版（exp2.sh 的 D~G）被 ip_unprivileged_port_start=0 短路了 ——
#            四组全部成功，NET_BIND_SERVICE 根本没参与判定（变量没控住，结论无效）。
# 本脚本用 --sysctl 把它调回内核默认值 1024，再重跑。
#
# ---- 本脚本新增的 flag ----
#   --sysctl net.ipv4.ip_unprivileged_port_start=1024
#        容器内"低于多少端口算特权端口"的阈值。内核默认 1024，Docker 默认给 0。
#        调回 1024 后，绑 80 才会去查 CAP_NET_BIND_SERVICE。
#   -i    把宿主 stdin 接到容器（上一版没加 → nc 的 stdin 立刻 EOF → 打印 punt!）

set -u
IMG=alpine:3.22
SYS='--sysctl net.ipv4.ip_unprivileged_port_start=1024'

echo '=== 先校验：阈值确实变成 1024 了吗 ==='
docker run --rm $SYS $IMG cat /proc/sys/net/ipv4/ip_unprivileged_port_start

echo
echo '=== F2 · root + --cap-drop=ALL + 阈值 1024 ==='
docker run --rm $SYS --cap-drop=ALL $IMG timeout 2 nc -l -p 80
echo "F2 退出码=$?"

echo
echo '=== E2 · 非 root(10001) + 默认能力 + 阈值 1024 ==='
docker run --rm $SYS -u 10001:10001 $IMG timeout 2 nc -l -p 80
echo "E2 退出码=$?"

echo
echo '=== G2 · 非 root + drop ALL + 加回 NET_BIND_SERVICE + 阈值 1024 ==='
docker run --rm $SYS -u 10001:10001 --cap-drop=ALL --cap-add=NET_BIND_SERVICE $IMG timeout 2 nc -l -p 80
echo "G2 退出码=$?"

echo
echo '=== 附：punt! 是不是"stdin EOF"造成的（加了 -i 对比）==='
docker run --rm -i $SYS $IMG timeout 2 nc -l -p 80
echo "退出码=$?"
