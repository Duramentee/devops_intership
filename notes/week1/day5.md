# Day 5 · 排障工具链与故障复现

> 日期：2026-09-15 · 代码：`code/week1/day5/`（`run.sh` / `run2.sh` / `prune.sh` + `logs/exp1-5.log`、`exp-round2.log`、`exp6-prune.log`）· 原笔记备份：`/tmp/day5-notes-backup.md`
> 关联文档：`docs/docker/04-排障索引.md` §一 五步定位法 · §二 退出码 · §三 现象索引 · `docs/linux/Linux-故障索引.md`（信号语义 / 进程生命周期 / fd）
> 环境：Docker Desktop 4.90.0 · Engine 29.7.2 · containerd 2.3.3 · runc 1.4.3

---

## 1. 结论速览

| # | 结论 |
|---|---|
| 1 | **排障是分层定位，不是猜测**：容器在不在 → 怎么退出的 → 日志最后说了什么 → 环境对不对 → 资源够不够（顺序不可颠倒） |
| 2 | **退出码 = 主进程的结束原因**：`0` 正常结束（对服务型进程反而是异常）/ `1` 应用报错 / `127` 找不到命令 / `137` = 128+9 被 SIGKILL / `143` = 128+15 收到 SIGTERM |
| 3 | ⚠️ **修正了原先的说法**：`docker stop` **不保证**得到 143 —— **PID 1 不装 handler 时 SIGTERM 被内核忽略** → 等超时被 SIGKILL = **137**；Go 程序做 PID 1 时还会得到 **2** |
| 4 | ⚠️ **"优雅关闭成功"的标志是 `ExitCode 0` + 日志中有善后输出**（实测 4-B），不是 143。`Exited (143)` 只说明"被 SIGTERM 杀死"，**善后可能并未发生** |
| 5 | ⚠️ **`137` ≠ OOM**：`docker kill`、`rm -f`、`stop` 超时、宿主 OOM 都产生 137（实测 4-C 就是 `OOMKilled=false` 的 137）；只有 `OOMKilled=true` 才是 OOM |
| 6 | **`0` 是最容易被忽略的"故障"**：容器生命周期 = 主进程生命周期，主进程结束容器就退出，即使它"没有报错" |
| 7 | **磁盘要连着容器一起看**：镜像层 + 可写层 + 卷 + 构建缓存四类占用；`prune` 不带 `-a` 只清已停止容器与缓存，带 `-a` 会删除未使用的带 tag 镜像 |

---

## 2. 机制

### 2.1 为什么排障必须按顺序

| 原因 | 说明 |
|---|---|
| 第 1 步决定后续命令**是否可用** | 容器已退出时 `docker exec` 直接报 `is not running`，`docker stats` 返回无意义的 `0B/0B` |
| 先拿退出码 = 先给死因**分类** | 避免在错误方向上翻日志（`125/126/127` 查镜像与 Dockerfile，其余查应用与资源） |
| 顺序颠倒会**破坏现场** | 先 `docker rm` 再 `docker inspect`，退出码、`State.Error`、可写层全都拿不到 |

### 2.2 退出码由谁记录

内核在进程退出时产生 wait status；**dockerd（经 containerd-shim）是父进程**，调用 `wait()` 取得后写入 `State.ExitCode`。因此退出码是**父进程视角的记录**。
同一机制解释僵尸进程：父进程不调用 `wait()`，进程就停留在 `Z` 状态。

### 2.3 PID 1 的信号语义（本日核心）

**机制链**（推断 + 实测证据，内核文档原文尚未核对，见 §7 遗留疑问）

| 步 | 发生什么 | 证据 |
|---|---|---|
| 1 | 内核给 **PID 1** 一个保护：**默认处置为"终止"的信号被忽略**（SIGKILL/SIGSTOP 除外），除非进程自己装了 handler | 补 B：`sleep` 直接做 PID 1，`stop -t 3` 等满 3.29s → 137（若 SIGTERM 生效，`sleep` 会立即结束） |
| 2 | 因此不装 handler 的 PID 1 收不到 SIGTERM 的效果，只能等超时被 SIGKILL | 4-C、4-D、补 B 全部为 137 + 3.29s |
| 3 | **Go runtime 给所有信号都装了内部 handler**。未注册 `Notify` 时走 `dieFromSignal()`：**恢复 `SIG_DFL` → `raise(SIGTERM)`**；若信号未杀死进程（PID 1 被忽略）→ **回退 `exit(2)`** | 4-A = `2`；补 C（非 PID 1，同样的 `raise` 生效）= `143` |
| 4 | `143` 的真实来源：进程**不是 PID 1**，或信号以默认处置生效 | 补 C 实测输出 `Terminated` + `CHILD-EXIT=143` |

