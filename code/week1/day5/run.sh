#!/usr/bin/env bash
# Day 5 主线实验：故意制造故障 + 排障工具链（实验 1~5）
#
# 用法：bash run.sh
# 注意：故意不写 set -e —— 本脚本里"命令返回非 0"就是实验结果的一部分（137/127）
cd "$(dirname "$0")" || exit 1

section() { printf '\n==================== %s ====================\n' "$*"; }
banner()  { printf '\n---------- %s ----------\n' "$*"; }

# ---------- 0. 清场 ----------
section "0. BUILD"
for pair in badcmd:Dockerfile.badcmd badcmd-shell:Dockerfile.badcmd-shell oom:Dockerfile.oom sig:Dockerfile.sig; do
    name=${pair%%:*}
    df=${pair##*:}
    banner "build day5-$name  <- $df"
    docker build -f "$df" -t "day5-$name" . 2>&1 | tail -3
done

section "1. 清掉旧实验容器（让 ps -a 干净）"
docker rm -f e1a e1b e2 oom1 oom2 sig-default sig-graceful sig-ignore sig-live 2>/dev/null
docker ps -a --format 'table {{.Names}}\t{{.Status}}'

# ---------- 实验 1 ----------
section "实验 1-A：exec 形式 CMD 指向不存在的文件"
banner "docker run --name e1a day5-badcmd"
docker run --name e1a day5-badcmd
echo "→ docker CLI 退出码: $?"
banner "docker ps -a 里到底有没有这个容器？"
docker ps -a --filter name=e1a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
echo "(空 = runc 在创建阶段就失败了，根本没生成容器对象)"

section "实验 1-B：shell 形式 CMD（同一个不存在的文件）"
banner "docker run --name e1b day5-badcmd-shell"
docker run --name e1b day5-badcmd-shell
echo "→ docker CLI 退出码: $?"
banner "docker inspect"
docker inspect e1b --format 'ExitCode={{.State.ExitCode}}  Error={{.State.Error}}'
banner "docker logs e1b"
docker logs e1b
banner "对比：PID 1 到底是谁"
docker inspect e1b --format 'Path={{.Path}}  Args={{.Args}}  Cmd={{.Config.Cmd}}'

# ---------- 实验 2 ----------
section "实验 2：Exited (0) —— 主进程\"跑完了\"，容器就没了"
banner "docker run --name e2 alpine:3.22 sh -c 'echo starting; echo done'"
docker run --name e2 alpine:3.22 sh -c 'echo starting; echo done'
docker inspect e2 --format 'ExitCode={{.State.ExitCode}}  OOMKilled={{.State.OOMKilled}}'
banner "docker ps -a（它在退出列表里，不在运行列表里）"
docker ps -a --filter name=e2 --format 'table {{.Names}}\t{{.Status}}'

# ---------- 实验 3 ----------
section "实验 3-A：OOM —— docker run --name oom1 -m 32m day5-oom（前台看输出）"
banner "docker run -m 32m"
docker run --name oom1 -m 32m day5-oom
echo "→ docker CLI 退出码: $?"
banner "docker inspect（关键三字段）"
docker inspect oom1 --format 'ExitCode={{.State.ExitCode}}
OOMKilled={{.State.OOMKilled}}
MemoryLimit={{.HostConfig.Memory}}
MemorySwap={{.HostConfig.MemorySwap}}
StartedAt={{.State.StartedAt}}
FinishedAt={{.State.FinishedAt}}'
banner "docker logs oom1 | tail -5   ← 日志停在\"死前最后一个成功的动作\""
docker logs oom1 | tail -5
banner "docker events（退出码查不到的那一半：谁杀的）"
t1=$(docker inspect -f '{{.State.StartedAt}}' oom1)
t2=$(docker inspect -f '{{.State.FinishedAt}}' oom1)
docker events --since "$t1" --until "$t2" --filter container=oom1

section "实验 3-B：同样 -m 32m，改成后台 + 中途采样 stats（拿\"运行中\"的内存证据）"
docker run -d --name oom2 -m 32m day5-oom >/dev/null
sleep 2
docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.PIDs}}' oom2
sleep 4
banner "事后 inspect"
docker inspect oom2 --format 'ExitCode={{.State.ExitCode}}  OOMKilled={{.State.OOMKilled}}'
docker logs oom2 | tail -3

# ---------- 实验 4 ----------
section "实验 4：同一个程序，三种\"对 SIGTERM 的态度\""
banner "4-A MODE=default（不装 handler）"
docker run -d --name sig-default -e MODE=default day5-sig >/dev/null
sleep 1
time docker stop -t 10 sig-default
docker inspect sig-default --format 'ExitCode={{.State.ExitCode}}  OOMKilled={{.State.OOMKilled}}'
docker logs sig-default | tail -3

banner "4-B MODE=graceful（捕获 → 善后 → exit 0）"
docker run -d --name sig-graceful -e MODE=graceful day5-sig >/dev/null
sleep 1
time docker stop -t 10 sig-graceful
docker inspect sig-graceful --format 'ExitCode={{.State.ExitCode}}  OOMKilled={{.State.OOMKilled}}'
docker logs sig-graceful | tail -5

banner "4-C MODE=ignore（忽略 SIGTERM，等被 SIGKILL）"
docker run -d --name sig-ignore -e MODE=ignore day5-sig >/dev/null
sleep 1
time docker stop -t 3 sig-ignore
docker inspect sig-ignore --format 'ExitCode={{.State.ExitCode}}  OOMKilled={{.State.OOMKilled}}'
docker logs sig-ignore | tail -3

banner "4-D 对照：shell 形式 CMD 会不会吞掉信号（alpine 里 sleep 被 sh 包着）"
docker run -d --name sig-shell alpine:3.22 sh -c 'sleep 600' >/dev/null
sleep 1
docker inspect sig-shell --format 'Path={{.Path}} Args={{.Args}}'
time docker stop -t 3 sig-shell
docker inspect sig-shell --format 'ExitCode={{.State.ExitCode}}'

# ---------- 实验 5 ----------
section "实验 5：资源与磁盘"
docker run -d --name sig-live -e MODE=default day5-sig >/dev/null
sleep 2
banner "docker stats --no-stream（只对运行中的容器有效）"
docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.PIDs}}'
banner "docker top sig-live（宿主视角看容器内进程）"
docker top sig-live
banner "docker system df  /  df -v（四类占用）"
docker system df
docker system df -v | head -40
banner "已退出容器：exec / stats / top 能不能用？"
echo "\$ docker exec sig-default true"; docker exec sig-default true
echo "\$ docker stats --no-stream sig-default"; docker stats --no-stream sig-default
echo "\$ docker top sig-default"; docker top sig-default
docker stop sig-live >/dev/null

section "DONE"
docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
