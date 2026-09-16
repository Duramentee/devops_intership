#!/bin/sh
# Day 6 · 观察组 2c：非 root 时能力位到底有没有被清空？（决定性测量）
# 背景：exp2b 里 E2/G2（非 root + 有 NET_BIND_SERVICE）也被拒 → 我的模型有洞。
#       两种假设：H-A = 非 root 时那个位根本没拿到；H-B = 内核还额外看 uid。
#
# 方法：直接读 /proc/self/status 的 CapEff，不再靠行为推测。
#
# ---- flag ----
#   -u 10001:10001                     非 root 身份
#   --cap-drop=ALL --cap-add=NET_BIND_SERVICE   只留这一个位
#   --sysctl ip_unprivileged_port_start=1024    阈值调回内核默认，让"低端口"规则生效

set -u
IMG=alpine:3.22
SYS='--sysctl net.ipv4.ip_unprivileged_port_start=1024'

echo '=== K1 · root + 默认能力 → CapEff 基线（应为 a80425fb）==='
docker run --rm $SYS $IMG grep ^Cap /proc/self/status

echo
echo '=== K2 · 非 root(10001) + 默认能力 → 位还在吗？（H-A 的关键）==='
docker run --rm $SYS -u 10001:10001 $IMG grep ^Cap /proc/self/status

echo
echo '=== K3 · 非 root + drop ALL + add NET_BIND_SERVICE → 位还在吗？==='
docker run --rm $SYS -u 10001:10001 --cap-drop=ALL --cap-add=NET_BIND_SERVICE $IMG grep ^Cap /proc/self/status

echo
echo '=== K4 · root + drop ALL + 只加回 NET_BIND_SERVICE → 能绑 80 吗 ==='
docker run --rm $SYS --cap-drop=ALL --cap-add=NET_BIND_SERVICE $IMG timeout 2 nc -l -p 80
echo "K4 退出码=$?  (143/124 = 绑上了；1 = 被拒)"

echo
echo '=== K5 · 非 root + drop ALL + add NET_BIND_SERVICE，但阈值=0 → 能绑吗 ==='
docker run --rm -u 10001:10001 --cap-drop=ALL --cap-add=NET_BIND_SERVICE $IMG timeout 2 nc -l -p 80
echo "K5 退出码=$?  (143/124 = 绑上了；1 = 被拒)"