**三条推论**

| # | 结论 |
|---|---|
| 1 | `143` 不是 `docker stop` 的默认结果，`137` 也不是故障专属 —— 同一个 `stop`，结局由「**PID 1 是谁 + 装没装 handler**」决定 |
| 2 | **优雅关闭成功的判定条件 = `ExitCode 0` + 日志中有善后输出**；`Exited (143)` 只说明被 SIGTERM 杀死 |
| 3 | 想让服务**收到**信号：① `CMD`/`ENTRYPOINT` 用 exec 形式（应用自己当 PID 1）② 代码中显式注册 handler ③ 或加 `--init`（tini）由 init 转发并回收子进程 |

> 旁证：`docker build` 对 shell 形式 CMD 会给出警告 —— `JSONArgsRecommended: JSON arguments recommended for CMD to prevent unintended behavior related to OS signals`。

### 2.4 `137` 与 `143` 的区别（为什么对优雅关闭关键）

| 信号 | 能否捕获 | 含义 |
|---|---|---|
| SIGTERM（143 = 128+15） | ✅ 可捕获 | "请退出" —— 进程有机会执行善后 |
| SIGKILL（137 = 128+9） | ❌ 不可捕获 | "立即终止" —— 无机会 |

优雅关闭的**全部机会**就是「收到 SIGTERM → 被 SIGKILL」这段窗口：停止接收新请求 → 处理完在途请求 → 关闭连接 → 刷盘/注销。做到即 `143`（甚至 `0`），没做到即 `137`。137 意味着连接被硬断、在途请求丢失 —— 这正是 K8s 中 `terminationGracePeriodSeconds` 与 `preStop` 钩子存在的原因。

### 2.5 OOM 的完整机制

cgroup 内存上限被超过 → 内核 OOM killer 直接发送 **SIGKILL**（不可捕获）→ 退出码 137；dockerd 从 cgroup 事件中读到 OOM 标记，写入 `State.OOMKilled=true`。
→ **OOM 一定是 137，但 137 不一定是 OOM。**
⚠️ `MemorySwap` 默认 = **2 × `Memory`**，多出的部分是**可换出的 swap**：`-m 32m` 实际可吃到约 56 MiB 才被杀。要严格限制需 `--memory-swap` 取与 `-m` 相同的值。

### 2.6 容器内的磁盘与宿主磁盘为何不一致

容器看到的是自己的**挂载命名空间**（只读镜像层 + 可写层 + 卷 + tmpfs）；宿主 `df` 看的是宿主文件系统。三种不一致的情形：

| 情形 | 说明 |
|---|---|
| 写满的是 tmpfs | tmpfs 占用内存，宿主的 `df` 看不到 |
| 挂载点位于其他分区 / 卷 | 两边统计的不是同一个文件系统 |
| 文件在宿主被 `rm` 但进程仍持有 fd | 空间不会释放，`lsof +L1` 可查 |

---

## 3. 命令

