#!/bin/sh
# Day 6 · 观察组 2：端口绑定 / 只读根 / 镜像体检
# 规矩：先跑 → 抄原始输出 → 再解释。脚本里不写"预期答案"，只写"看什么"。
set -u
IMG=alpine:3.22

# ---- 本脚本用到的 flag 速查 ----
#   -u 10001:10001                    指定容器主进程的 uid:gid（非 root 运行）
#   --read-only                       根文件系统挂载为只读
#   --tmpfs /tmp                      额外挂一个内存文件系统（配合 --read-only 给可写处）
#   --cap-drop=ALL / --cap-add=XXX    drop 在前、add 在后，净结果 = 只留 add 的那个
#   timeout 2 <命令>                   2 秒后给进程发 SIGTERM、退出码 124
#                                      —— 用来防止 nc 监听把脚本卡死
#   nc -l -p 80                       busybox 的 netcat：监听(listen) 80 端口
#   docker inspect -f '{{.XXX}}'      用 Go 模板只取某个字段（不吐整坨 JSON）

echo '=== 0 · 先量底料：ip_unprivileged_port_start（决定"非 root 能绑多低"）==='
docker run --rm $IMG cat /proc/sys/net/ipv4/ip_unprivileged_port_start

echo
echo '=== D · root + 默认能力，绑 80 ==='
docker run --rm $IMG timeout 2 nc -l -p 80
echo "D 退出码=$?"

echo
echo '=== E · 非 root(10001) + 默认能力，绑 80 ==='
docker run --rm -u 10001:10001 $IMG timeout 2 nc -l -p 80
echo "E 退出码=$?"

echo
echo '=== F · root + --cap-drop=ALL，绑 80 ==='
docker run --rm --cap-drop=ALL $IMG timeout 2 nc -l -p 80
echo "F 退出码=$?"

echo
echo '=== G · 非 root + drop ALL + 加回 NET_BIND_SERVICE，绑 80 ==='
docker run --rm -u 10001:10001 --cap-drop=ALL --cap-add=NET_BIND_SERVICE $IMG timeout 2 nc -l -p 80
echo "G 退出码=$?"

echo
echo '=== H · --read-only 下写根目录 ==='
docker run --rm --read-only $IMG touch /f
echo "H 退出码=$?"

echo
echo '=== I · --read-only + --tmpfs /tmp 下写 /tmp ==='
docker run --rm --read-only --tmpfs /tmp $IMG touch /tmp/f
echo "I 退出码=$?"

echo
echo '=== J · 镜像体检：webapp:v2 的身份与 Env ==='
docker inspect -f 'User={{.Config.User}}|Env={{.Config.Env}}' webapp:v2
