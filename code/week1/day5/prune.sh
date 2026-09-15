#!/usr/bin/env bash
# Day 5 实验 6：docker system prune —— 先预检爆炸半径，再动手
#
# 本机两个前提（已实测）：
#   1. kind-control-plane 处于 Up → docker system prune 不动"运行中"的容器，安全
#   2. webapp:v1/v2/v3 都是**有 tag 的**镜像 → 不带 -a 的 prune 不删有 tag 的镜像，安全
# ⚠️ 但"所有已停止的容器"会被删掉（包括 2 周前的 docker_test）
cd "$(dirname "$0")" || exit 1
section() { printf '\n==================== %s ====================\n' "$*"; }
banner()  { printf '\n---------- %s ----------\n' "$*"; }

section "0. 清理前：四类占用总览"
docker system df

section "1. 预检：prune 到底会删什么"
banner "① 已停止的容器（prune 会全部删除）"
docker ps -a --filter status=exited --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
banner "② 悬空镜像（<none>，prune 会删）"
docker image ls -f dangling=true --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}'
banner "③ 网络（未被容器使用的会被删）"
docker network ls
banner "④ 卷 —— prune **不碰**（只有 docker volume prune 才删）"
docker volume ls
banner "⑤ 必须保住的东西"
docker ps --filter name=kind-control-plane --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'

section "2. 执行 docker system prune -f（⚠️ 不带 -a）"
docker system prune -f

section "3. 清理后：对账"
docker system df
banner "容器列表（注意 docker_test 已消失、kind-control-plane 还在）"
docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
banner "有 tag 的镜像应该毫发无伤"
docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}' | grep -E 'webapp|kindest|mysql|alpine' || true
banner "卷应该一个不少"
docker volume ls

section "4. 演示 docker system prune -a 的爆炸半径（只看，不执行）"
echo '$ docker system prune -a -f  ← 会额外删掉所有"没容器在用"的镜像：'
docker image ls --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' | grep -vE '^(day5-|alpine:)' | head -20
echo '↑ 其中包括 webapp:v1/v2/v3、kindest/node（1.3GB）、mysql、rabbitmq —— 第 2 周还要用的东西'