| 场景 | 命令 | 说明 |
|---|---|---|
| 一眼看状态 | `docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'` | STATUS 列直接显示 `Exited (n)`；`Created` 表示从未运行 |
| 一眼看退出原因（本日主力） | `docker inspect 名 --format '{{.State.ExitCode}} oom={{.State.OOMKilled}} {{.State.Error}} {{.State.FinishedAt}}'` | 一次取齐 4 个关键字段 |
| 按退出码筛容器 | `docker ps -a --filter 'exited=137'` | 找"谁被 SIGKILL 了" |
| **查"谁杀的它"** | `docker events --since <Start> --until <现在>`；`--filter event=oom` / `--filter container=名` | ⚠️ `--until` 不要用 `FinishedAt`（会切掉 `oom`/`die` 事件）；`die` 事件带 `exitCode` 与 `execDuration` |
| 看 `Created` 容器的错误 | `docker inspect 名 --format '{{.State.Error}}'` | runc 的原始报错，是从未启动的容器的**唯一**线索 |
| 看内存限制与 swap | `docker inspect 名 --format '{{.HostConfig.Memory}} {{.HostConfig.MemorySwap}}'` | `MemorySwap` 默认 = 2 × `Memory` |
| 清理前预检（必做） | `docker system df` + `docker ps -a --filter status=exited` + `docker image ls -f dangling=true` | 先确认影响范围；`Created` 的容器也会被删除 |
| 确认容器是否在运行 | `docker inspect -f '{{.State.Status}}' 名` | ⚠️ `docker stats` 对已退出容器返回 `0B/0B` 且不报错，不能作为判断依据 |
| 看运行时长 | `docker inspect 名 --format '{{.State.StartedAt}} → {{.State.FinishedAt}}'` | 秒级退出 → 优先怀疑 OOM 或启动即崩 |
| 看日志尾部并跟随 | `docker logs --tail 100 -f 名` | 容器已退出也可用 |
| 看 PID 1 是什么 | `docker inspect 名 --format '{{.Config.Cmd}} {{.Config.Entrypoint}}'` | 排查 127 的第一条命令 |
| 忽略 ENTRYPOINT 直接进入容器 | `docker run --rm -it --entrypoint sh 镜像:tag` | 镜像无 shell（scratch/distroless）时无效 |
| 进入运行中的容器 | `docker exec -it 名 sh` | ⚠️ 容器必须在运行 |
| 宿主视角看容器内进程 | `docker top 名` | 对应 Day 1「容器进程在宿主 `ps` 中可见」 |
| 资源占用快照 | `docker stats --no-stream` | 只对运行中容器有效 |
| 磁盘占用明细 | `docker system df -v` | 四类占用：镜像层 / 可写层 / 卷 / 构建缓存 |
| 清理 | `docker system prune`；`docker volume prune` | 卷默认只删**匿名**卷；`-a` 会扩大范围，先 `df -v` 确认 |
| 看容器的文件改动 | `docker diff 名` | ⚠️ 必须在删除容器之前执行 |
| 看挂载 | `docker inspect -f '{{json .Mounts}}' 名` | 查 tmpfs / bind / 卷 |
| 看环境变量 | `docker inspect -f '{{json .Config.Env}}' 名` | 查"配置从环境变量读取"这一类的丢失 |

---

## 4. 实测数据（原始输出）

### 4.1 退出码总表（全部实测）

| # | 制造方式 | `ps -a` 的 STATUS | ExitCode | OOMKilled | 机制 |
|---|---|---|---|---|---|
| 1-A | **exec** 形式 CMD 指向不存在的文件 | **`Created`** | `127` | false | 容器**从未运行**：runc 在 create 阶段失败 |
| 1-B | **shell** 形式 CMD（同一路径） | `Exited (127)` | `127` | false | PID 1 = `/bin/sh -c /app/not-exist`，sh 报 `not found` 后以 127 退出 |
| 2 | `sh -c 'echo starting; echo done'` | `Exited (0)` | `0` | false | 主进程结束 → 容器退出（服务型进程的反例） |
| 3-A | `-m 32m` + 内存分配程序 | `Exited (137)` | `137` | **true** | OOM：内核 OOM killer 发送 SIGKILL |
| 3-E | `-m 256m --memory-swap 256m` | `Exited (137)` | `137` | **true** | 同上，且此时是**严格限制**（无 swap） |
| 4-A | Go 是 PID 1，**不装** handler | `Exited (2)` | **`2`** | false | 不是 143：PID 1 语义 + Go runtime 回退 `exit(2)` |
| 4-B | Go 是 PID 1，**捕获** SIGTERM 并善后 | `Exited (0)` | **`0`** | false | ✅ 优雅关闭成功的标志是 `0` |
| 4-C | Go 是 PID 1，`signal.Ignore(SIGTERM)` | `Exited (137)` | `137` | false | `stop -t 3` 超时 → SIGKILL；137 ≠ OOM |
| 4-D | `sh -c 'sleep 600'`（PID 1 = sh） | `Exited (137)` | `137` | false | 同 4-C：信号未生效 → 超时被杀 |
| 补 B | `sleep 600` **直接**做 PID 1 | `Exited (137)` | `137` | false | **直接证据**：PID 1 不装 handler → SIGTERM 被内核忽略 |
| 补 C | 同一个 Go 程序**不是 PID 1**（子进程 pid=7） | — | **`143`** | — | `143` 的真实来源：非 PID 1 时默认处置生效 |

### 4.2 五步定位法逐条实测

