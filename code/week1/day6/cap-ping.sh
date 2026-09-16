#!/bin/sh
# Day 6 · 「ping 之谜」对照实验（一次只改一个变量）
# 现象：--cap-drop=ALL 后 ping 8.8.8.8 仍然成功，与「raw socket 需要 CAP_NET_RAW」矛盾
# 目的：定位它走的是 raw socket 还是 ICMP datagram socket
set -u

IMG=alpine:3.22

# ---- 命令里每个 flag 都是干什么的 ----
#   docker run [DOCKER 的选项...] 镜像名 [镜像里要跑的命令 + 它的参数...]
#     ↑ 第一个"非选项"就是镜像名，它后面的一切 docker 原样当"容器内命令"
#   --rm                       容器退出后自动删除（不留 Exited 尸体）
#   --cap-drop=ALL             启动时把能力位全清零（CapEff/Prm/Bnd 都变 0）
#   --cap-add=NET_RAW          在 drop 之后再把某一个位加回来（顺序有语义）
#                               ⚠️ 名字不带 CAP_ 前缀（内核文档里叫 CAP_NET_RAW）
#   --sysctl 键=值              往容器里写一个"命名空间化"的内核参数
#   net.ipv4.ping_group_range   一个 gid 区间：区间内的进程可以建 ICMP datagram socket
#                               （这条路径不检查 CAP_NET_RAW）；'1 0' 是空区间（内核默认值）
#   alpine:3.22                镜像名
#   ping -c1 8.8.8.8           容器里跑 ping；-c1 是 ping 自己的参数（只发 1 个包）

echo '=== A · 默认的 ping_group_range 是多少（关键嫌疑）==='
# 用 cat 读 /proc/sys（伪文件），不依赖镜像里有没有 sysctl 这个命令
docker run --rm --cap-drop=ALL $IMG cat /proc/sys/net/ipv4/ping_group_range

echo
echo '=== B · 区间掏空(1 0) + 没有 NET_RAW → 还通吗 ==='
docker run --rm --cap-drop=ALL \
  --sysctl net.ipv4.ping_group_range='1 0' \
  $IMG ping -c1 8.8.8.8
echo "B 退出码=$?"

echo
echo '=== C · 同上，但把 NET_RAW 加回来 → 又通了吗 ==='
docker run --rm --cap-drop=ALL --cap-add=NET_RAW \
  --sysctl net.ipv4.ping_group_range='1 0' \
  $IMG ping -c1 8.8.8.8
echo "C 退出码=$?"

echo
echo '=== 判定 ==='
echo 'B 失败 + C 成功 → 走 datagram 路径，raw 只认 CAP_NET_RAW'
echo 'B 还通        → 假设不成立，查 docker info | grep -i userns'
