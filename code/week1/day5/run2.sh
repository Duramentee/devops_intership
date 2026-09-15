#!/usr/bin/env bash
# Day 5 第二轮：钉死第一轮里三个"反直觉"发现的机制
#   A. docker events 的 --until 会切掉同一秒的事件
#   B. PID 1 的"默认处置信号被忽略"到底是什么表现（用非 Go 的 sleep 做对照）
#   C. 同一个 Go 程序**不是 PID 1** 时，SIGTERM 会不会给出 143
#   D. CMD 写错时，容器对象的 ExitCode 到底是什么（Created 状态的坑）
#   E. 把 OOM 拉长，采样 stats 拿到"运行中内存曲线" + --memory-swap 的作用
cd "$(dirname "$0")" || exit 1
section() { printf '\n==================== %s ====================\n' "$*"; }
banner()  { printf '\n---------- %s ----------\n' "$*"; }

section "A. docker events：把 --until 放宽到\"现在\""
t1=$(docker inspect -f '{{.State.StartedAt}}' oom1)
echo "oom1 StartedAt = $t1"
docker events --since "$t1" --until "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --filter container=oom1

section "B. PID 1 = sleep（非 Go，不装 handler）→ docker stop 会怎样？"
docker rm -f t-sleep >/dev/null 2>&1
docker run -d --name t-sleep alpine:3.22 sleep 600 >/dev/null
sleep 1
docker inspect t-sleep --format 'Path={{.Path}} Args={{.Args}}  ← PID 1 是谁'
banner "docker stop -t 3（如果 SIGTERM 生效，应该 0.x 秒就结束）"
time docker stop -t 3 t-sleep
docker inspect t-sleep --format 'ExitCode={{.State.ExitCode}} OOMKilled={{.State.OOMKilled}}'

section "C. 同一个 Go 程序，但不是 PID 1 → SIGTERM 的退出码"
docker rm -f t-child >/dev/null 2>&1
docker run -d --name t-child --entrypoint sh day5-sig \
  -c '/sig & p=$!; sleep 2; kill -TERM $p; wait $p; echo "CHILD-EXIT=$?"; sleep 300' >/dev/null
sleep 5
banner "docker logs t-child"
docker logs t-child
banner "容器自己的退出码（父 shell 的，不是子进程的）"
docker inspect t-child --format 'Status={{.State.Status}}'
docker stop -t 2 t-child >/dev/null 2>&1
docker inspect t-child --format 'ExitCode={{.State.ExitCode}}'

section "D. CMD 写错的容器对象：Created 状态下的 State 字段"
docker inspect e1a --format 'Status={{.State.Status}}
ExitCode={{.State.ExitCode}}
Error={{.State.Error}}
StartedAt={{.State.StartedAt}}
FinishedAt={{.State.FinishedAt}}
Pid={{.State.Pid}}'
banner "docker ps -a 里它是什么样"
docker ps -a --filter name=e1a --format 'table {{.Names}}\t{{.Status}}'
banner "docker start e1a（手动启动这个\"从没跑起来\"的容器）"
docker start e1a; echo "→ docker start 退出码: $?"
docker ps -a --filter name=e1a --format 'table {{.Names}}\t{{.Status}}'

section "E. 拉长 OOM：-m 256m --memory-swap 256m（= 禁用 swap）"
docker rm -f oom3 >/dev/null 2>&1
docker run -d --name oom3 -m 256m --memory-swap 256m day5-oom >/dev/null
banner "stats 采样（每 1.5s）"
for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1.5
    docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}' oom3
    st=$(docker inspect -f '{{.State.Status}}' oom3)
    printf '(status=%s)\n' "$st"
    [ "$st" != "running" ] && break
done
banner "事后 inspect"
docker inspect oom3 --format 'ExitCode={{.State.ExitCode}}  OOMKilled={{.State.OOMKilled}}  Memory={{.HostConfig.Memory}}  MemorySwap={{.HostConfig.MemorySwap}}'
docker logs oom3 | tail -3
banner "对照：这次 MemorySwap 与 Memory 的关系 vs 第一轮 oom1"
docker inspect oom1 --format 'oom1: Memory={{.HostConfig.Memory}} MemorySwap={{.HostConfig.MemorySwap}}（= 2×memory，所以它能吃到 56MiB）'
docker inspect oom3 --format 'oom3: Memory={{.HostConfig.Memory}} MemorySwap={{.HostConfig.MemorySwap}}（= 1×memory，禁用 swap）'

section "DONE"
docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