| 步 | 命令 | 实测结果 |
|---|---|---|
| 1 | `docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'` | 直接拿到 STATUS（含退出码）；`e1a` 显示 **`Created`** 而不是 `Exited` |
| 2 | `docker inspect 名 --format '{{.State.ExitCode}} oom={{.State.OOMKilled}} {{.State.StartedAt}} → {{.State.FinishedAt}}'` | `oom1`：`137 / true / 07:35:39.46 → 07:35:42.11`（**运行 2.65s**） |
| 2' | `docker inspect 名 --format '{{.State.Error}}'` | `e1a` 的 runc 完整报错 —— `Created` 容器的唯一线索 |
| 3 | `docker logs --tail 100 名` | `oom1` 停在 `allocated 56 MiB`；`e1a`（Created）日志为**空** |
| 4 | 已退出容器：`docker run --rm -it --entrypoint sh 镜像` / `docker cp` | ⚠️ `docker exec` 直接失败（见 4.5） |
| 5 | `docker stats --no-stream`；`docker inspect -f '{{.HostConfig.Memory}}'` | ⚠️ stats 对已退出容器返回 `0B / 0B`（见 4.5） |
| 补 | `docker events --since <Start> --until <现在>` | 拿到 `container oom` + `container die (exitCode=137, execDuration=2)` |

### 4.3 PID 1 信号实验（6 组）

| 实验 | PID 1 是谁 | 是否装了 handler | `docker stop` 结果 | 用时 |
|---|---|---|---|---|
| 4-A | `/sig`（Go） | ❌ 未装 | **`Exited (2)`** | 0.30s |
| 4-B | `/sig`（Go） | ✅ `signal.Notify` | **`Exited (0)`** | 2.29s（应用自身的 2s 善后） |
| 4-C | `/sig`（Go） | ✅ `signal.Ignore` | **`Exited (137)`** | 3.29s（= `-t 3` 超时） |
| 4-D | `/bin/sh` | ❌ | **`Exited (137)`** | 3.29s |
| 补 B | `sleep` | ❌ | **`Exited (137)`** | 3.29s |
| 补 C | `/bin/sh`（**Go 是子进程** pid=7） | ❌ | 子进程 **`143`** | 立即 |

### 4.4 OOM 证据链（实验 3-E）

| 证据 | 实测值 |
|---|---|
| `docker stats` 采样（`-m 256m --memory-swap 256m`） | `74.08MiB (28.94%)` → `138.3MiB (54.04%)` → `202.5MiB (79.12%)` → `0B / 0B` |
| 日志最后 3 行 | `allocated 232 MiB` → `240 MiB` → `248 MiB`（在 256MiB 前被杀） |
| `docker inspect` | `ExitCode=137`、`OOMKilled=true`、`Memory=268435456`、`MemorySwap=268435456` |
| `docker events`（`--until` 放宽后） | `container oom <id>` + `container die <id> (exitCode=137, execDuration=2)` |

### 4.5 已退出容器的命令可用性

| 命令 | 实测结果 |
|---|---|
| `docker exec sig-default true` | ❌ `Error response from daemon: container db716c6f... is not running` |
| `docker stats --no-stream sig-default` | ⚠️ **不报错**，返回 `0B / 0B`、`MEM %=0.00`、`PIDS=0` —— 最容易误导的一项 |
| `docker top sig-default` | ❌ `... is not running` |
| `docker logs` / `inspect` / `diff` / `cp` | ✅ 均可用 |

### 4.6 `127` 的两种形态

| CMD 形式 | Docker 实际执行 | `ps -a` 显示 | ExitCode | `docker logs` | 线索在哪 |
|---|---|---|---|---|---|
| `CMD ["/app/not-exist"]` | runc 直接 `exec /app/not-exist` | **`Created`** | `127` | **空** | `State.Error`（runc 报错） |
| `CMD /app/not-exist` | `/bin/sh -c "/app/not-exist"` | `Exited (127)` | `127` | `/bin/sh: /app/not-exist: not found` | `docker logs` |

`Created` 容器的 `State`：`ExitCode=127`、`StartedAt`/`FinishedAt` = `0001-01-01T00:00:00Z`（Go 零值）、`Pid=0` → 可据此判断"从未运行"；`docker start e1a` 重试仍失败（CLI 退出码 `1`）。

### 4.7 `docker system prune` 的删除范围（实验 6）

| 对象 | 实测结果 |
|---|---|
| 已停止的容器 | **14 个全部删除** —— 含两周前的 `docker_test`，也含 `Created` 状态的 `e1a`（未运行过也算） |
| 构建缓存 | 回收 **431.6MB**（Build Cache 1.431GB → 999MB） |
| 悬空镜像 | 本次无（删除 0 个） |
| **带 tag 的镜像** | ✅ 全部保留：`webapp:v1/v2/v3`、`kindest/node`、`mysql`、`rabbitmq`、`golang:1.25-alpine` |
| **卷** | ✅ 4 个全部保留（`webvol`、`webvol2` 与 kind 的两个）—— `prune` 不涉及卷 |
| 运行中的 `kind-control-plane` | ✅ 不受影响（全程 Up） |

⚠️ **加 `-a` 的后果**（本次只观察未执行）：会额外删除 `webapp:v1/v2/v3`、`kindest/node`（1.34GB + 1.31GB）、`mysql`、`rabbitmq` —— 第 2 周要用的镜像全在其中。

### 4.8 环境问题记录：`docker` 命令不可用

| 现象 | 命令 | 输出 |
|---|---|---|
| 任何 `docker` 子命令都失败 | `docker images` | `The command 'docker' could not be found in this WSL 2 distro` |
| 真实原因（**不是未安装**） | `ls -l /usr/bin/docker` | 软链指向 `/mnt/wsl/docker-desktop/cli-tools/usr/bin/docker`，**该目标不存在** |
| 旁证 | `ls -d /mnt/wsl/docker-desktop*` | `no matches found` → Docker Desktop 的 VM 未启动 |

→ 解决方法：在 Windows 侧启动 Docker Desktop。
**方法论**：报错文案说"在 WSL 里找不到 docker"，但根因不在 docker 的安装，而在软链的目标不存在 → **顺着命令的解析链往回走一步**（`docker` → `/usr/bin/docker` → 软链目标 → VM 是否运行）。这与本日"退出码要往回一步看谁发的信号"是同一个思路。

---

## 5. 易错点

| 错法 | 现象 | 正确做法 |
|---|---|---|
| 认为 `docker stop` 一定得到 `143` | 实测出现四种结局（0 / 2 / 137 / 143），不存在"默认 143" | 先确认 **PID 1 是谁、装没装 handler**；信号被内核忽略时只能等超时 → SIGKILL |
| 把"未装 handler → 信号被忽略"当成**通用**规律 | 会推出"没 handler 就该 143"，实测全错 | 该保护**只对 PID 1 成立**：非 PID 1 未装 handler → `143`；Go 做 PID 1 → `2`；`sleep`/`sh` 做 PID 1 → 超时 `137` |
| 用 `sysctl` 查"谁杀了进程" | 查不到任何结果 | `sysctl` 用于读写内核参数（如 `net.ipv4.ip_forward`）；查信号与杀进程用 `docker events` +（VM 内）`journalctl -k \| grep -i oom` |
| 把 `docker start` 返回的 `1` 当成容器退出码 | 记成"127 那个场景返回 1" | `1` 是 **CLI 自身**的返回码；容器退出码只从 `docker inspect -f '{{.State.ExitCode}}'` 读 |
| 把 `Exited (143)` 当成"优雅关闭成功" | 143 只说明被 SIGTERM 杀死 | **成功 = `ExitCode 0` + 日志有善后输出**（实测 4-B） |
| 把 137 一律当 OOM | 只查 `OOMKilled`，其余原因全漏 | 137 是"被 SIGKILL"的统称；要区分需看 `OOMKilled=true` 或 `docker events` 的 `oom` 事件 |
| 认为 `-m 32m` 就是严格限制 | 实测吃到 **56 MiB** 才被杀 | `MemorySwap` 默认 = 2 × `Memory`；要严格限制就把 `--memory-swap` 设为与 `-m` 相同 |
| 用 `State.FinishedAt` 作为 `docker events --until` | `oom`/`die` 事件全部看不到 | `--until` 用"现在"或更晚；事件时间戳晚于 `FinishedAt` |
| 用 `docker stats` 判断容器状态 | 已退出容器返回 `0B/0B`、`PIDS=0` 且不报错 | 先用 `docker inspect -f '{{.State.Status}}'` 确认；stats 只对运行中容器有效 |
| 用 `docker logs` 排查 exec 形式的 `127` | 日志为空 | 该形态容器未运行（`Created`），线索在 `State.Error`；shell 形式才有 sh 的 `not found` 日志 |
| 认为"CMD 写错 = `Exited (127)`" | 实测两种形态 | 看 STATUS：**`Created` = 从未运行**（`StartedAt` 为零值、`Pid=0`） |
| 把 shell 形式 CMD 的问题直接归因于"sh 不转发信号" | 本轮无法区分"sh 不转发"与"PID 1 忽略"—— 信号压根未被处理（`sleep` 直接做 PID 1 也是 137） | 先理解 PID 1 语义；shell 形式确实有风险，build 时 Docker 会警告 |
| 把 137 当作"故障专属" | 4-C 的 137 是 `docker stop` 超时导致，并非故障 | 退出码只说明"怎么死的"，不代表"是不是故障"；结合 `docker events` 与自己是否执行过 `stop` 判断 |
| `docker system prune` 直接执行 | ⚠️ 实验容器全部消失（含 `Created` 状态的） | 先 `docker system df` + `docker ps -a --filter status=exited` 预检；**不要加 `-a`**（会删除第 2 周要用的镜像） |
| 认为 `prune` 会删除卷 | 实测 4 个卷全部保留 | `docker system prune` 不涉及卷；卷需 `docker volume prune`（默认只删匿名卷） |
| 容器 `Exited (0)` 却以为正常 | 服务静默消失，排查方向跑偏 | 服务型进程必须前台常驻；`CMD` 写成"启动脚本执行完就退出"必踩此坑 |
| 用 `docker exec` / `docker top` 查已退出的容器 | `container ... is not running` | 已停止容器只能用 `logs` / `inspect` / `cp` / `diff`；需要查看 rootfs 时用 `docker run --entrypoint sh` 起同款镜像 |
| 在宿主 `df` 中查找容器的"磁盘满" | 两边数值对不上 | 容器有独立挂载命名空间，需在**容器内**执行 `df -h` / `du` |
| 只看 `docker ps`（不加 `-a`） | 认为"容器不见了" | 已退出的容器不在 `docker ps` 中，始终使用 `-a` |
| 把 137 直接等同于"被程序主动杀掉" | 137 至少有四类来源：① PID 1 不处理 SIGTERM → `stop` 超时升级为 SIGKILL ② 有人执行 `docker kill`（默认 SIGKILL）③ `docker rm -f` ④ 宿主层级内存挤压（宿主 OOM） | 区分手段：`docker events`（`kill` 事件带 `signal`、`die` 事件带 `exitCode` 与 `execDuration`）+ 算 `FinishedAt − StartedAt` 是否约等于 `stop -t` 的值（本机默认 10s；本地实验里设的是 3s）+ 自己是否执行过 `kill`/`rm -f` |

---

## 6. 每日一题（面试自测）

### 6.1 容器排障题：`Exited (137)`

**题目**：容器 `Exited (137)`。写出排查顺序（≥4 步），并回答：137 与 143 的区别是什么？为什么这个区别对"优雅关闭"很关键？

**我的原答**

1. 退出码是 137，说明它运行过 → `docker ps -a` 看到的是停止状态
2. `docker inspect` 查退出状态 / 退出码 / 是否 `OOMKilled`（是的话即可定因），并用 `FinishedAt` 定位时间
3. `docker logs` 找问题，看日志能否说明为什么被内核 kill
4. 再看环境（`docker exec -it xx sh`）与资源（`docker stats`），判断是应用配置问题还是资源不足被强杀

> 关于 137 与 143：143 优雅退出超出指定时段后会被 137 打死。

**批改：中上（四步骨架正确，3 处硬伤 + 概念答偏）**

| 步 | 判定 | 问题 |
|---|---|---|
| 1 `docker ps -a` | 🔶 动作对，**但理由是倒推的** | 退出码本身就来自 `ps -a` 的 STATUS 列，用"已知 137"论证顺序是循环论证。这一步真正要取的是「**在不在 / 是否 `Restarting` / 重启次数**」 |
| 2 `docker inspect` | ✅ 最扎实 | 补充：`StartedAt` 与 `FinishedAt` **配对**算出运行时长（秒级 → 怀疑 OOM）；还有 `State.Error`；⚠️ `OOMKilled=false` **不是结案**（137 还可能是 `docker kill` / `rm -f` / stop 超时 / 宿主 OOM） |
| 3 `docker logs` | 🔶 前提错误 | **SIGKILL 不可捕获** → 应用没有机会写"我被杀了"。日志只能看"死之前在做什么"；OOM 的原始证据在内核侧：`docker events --filter event=oom` / `journalctl -k \| grep -i oom` |
| 4 `exec` + `stats` | 🔶 顺序错误 | 容器已退出 → `exec` 报 `is not running`、`stats` 无有效输出。替代：`docker run --rm -it --entrypoint sh 镜像` / `docker cp 名:/路径 /tmp/` / `docker inspect -f '{{.HostConfig.Memory}}'` |
| 137 vs 143 | 🔶 答的是流程而非区别 | 区别在**可否捕获**：143 = SIGTERM，能善后；137 = SIGKILL，无机会。"stop 超时升级为 137"是流程描述（正确），但不是两者本身的区别 |

**为什么对优雅关闭关键**：优雅关闭的全部机会就是「收到 SIGTERM → 被 SIGKILL」这段窗口，窗口内需完成：停止接收新请求 → 处理完在途请求 → 关闭连接 → 刷盘/注销。做到即 `143`（更好是 `0`），没做到即 `137` —— 后者意味着连接被硬断、在途请求全丢。这就是 K8s 中 `terminationGracePeriodSeconds` 与 `preStop` 的原因。

**修正后的排查顺序（按实测校验）**

| 步 | 问什么 | 命令 | 实测校验点 |
|---|---|---|---|
| 1 | 在不在 / 什么状态 | `docker ps -a` | 顺带获取退出码；还要看是否 `Restarting` / **`Created`** |
| 2 | 怎么退出的 | `docker inspect 名 --format '{{.State.ExitCode}} oom={{.State.OOMKilled}} {{.State.StartedAt}} → {{.State.FinishedAt}} {{.State.Error}}'` | `StartedAt→FinishedAt` 差 2.65s；`State.Error` 是 `Created` 容器的唯一线索 |
| 3 | 日志最后说了什么 | `docker logs --tail 100 名` | 日志停在 `allocated 56 MiB`，即"死前最后一个成功动作" |
| 4 | **谁杀的它** | `docker events --since <Start> --until <现在>` | ⚠️ `--until` 不要用 `FinishedAt`；实测可拿到 `container oom` + `container die (exitCode=137)` |
| 5 | 资源限制是多少 | `docker inspect -f '{{.HostConfig.Memory}} {{.HostConfig.MemorySwap}}' 名` | ⚠️ `MemorySwap` 默认 2×；`stats` 对已退出容器返回 `0B/0B`（无效数据） |
| 6 | 环境对不对 | 已退出：`docker run --rm -it --entrypoint sh 镜像:tag` / `docker cp 名:/路径 /tmp/` | ⚠️ 不能 `exec`（`is not running`） |

> 实测给这道题带来两个反转：① 137 的原因里有一类是**自己执行过的 `docker stop` 超时**（4-C），与 OOM 无关；② `143` 不是 `docker stop` 的默认结果 —— PID 1 收不到 SIGTERM 时反而是 137。

**自测记录（12 题快问快答）**：结果 3 ✅ / 8 🔶 / 1 ❌。错题全部集中在"本日刚被实测修正的反直觉机制"上，说明是记忆尚未二次巩固，而非基础漏洞；6 条需要二次记忆的结论已并入 §5 易错点。

### 6.2 Linux 题：参数扩展

**题目**：`f=/backup/app_2025.tar.gz`，只用参数扩展取出：① 文件名 ② 去掉最后一个扩展名 ③ 只取扩展名 ④ 变量为空时输出 `unknown`。

**结论：背 2 个、认识 4 个，其余现查**

| 类别 | 写法 | 用途 |
|---|---|---|
| **必须会** | `${v:-默认}` | 为空或未设置时给默认值。注意 `[ -z "$v" ] && v=x` 在 `set -e` 下会**误终止脚本**（测试为假时整条 AND 列表返回非零）；且它能直接用在参数位置：`cmd "${1:-/etc/app.conf}"` |
| **必须会** | `${v:?错误信息}` | 必填校验，为空即报错退出；没有等价的单条命令 |
| 认识即可 | `${f##*/}` | 取文件名（= `basename "$f"`） |
| 认识即可 | `${f%/*}` | 取目录（= `dirname "$f"`） |
| 认识即可 | `${f%.*}` / `${f##*.}` | 去掉最后一个扩展名 / 取最后一个扩展名 |
| 认识即可 | `${#v}`、`${v//a/b}` | 长度、全部替换 |

**"必须用"而非"风格偏好"的场景**

| 场景 | 原因 |
|---|---|
| `scratch` / 极简镜像的 entrypoint | **镜像里没有 `basename`**，`scratch` 里连 shell 都没有 |
| 启动脚本 / `.bashrc` | 每次登录都要 fork 一批进程，没有必要 |
| 热循环中的路径处理 | 循环 10 万次、每次 fork 一个 `basename` 会带来秒级差距 |
| `set -euo pipefail` 的脚本 | `${v:?}`、`${v:-x}` 是唯一不会踩 `&&` 陷阱的判空写法 |

**语法速查**：`${变量<操作符>模式}`；`#` 在左 → 从左边删，`%` 在右 → 从右边删；**单写 = 最短匹配，双写 = 最长匹配**。
以 `p=/var/log/nginx/access.log.1` 为例：

| 写法 | 结果 | 等价命令 |
|---|---|---|
| `${p#*/}` | `var/log/nginx/access.log.1` | — |
| `${p##*/}` | `access.log.1` | `basename` |
| `${p%/*}` | `/var/log/nginx` | `dirname` |
| `${p%%/*}` | 空串 | — |
| `${p%.*}` | `/var/log/nginx/access.log` | 去最后一个扩展名 |
| `${p%%.*}` | `/var/log/nginx/access` | 去全部扩展名 |
| `${p##*.}` | `1` | 取扩展名 |

**两个必踩的坑**

| 坑 | 现象 | 说明 |
|---|---|---|
| 给模式加引号 | `"${p##*/}"` 可用，`"${p##'*'/}"` 失效 | 整体加引号防分词是正确的，但**模式中的 `*` 不能单独加引号**，否则变为字面量 |
| 未匹配不报错 | `x=abc; echo ${x%%.def}` → `abc` | 直接原样返回，因此**不能用于格式校验** |

**默认值：`:` 不能省**

| 写法 | 未设置 | 已设置但为空（`v=""`） | 已设置且有值 |
|---|---|---|---|
| `${v-x}` | `x` | **空** ⚠️ | `v` |
| `${v:-x}` | `x` | `x` ✅ | `v` |
| `${v:=x}` | `x` 并赋值给 `v` | 同左 | `v` |
| `${v:?msg}` | 报错并退出脚本 | 同左 | `v` |
| `${v:+x}` | 空 | 空 | `x` |

> 题目第 ④ 问的关键：**变量为空**要用带 `:` 的形式 —— `:-` 与 `-` 的差别就在"空串算不算未设置"。
> 定位：这属于 `Linux-故障索引.md` §2 机制 3「Shell 展开顺序」的一环 —— 参数扩展发生在**分词之前**，因此 `${f##*/}` 的结果不会再被拆分，这也是它比命令替换更安全的原因。日常脚本用 `basename` / `dirname` / `sed` 完全可接受（可读性更好），本内容的价值在于"知道有这条路径"以及读懂他人脚本。

---

## 7. 遗留疑问

| # | 问题 | 状态 |
|---|---|---|
| 1 | PID 1 的"默认处置信号被忽略"在 `signal(7)` 中的原文表述（现象已实测确认，原文未核对） | ⬜ 待查内核文档 |
| 2 | Go runtime `dieFromSignal()` 中 `exit(2)` 回退的官方描述（实测 4-A 得 `2`、补 C 得 `143`，差异全部来自"是不是 PID 1"） | ⬜ 待查 `runtime/signal_unix.go` |
| 3 | `docker stop` 的 10s 超时由 **CLI** 计时还是 **dockerd** 计时？`-t 0` / `-t 30` 分别会发生什么 | ⬜ 待实测 |
| 4 | `signal.Notify` 收到的是 `terminated`（`syscall.SIGTERM.String()`），如何打印成 `SIGTERM` 更清晰 | ⬜ 可选 |
| 5 | `--memory-swap` 的换算规则（`-m 32m --memory-swap 64m` 时最多吃到多少） | ⬜ 待实测 |

---

## 附：本日产出与后续衔接

| 项 | 内容 |
|---|---|
| 原始日志与脚本 | `code/week1/day5/logs/`（`exp1-5.log` / `exp-round2.log` / `exp6-prune.log`）；`run.sh` / `run2.sh` / `prune.sh` 可复跑 |
| 保留的镜像 | `day5-badcmd` / `day5-badcmd-shell` / `day5-oom` / `day5-sig` 四个实验镜像 |
| 已删除 | 14 个已停止容器（含 `Created` 的 `e1a`）；`kind-control-plane` 全程未受影响 |
| 文档同步 | `docs/docker/04-排障索引.md` §二 退出码表（含"谁的问题 + 第一步命令"）与三条反直觉实测结论 |
