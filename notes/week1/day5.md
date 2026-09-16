# Day 5 学习笔记 · 排障工具链 + 故意制造故障

> 日期：2026-09-15
> 对应模块：`docs/docker/05-排障索引.md`（五步定位法 / 退出码 / 现象索引）
> 参考：`docs/linux/Linux-故障索引.md`（信号语义、进程生命周期、fd）
> 代码目录：`code/week1/day5/`
> 模板：概念 / 命令 / 易错点 / 我的疑问

---

## 今日速览（先看这 7 条，全是本机实测出来的）

| # | 结论 |
|---|---|
| 1 | **排障是分层定位，不是猜**：容器在不在 → 怎么退的 → 日志说了什么 → 环境对不对 → 资源够不够（顺序不可颠倒） |
| 2 | **退出码 = 主进程的死亡原因**：`0` 正常结束（服务型进程**反而异常**）/ `1` 应用报错 / `127` 找不到命令 / `137` = 128+9 被 SIGKILL / `143` = 128+15 收到 SIGTERM |
| 3 | ⚠️ **实测翻案**：`docker stop` **不保证**给 143 —— **PID 1 不装 handler 时 SIGTERM 被内核忽略** → 等超时被 SIGKILL = **137**；Go 程序还会拿到 **2**（详见实测记录 §3） |
| 4 | ⚠️ **实测翻案**：**"优雅关闭成功"的标志是 `ExitCode 0` + 日志有善后**（实测 `4-B`）；`Exited (143)` 只说明"被 SIGTERM 杀死"，**善后可能压根没发生** |
| 5 | ⚠️ **实测翻案**：**`137` ≠ OOM**。`docker kill`、`rm -f`、`stop` 超时、宿主 OOM 都给 137（实测 `4-C` 就是 `OOMKilled=false` 的 137）；只有 `OOMKilled=true` 才是 OOM |
| 6 | **`0` 是最容易被忽略的"故障"**：容器 = 主进程的生命周期，主进程跑完 → 容器退出，哪怕它"没报错" |
| 7 | **磁盘要和容器一起看**：镜像层 + 可写层 + 卷 + 构建缓存四类账；`prune` 不带 `-a` 是倒垃圾、带 `-a` 是清库存 |

---

## 今日任务清单

| # | 任务 | 完成 |
|---|---|---|
| 1 | `CMD` 指向不存在的文件 → **exec 形式** = `Created` + `State.Error`；**shell 形式** = `Exited (127)` | ✅ |
| 2 | 起一个立刻退出的容器 → `Exited (0)`，想清它为什么算故障 | ✅ |
| 3 | `-m 32m` 制造 OOM → `137` + `OOMKilled=true`（顺带发现 `-m 32m` 能吃 56MiB） | ✅ |
| 4 | 让应用捕获 SIGTERM → 实测出**四种**结局：`143` 只出现在"非 PID 1"；PID 1 是 `137` / `2` / `0` | ✅ 超出预期 |
| 5 | `docker stats --no-stream`、`docker system df -v`、`docker top` | ✅ |
| 6 | `docker system prune` 清理（先预检爆炸半径） | ✅ 删 14 个停止容器 + 431.6MB 缓存；镜像/卷全保住 |
| 7 | 补做 Day 4 的两道每日一题 | ✅ 已批改（回执在 `notes/week1/day4.md`） |
| 8 | 四段收尾（概念 / 命令 / 易错点 / 我的疑问） | ✅ 实测已回填 |

---

## ⚠️ 环境阻塞：已解除（排障过程本身值得记）

| 现象 | 命令 | 输出 |
|---|---|---|
| 任何 `docker` 子命令都失败 | `docker images` | `The command 'docker' could not be found in this WSL 2 distro` |
| 真实原因（**不是没装**） | `ls -l /usr/bin/docker` | 软链指向 `/mnt/wsl/docker-desktop/cli-tools/usr/bin/docker`，**该目标不存在** |
| 旁证 | `ls -d /mnt/wsl/docker-desktop*` | `no matches found` → Docker Desktop 的 VM 没跑起来 |

→ **解法**：Windows 侧启动 Docker Desktop。**已解除**，随后全部实验正常跑通：

```
Server: Docker Desktop 4.90.0 (238679)
 Engine: 29.7.2   containerd: v2.3.3   runc: 1.4.3
```

> **方法论**：报错文案说"在 WSL 里找不到 docker"，但**根因不在 docker 的安装**，而在"软链的目标不存在"。→ 排障时永远**顺着命令的解析链往回走一步**（`docker` → `/usr/bin/docker` → 软链目标 → VM 是否在跑）。这条和本文后面"退出码要往回走一步看谁发的信号"是同一个思路。

---

## 实测记录

> 环境：Docker Desktop 4.90.0 · Engine **29.7.2** · containerd 2.3.3 · runc 1.4.3
> 原始日志：`code/week1/day5/logs/exp1-5.log`（实验 1~5）、`logs/exp-round2.log`（第二轮对照）、`logs/exp6-prune.log`（清理）
> 脚本：`run.sh`（实验 1~5）、`run2.sh`（机制对照）、`prune.sh`（实验 6）

### 1. 退出码总表（全部本机实测）

| # | 制造方式 | `ps -a` 的 STATUS | ExitCode | OOMKilled | 机制 |
|---|---|---|---|---|---|
| 1-A | **exec** 形式 CMD 指向不存在文件 | **`Created`** | `127` | false | ⚠️ 容器**从没跑起来**：runc 在 **create 阶段**就失败 |
| 1-B | **shell** 形式 CMD（同一个路径） | `Exited (127)` | `127` | false | PID 1 = `/bin/sh -c /app/not-exist`，sh 报 `not found` 后以 127 退出 |
| 2 | `sh -c 'echo starting; echo done'` | `Exited (0)` | `0` | false | 主进程跑完 → 容器退出（**服务型进程的反面教材**） |
| 3-A | `-m 32m` + 内存吞噬程序 | `Exited (137)` | `137` | **true** | OOM：内核 OOM killer 发 **SIGKILL** |
| 3-E | `-m 256m --memory-swap 256m` | `Exited (137)` | `137` | **true** | 同上，且这次是**真·硬限制**（无 swap） |
| 4-A | Go 是 PID 1，**不装** handler | `Exited (2)` | **`2`** | false | ⚠️ **不是 143**！PID 1 语义 + Go runtime 回退 `exit(2)`（见 §3） |
| 4-B | Go 是 PID 1，**捕获** SIGTERM 并善后 | `Exited (0)` | **`0`** | false | ✅ **优雅关闭成功的标志是 0，不是 143** |
| 4-C | Go 是 PID 1，`signal.Ignore(SIGTERM)` | `Exited (137)` | `137` | false | `stop -t 3` 超时 → **SIGKILL**；⚠️ **137 ≠ OOM** |
| 4-D | `sh -c 'sleep 600'`（PID 1 = sh） | `Exited (137)` | `137` | false | 同 4-C：信号没生效 → 等超时被打死 |
| 补 B | `sleep 600` **直接**做 PID 1 | `Exited (137)` | `137` | false | **铁证**：PID 1 不装 handler → SIGTERM 被**内核忽略** |
| 补 C | 同一个 Go 程序**不是 PID 1**（子进程 pid=7） | — | **`143`** | — | ⚠️ **143 的真实来源**：非 PID 1 时默认处置生效 → 被信号杀死 |

### 2. 五步定位法 · 逐条实测

| 步 | 命令 | 本机实测结果 |
|---|---|---|
| 1 | `docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'` | 一眼拿到 STATUS（含退出码）；`e1a` 显示 **`Created`** 而不是 `Exited` |
| 2 | `docker inspect 名 --format '{{.State.ExitCode}} oom={{.State.OOMKilled}} {{.State.StartedAt}} → {{.State.FinishedAt}}'` | 137 的 oom1：`137 / true / 07:35:39.46 → 07:35:42.11`（**活了 2.65s**） |
| 2' | `docker inspect 名 --format '{{.State.Error}}'` | 1-A 的 e1a：完整的 runc 报错 —— **这是 Created 容器唯一的线索** |
| 3 | `docker logs --tail 100 名` | oom1 停在 `allocated 56 MiB`；e1a（Created）**日志为空** |
| 4 | 已退出容器：`docker run --rm -it --entrypoint sh 镜像` / `docker cp` | ⚠️ `docker exec` 直接失败（见 §5） |
| 5 | `docker stats --no-stream`；`docker inspect -f '{{.HostConfig.Memory}}'` | ⚠️ stats 对已退出容器返回 **`0B / 0B`**（见 §5） |
| 补 | `docker events --since <Start> --until <现在>` | 拿到 `container oom` + `container die (exitCode=137, execDuration=2)`（见 §4） |

### 3. 今天最大的收获：PID 1 的信号语义（五个对照实验钉死）

| 实验 | PID 1 是谁 | 装 handler 了吗 | `docker stop` 结果 | 用时 |
|---|---|---|---|---|
| 4-A | `/sig`（Go） | ❌ 没装 | **`Exited (2)`** | 0.30s |
| 4-B | `/sig`（Go） | ✅ `signal.Notify` | **`Exited (0)`** | 2.29s（应用自己的 2s 善后） |
| 4-C | `/sig`（Go） | ✅ `signal.Ignore` | **`Exited (137)`** | 3.29s（= `-t 3` 超时） |
| 4-D | `/bin/sh` | ❌ | **`Exited (137)`** | 3.29s |
| 补 B | `sleep` | ❌ | **`Exited (137)`** | 3.29s |
| 补 C | `/bin/sh`（**Go 是子进程** pid=7） | ❌ | 子进程 **`143`** | 立即 |

**推出来的机制链**（⚠️ 我的推断 + 实测证据，**尚未在书里/内核文档核对原文**）：

| 步 | 发生什么 | 证据 |
|---|---|---|
| 1 | 内核给 **PID 1** 一个保护：**默认处置为"终止"的信号会被忽略**，除非进程自己装了 handler（SIGKILL/SIGSTOP 除外） | 补 B：`sleep` 做 PID 1，`stop -t 3` 等满 3.29s → 137（若 SIGTERM 生效，`sleep` 会立刻死） |
| 2 | 所以不装 handler 的 PID 1 **收不到** SIGTERM 的效果 → 只能等超时被 SIGKILL | 4-C、4-D、补 B 全部 137 + 3.29s |
| 3 | Go runtime 给所有信号都装了内部 handler。没注册 `Notify` 时走 `dieFromSignal()`：**改回 `SIG_DFL` → `raise(SIGTERM)`**；若信号没把进程杀死（PID 1 被忽略）→ **回退 `exit(2)`** | 4-A = **2**；补 C（非 PID 1，同样的 `raise` 生效）= **143** |
| 4 | `143` 的真实来源：进程**不是 PID 1**，或信号以默认处置生效 | 补 C 实测 `Terminated` + `CHILD-EXIT=143` |

**三条推论**

| # | 结论 |
|---|---|
| 1 | **`143` 不是 `docker stop` 的标配，`137` 也不是故障专属** —— 同一个 `stop` 命令，结局由"PID 1 是谁 + 装没装 handler"决定 |
| 2 | **"优雅关闭成功"的正确标志 = `ExitCode 0` + 日志里有善后输出**；`Exited (143)` 只说明"被 SIGTERM 杀死"，**善后可能压根没发生** |
| 3 | 想让自己写的服务**收到**信号：① `CMD`/`ENTRYPOINT` 用 **exec 形式**（应用自己当 PID 1）② 代码里显式装 handler ③ 或者加 `--init`（tini）让 init 帮忙转发/收割 |

> 旁证：`docker build` 对 shell 形式 CMD 会警告 —— `JSONArgsRecommended: JSON arguments recommended for CMD to prevent unintended behavior related to OS signals`。这条 warning 说的就是 4-A~4-D 这件事。

### 4. OOM 的完整证据链（实验 3-E）

| 证据 | 实测值 |
|---|---|
| `docker stats` 采样曲线（`-m 256m --memory-swap 256m`） | `74.08MiB (28.94%)` → `138.3MiB (54.04%)` → `202.5MiB (79.12%)` → `0B / 0B` |
| 日志最后 3 行 | `allocated 232 MiB` → `240 MiB` → `248 MiB`（死在 256MiB 之前） |
| `docker inspect` | `ExitCode=137` `OOMKilled=true` `Memory=268435456` `MemorySwap=268435456` |
| `docker events`（放宽 until 后） | `container oom <id> (...)` + `container die <id> (..., exitCode=137, execDuration=2)` |

**三个坑（全是实测踩出来的）**

| 坑 | 现象 | 正确做法 |
|---|---|---|
| **`-m 32m` 不是硬限制** | 实测能吃到 **56 MiB** 才死 | `MemorySwap` **默认 = 2 × `Memory`**（32MiB → 64MiB），多出来是**可换出的 swap**。要硬限制：`--memory-swap` 设成与 `-m` **相同**（3-E 就是这样） |
| **`docker events --until` 会切掉事件** | 第一轮用 `--until <FinishedAt>` → 只看到 `start`，`oom`/`die` 全没了 | `die`/`oom` 事件时间戳（`15:35:42.534`）**晚于** `State.FinishedAt`（`15:35:42.113`）→ `--until` 要用**"现在"或更晚**的时间 |
| **`docker stats` 会骗人** | 对已退出容器返回 `0B / 0B`、`PIDS=0`，**不报错** | 先 `docker inspect -f '{{.State.Status}}'` 确认在跑，再看 stats |

### 5. 已退出容器的命令可用性（实测）

| 命令 | 实测结果 |
|---|---|
| `docker exec sig-default true` | ❌ `Error response from daemon: container db716c6f... is not running` |
| `docker stats --no-stream sig-default` | ⚠️ **不报错**！返回 `0B / 0B`、`MEM %=0.00`、`PIDS=0` ← **最坑的一个**，看着像"容器闲着"，其实容器已经死了 |
| `docker top sig-default` | ❌ `... is not running` |
| `docker logs` / `inspect` / `diff` / `cp` | ✅ 都可用 |

### 6. 127 的两种形态（**修正我之前的讲义**）

| CMD 形式 | Docker 实际执行 | `ps -a` 显示 | ExitCode | `docker logs` | 线索在哪 |
|---|---|---|---|---|---|
| `CMD ["/app/not-exist"]` | runc 直接 `exec /app/not-exist` | **`Created`** | `127` | **空** | `State.Error`（那段 runc 报错） |
| `CMD /app/not-exist` | `/bin/sh -c "/app/not-exist"` | `Exited (127)` | `127` | `/bin/sh: /app/not-exist: not found` | `docker logs` |

- Created 容器的 `State`：`ExitCode=127`、`StartedAt`/`FinishedAt` = **`0001-01-01T00:00:00Z`**（Go 零值）、`Pid=0` → **一眼看出"从没跑过"**
- `docker start e1a` 重试同样失败（CLI 退出码 **1**），容器**永远卡在 Created**
- 「CMD 写错 → 127」这句话**只对 shell 形式成立**；exec 形式是**根本没生成可运行的容器**

### 7. `docker system prune` 的爆炸半径（实验 6 实测）

| 对象 | 实测结果 |
|---|---|
| 已停止的容器 | **14 个全删** —— 含 2 周前的 `docker_test`，也含 `Created` 状态的 `e1a`（⚠️ 没跑起来的也算） |
| 构建缓存 | 回收 **431.6MB**（Build Cache 65 → 38，1.431GB → 999MB） |
| 悬空镜像 | 本次没有（删 0 个） |
| **有 tag 的镜像** | ✅ **全部保留**：`webapp:v1/v2/v3`、`kindest/node`、`mysql`、`rabbitmq`、`golang:1.25-alpine` |
| **卷** | ✅ **4 个全在**（`webvol`、`webvol2` + kind 的两个）—— `prune` 不碰卷 |
| 运行中的 `kind-control-plane` | ✅ 不受影响（Up 7 hours 全程没动） |

⚠️ **`-a` 的后果**（本次只看没执行）：会额外删掉 `webapp:v1/v2/v3`、`kindest/node`（1.34GB + 1.31GB）、`mysql`、`rabbitmq` —— **第 2 周要用的全在里面**。

> 口诀：**不带 `-a` 是"倒垃圾"，带 `-a` 是"清库存"。**｜清理前永远先跑 `docker system df` + `docker ps -a --filter status=exited`。

---

## 每日一题（Day 5 · 排障题）· 已批改

> 题目：容器 `Exited (137)`。写出排查顺序（≥4 步），并回答：**137 与 143 的区别是什么？为什么这个区别对「优雅关闭」很关键？**

**我的原答：**

1. 退出码是 137，说明它跑起来过 → `docker ps -a` 看到的是停止状态
2. `docker inspect` 查退出状态 / 退出码 / 是否 `OOMKilled`（是的话到此就能定因），并用 `FinishedAt` 定位报错时段
3. `docker logs` 找问题，看日志能不能说明为什么被内核 kill
4. 再看环境（`docker exec -it xx sh`）和资源（`docker stats`），判断是应用配置问题还是资源不足被强杀

> 137 vs 143：143 优雅退出超出指定时段后会被 137 打死。

**批改：🔶 中上 —— 四步骨架对，3 处硬伤 + 概念答偏**

| 步 | 判定 | 问题在哪 |
|---|---|---|
| 1 `docker ps -a` | 🔶 动作对，**理由是倒推的** | 退出码本来就来自 `ps -a` 的 STATUS 列；用"已知 137"去论证顺序，逻辑就空了。这一步真正要拿的是「**在不在 / 是不是 `Restarting` / 重启了几次**」，不是验证 137 |
| 2 `docker inspect` | ✅ **最扎实** | 补：`StartedAt` 与 `FinishedAt` **配对**算出活了多久（秒级 → 怀疑 OOM）；`State.Error`；⚠️ `OOMKilled=false` **不是结案**（137 还可能是 `docker kill` / `rm -f` / stop 超时 / 宿主 OOM） |
| 3 `docker logs` | 🔶 **前提错了** | **SIGKILL 不可捕获** → 应用**没有机会**写"我被杀了"。日志只能看"**死之前在干什么**"（如停在 `loading 2GB file`）；OOM 的原始证据在**内核侧**：`docker events --filter event=oom` / `journalctl -k \| grep -i oom` |
| 4 `exec` + `stats` | 🔶 **顺序硬伤** | 容器已退出 → `exec` 报 `is not running`、`stats` 无输出。替代：`docker run --rm -it --entrypoint sh 镜像` / `docker cp 名:/路径 /tmp/` / `docker inspect -f '{{.HostConfig.Memory}}'` |
| 137 vs 143 | 🔶 答的是**流程**不是**区别** | 区别在「**可捕获 vs 不可捕获**」：143 = SIGTERM，**能善后**；137 = SIGKILL，**必死且无机会**。你说的"stop 超时升级为 137"是流程（✅ 对），但不是区别本身 |

**为什么这个区别对"优雅关闭"关键（题眼）**：优雅关闭的**全部机会**就是「收到 SIGTERM → 被 SIGKILL」这段窗口。窗口里要：停接新请求 → 处理完在途请求 → 关连接 → 刷盘/注销。**做到 = 143，没做到 = 137**。137 意味着连接被硬断、在途请求全丢、上游看到 5xx —— 这就是 K8s 里 `terminationGracePeriodSeconds` + `preStop` 存在的原因。

**修正后的排查顺序（抄这一版，已按实测校验）**

| 步 | 问什么 | 命令 | 实测校验点 |
|---|---|---|---|
| 1 | 在不在 / 什么状态 | `docker ps -a` | 顺带拿退出码；还要看是不是 `Restarting` / **`Created`** |
| 2 | 怎么退的 | `docker inspect 名 --format '{{.State.ExitCode}} oom={{.State.OOMKilled}} {{.State.StartedAt}} → {{.State.FinishedAt}} {{.State.Error}}'` | `StartedAt→FinishedAt` 差 **2.65s**；`State.Error` 是 Created 容器的唯一线索 |
| 3 | 日志最后说了什么 | `docker logs --tail 100 名` | 日志停在 `allocated 56 MiB` —— 是"死前最后一个成功动作" |
| 4 | **谁杀的它** | `docker events --since <Start> --until <现在>` | ⚠️ `--until` 别用 `FinishedAt`（会切掉 `oom`/`die`）；实测能拿到 `container oom` + `container die (exitCode=137)` |
| 5 | 资源限制是多少 | `docker inspect -f '{{.HostConfig.Memory}} {{.HostConfig.MemorySwap}}' 名` | ⚠️ `MemorySwap` 默认 **2×**；`docker stats` 对已退出容器返回 **`0B/0B`（假数据）** |
| 6 | 环境对不对 | 已退出：`docker run --rm -it --entrypoint sh 镜像:tag` / `docker cp 名:/路径 /tmp/` | ⚠️ **不能 `exec`**（`is not running`） |

> **实测给这道题加了两个"反转"**：① 137 的"真凶"里有一类是**我自己下过的 `docker stop` 超时**（4-C），跟 OOM 毫无关系；② `143` 并不是 `docker stop` 的标配——PID 1 收不到 SIGTERM 时反而是 137。

→ 完整版（含 0/1/2/125/126/127/137/139/143/255 每个码的排查路径）已写进 `docs/docker/05-排障索引.md` §二「按退出码排障」。

---

## 快问快答回执（12 题 · Day 5 收尾自测）

> 规则：一句话一题、凭记忆答（不许翻笔记）。结果 **3 ✅ / 8 🔶 / 1 ❌**。
> 错题**全部集中在今天刚被实测翻案的反直觉机制**上（不是基础漏洞）—— 属于"还没有第二遍记忆"。

**总览**

| # | 我的原答（摘要） | 判定 | 修正 |
|---|---|---|---|
| 1 | 默认发 SIGTERM，10 秒，`-t` 可指定，超时改发 SIGKILL | ✅ | 补：`--stop-signal` 可以换信号 |
| 2 | 128+9 = SIGKILL，143 = 128+15 = SIGTERM | ✅ | — |
| 3 | 不一定 OOM；`inspect` 看 `OOMKilled`，true 才是 | ✅ | 补：`false` 时还要用 `events` 排掉"stop 超时 / 人杀的" |
| 4 | 内核发 SIGTERM，进程没装 handler 就会被忽略 | 🔶 | **漏掉最关键的前提**：只有 **PID 1** 才享受这个"忽略"保护 |
| 5 | **143**（理由：没注册 `signal.Notify` = 没 handler → 忽略信号） | ❌ | 实测是 **`2`**（Go runtime 给所有信号都装了内部 handler）——见下方「三题一起讲」 |
| 6 | 看是不是 143，再 `inspect` 查退出时间 | 🔶 | 判据是 **`ExitCode 0` + 善后日志**；`143` 恰恰**不是**成功 |
| 7 | 显示"待运行/停摆"，查 log 会提示 runc 错误 | 🔶 | 状态叫 **`Created`**；而且 **`docker logs` 是空的** → 要看 `State.Error` |
| 8 | 1，用 `inspect` 能查到 | 🔶 | 退出码是 **127**；具体信息在 **`docker logs`**（`/bin/sh: ... not found`）；`1` 是 **`docker start` 自己**的返回码 |
| 9 | 去内核查信号，命令不知道，可能是 `sysctl` | 🔶 | `docker events --since <Start> --until <现在>`（`die` 事件带 `exitCode`）；内核层 `journalctl -k \| grep -i oom`。⚠️ **`sysctl` 是读写内核参数的**（如 `net.ipv4.ip_forward`），不是查日志的工具 |
| 10 | 大约 48M，因为有 swap；限制就取消 swap | 🔶 | 实测 **56 MiB**（上限 = `Memory + swap` = 32 + 32 = **64 MiB**）；硬限制要写出来：`-m 32m --memory-swap 32m` |
| 11 | exec / stats 不能用，其余可用；会骗人的"感觉是 top" | 🔶 | `exec` ❌ / **`stats` ⚠️ 能用但会骗人**（返回 `0B/0B` 且**不报错**）/ `top` ❌ / `logs`·`inspect`·`diff`·`cp` ✅。top 的"宿主视角"是**正常行为**（Day 1 用过），不是骗人 |
| 12 | 删所有默认容器，不碰运行中的容器 | 🔶 | **删**：所有**已停止**容器 + **构建缓存** + 悬空镜像 + 未使用的自定义网络；**不碰**：运行中容器、**有 tag 的镜像**、**所有卷** |

### 三题一起讲：4️⃣ + 5️⃣ + 6️⃣ 是同一个机制

我的推理链是「没装 handler → 信号被忽略 → **143**」。前半句对，错在**漏掉了一个前提**：

| 问题 | 正确答案 | 对应实测 |
|---|---|---|
| **谁**会被内核忽略"默认处置为终止"的信号？ | **只有 PID 1**（内核对 init 的保护） | 补 B：`sleep` 直接做 PID 1 → `stop` 等满 **3.29s**（信号没生效） |
| 非 PID 1 的进程没装 handler 呢？ | **照样被杀死 → `143`** | 补 C：同一个 Go 程序做**子进程** → `Terminated` + **`CHILD-EXIT=143`** |
| Go 做 PID 1 且没 `Notify`？ | **`2`** —— Go runtime 给**所有**信号都装了内部 handler，走 `dieFromSignal()`：置回 `SIG_DFL` → `raise(SIGTERM)` → 因是 PID 1 又被忽略 → **回退 `exit(2)`** | 4-A：`Exited (2)` |

> **一句话**：`143` 只属于"**信号真的生效了**"的情况；PID 1 会把信号**吃掉**，于是结局变成 **`137`**（等超时被打死）或 **`2`**（Go 的回退码）。
>
> **第 6 题为什么是陷阱**：`143` 只说明"被 SIGTERM 杀死"，**善后可能压根没发生**。正确判据 = **`ExitCode 0` + 日志里有善后输出**（4-B：日志有"停止接收新连接 / 刷盘 / 注销"，码 `0`）。"看退出时间"有参考价值（4-A 是 **0.30s** 秒退 = 没善后），但**不能当主判据**。

### 错题清单（要形成"第二遍记忆"的 6 条）

| # | 一句话 | 之前错成 |
|---|---|---|
| 1 | **"信号被忽略"只在 PID 1 成立**：非 PID 1 → `143`；Go 做 PID 1 → `2`；`sleep`/`sh` 做 PID 1 → 等超时 `137` | 当成通用规律 |
| 2 | **优雅关闭的判据 = `ExitCode 0` + 善后日志**，不是 143 | 以为 143 = 成功 |
| 3 | **exec 形式 CMD 写错 → `Created` + `logs` 空** → 唯一线索是 `State.Error` | 以为能查 log |
| 4 | 查"谁杀的"用 **`docker events`**（`--until` 用"现在"）+ 内核日志；**`sysctl` 不是查日志的** | 工具张冠李戴 |
| 5 | **`docker stats` 对死容器返回 `0B/0B` 且不报错** —— 唯一"静默骗人"的命令 | 怀疑 top |
| 6 | `prune` 不带 `-a`：**卷和有 tag 的镜像安全，构建缓存会没** | 漏了构建缓存/悬空镜像/网络 |

---

## 补做 · Day 4 每日一题（已完成）

→ 原答 + 批改 + 正确写法已归档到 `notes/week1/day4.md` 的「Day 4 每日一题（Day 5 批改）」。

**今日结论（三行）**：

| # | 结论 |
|---|---|
| 1 | 配置丢失的嫌疑人是 **挂载**（tmpfs / 空 bind / 卷）和 **可写层 + 容器被重建**，以及 **配置本身就在镜像里** —— 不是「没持久化」这种循环论证 |
| 2 | `docker restart` **不动可写层**；会对可写层动手的是 `rm` + `run`（重建） |
| 3 | shell 遍历文件：**glob 不用 `$(ls)`** + **`printf` 不用 `echo`** + **`[ -e ]` 兜底** + **隐藏文件单独处理** |

---

## Linux 每日一题（Day 5 · 参数扩展）· **已跳过（明确不做）**

> 决定：不建议为了这题去背 `${f%%.*}` 这种语法。**日常脚本用 `basename` / `dirname` / `sed` 完全 OK，可读性更高、review 更容易过。**
> 但要知道它是什么、在哪些场景**没有替代品** —— 结论如下。

**这题真正在考什么（不是背符号）**

| # | 考点 | 为什么 |
|---|---|---|
| 1 | **参数扩展是「Shell 展开顺序」里的一环**（发生在**分词之前**） | 所以 `${f##*/}` 的结果**不会再被拆**，在 `"$f"` 引号里也安全；而 `$(basename "$f")` 是**命令替换**，走的是另一条路 |
| 2 | Shell 里字符串操作有**两个世界**：外部命令（fork）vs 内建展开（零成本） | `basename`/`dirname`/`sed`/`awk` 都要 **fork 一个进程**；参数扩展不 fork |
| 3 | **读别人的脚本** | `docker-entrypoint.sh`、`/etc/init.d/*`、K8s 探针脚本里全是 `${x##*/}`、`${VAR:-default}` —— 看不懂就只能复制粘贴 |

**必须会用的（有真实不可替代性）**

| 写法 | 用途 | 为什么没替代 |
|---|---|---|
| `${v:-默认}` | 空或未设置时给默认值 | ⚠️ `[ -z "$v" ] && v=x` 在 `set -e` 下会**误杀脚本**（测试为假时整条 AND 列表返回非零 → 脚本直接退出）；且它只能同句赋值，`cmd "${1:-/etc/app.conf}"` 一行就能给**参数默认值** |
| `${v:?错误信息}` | 必填校验：为空就报错退出 | 没有等价的一条命令；比手写 `if [ -z ]` 短且不会忘 |
| `${!#}` / `${#}` 之类的位置参数处理 | 取"最后一个参数" | 只能用 `eval`，更诡异 |

**认识就够的（读代码能看懂即可）**

| 写法 | 含义 | 等价命令 |
|---|---|---|
| `${f##*/}` | 取文件名 | `basename "$f"` |
| `${f%/*}` | 取目录 | `dirname "$f"` |
| `${f%.*}` | 去掉最后一个扩展名 | `basename "$f" .gz`（不如前者通用） |
| `${f##*.}` | 取扩展名 | `echo "$f" \| awk -F. '{print $NF}'` |
| `${#v}` | 字符串长度 | `wc -c` / `expr length` |
| `${v//a/b}` | 全部替换 | `sed 's/a/b/g'` |

**什么场景下**真的**必须用（不是风格问题）**

| 场景 | 原因 |
|---|---|
| `scratch` / 极简镜像的 entrypoint | **镜像里根本没有 `basename`**（`scratch` 里连 shell 都没有；Day 3 已踩过这个坑） |
| 启动脚本 / `.bashrc` | 每次登录 fork 一堆进程，慢且没必要 |
| 热循环里做路径处理 | 循环 10 万次，每次 fork 一个 `basename` = 秒级差距 |
| `set -euo pipefail` 的健壮脚本 | `${v:?}`、`${v:-x}` 是**唯一**不会踩 `&&` 坑的判空写法 |

> **一句话立场**：**背 2 个（`${v:-x}`、`${v:?msg}`），认识 4 个（`##*/`、`%/*`、`%.*`、`##*.`），剩下的用的时候现查。** 这题的价值在"知道有这条路"，不在"默写符号"。

---

## 附录 · 「参数扩展」到底是什么

> 一句话：**`${}` 里对变量做的"字符串手术"**，由 **bash 自己**完成，**不启动任何外部进程**（`basename`/`sed`/`awk` 都要 fork）。
> 语法统一是 `${变量<操作符>模式}`；把键盘当口诀：`#` 在左 → **从左边删**；`%` 在右 → **从右边删**。

### 四种常用形式

| 类别 | 语法 | 作用 |
|---|---|---|
| 删前后缀 | `${v#pat}` `${v##pat}` `${v%pat}` `${v%%pat}` | 按**模式**删掉开头 / 结尾 |
| 替换 | `${v/旧/新}` `${v//旧/新}` | 只替第一个 / 全部 |
| 默认值与判空 | `${v:-x}` `${v:=x}` `${v:?msg}` `${v:+x}` | 空值时给默认 / 报错 / 反选 |
| 长度、大小写（bash 4+） | `${#v}` `${v^^}` `${v,,}` | 字符数、转大写、转小写 |

### 删前后缀：**单写 = 最短匹配，双写 = 最长匹配**

举例用另一个路径 `p=/var/log/nginx/access.log.1`（**别拿它当题目的答案**）：

| 写法 | 结果 | 含义 | 对应哪个外部命令 |
|---|---|---|---|
| `${p#*/}` | `var/log/nginx/access.log.1` | 从左删到**第一个** `/` | — |
| `${p##*/}` | `access.log.1` | 从左删到**最后一个** `/` | = `basename` |
| `${p%/*}` | `/var/log/nginx` | 从右删到**最后一个** `/` | = `dirname` |
| `${p%%/*}` | （空串） | 从右删到**第一个** `/` | — |
| `${p%.*}` | `/var/log/nginx/access.log` | 从右删到**最后一个** `.` | = 去最后一个扩展名 |
| `${p%%.*}` | `/var/log/nginx/access` | 从右删到**第一个** `.` | = 去全部扩展名 |
| `${p##*.}` | `1` | 只留**最后一个** `.` 之后 | = 取扩展名 |

**两个必踩的坑**

| 坑 | 现象 | 说明 |
|---|---|---|
| 给模式加引号 | `"${p##*/}"` 能用，但 `"${p##'*'/}"` 就废了 | **整体加引号**防分词是正确的；但**模式里的 `*` 不能单独引**，否则变成字面量 |
| 没匹配到不报错 | `x=abc; echo ${x%%.def}` → `abc` | 直接**原样返回** —— 所以不能拿它做"格式校验" |

### 默认值：`:` 不能省

| 写法 | 未设置 | 已设置但为空（`v=""`） | 已设置且有值 |
|---|---|---|---|
| `${v-x}` | 输出 `x` | **输出空** ⚠️ | 输出 `v` |
| `${v:-x}` | 输出 `x` | 输出 `x` ✅ | 输出 `v` |
| `${v:=x}` | 输出 `x` **并赋值给 `v`** | 同上 | 输出 `v` |
| `${v:?msg}` | **报错并使脚本退出** | 同上 | 输出 `v` |
| `${v:+x}` | 空 | 空 | 输出 `x`（反向：有值才用替代） |

> 这就是题目第 ④ 问的关键：**变量为空**要用带 `:` 的形式；`:-` 与 `-` 的差别就在"空串算不算没有"。

### 为什么值得学：省掉子进程

| 场景 | 老写法（至少 fork 一次） | 参数扩展（零子进程） |
|---|---|---|
| 取文件名 | `basename "$f"` | `${f##*/}` |
| 取目录 | `dirname "$f"` | `${f%/*}` |
| 去扩展名 | `basename "$f" .txt` | `${f%.*}` |
| 取扩展名 | `echo "$f" \| awk -F. '{print $NF}'` | `${f##*.}` |
| 判空给默认 | `[ -z "$v" ] && v=默认` | `${v:-默认}` |

> 归属：这属于 `Linux-故障索引.md` §2 机制 3「**Shell 展开顺序**」里的一环 —— 参数扩展发生在**分词之前**，所以 `${f##*/}` 得到的结果**不会再被拆**。

---

## 概念

> 学完填：为什么容器"没报错"也会退出、退出码是谁记录的、137/143 差在哪、排障为什么要按顺序。
> ⚠️ 下表是**讲义基线**（先看懂机制），实测后**用自己的话重写一遍**才算学会。

| 要点 | 机制（先看懂） | 我的重写（实测后填） |
|---|---|---|
| 容器为什么会 `Exited (0)`，为什么这算故障 | 容器生命周期 = **PID 1 的生命周期**：主进程跑完 → 容器退出。对**服务型**进程来说「正常结束」= 没有进程守着端口 = 服务没了；带 `--restart` 会陷入无限重启（K8s 里就是 `CrashLoopBackOff`）。容器不是虚拟机，**没有 init 兜底**（除非 `--init` / CMD 里自己 exec） | |
| 退出码是谁写进容器对象里的（dockerd 还是内核） | 内核在进程退出时产生 wait status；**dockerd（经 containerd-shim）是父进程**，调 `wait()` 拿到后写进 `State.ExitCode`。所以退出码是「**父进程视角的记录**」。→ 同一机制解释僵尸进程：没人 `wait()` 就变 `Z` | |
| `137` vs `143`：机制差在哪 | **实测修正**：`128+n` 只说明"被信号 n 杀死"。`143` = 被 **SIGTERM** 杀（前提：该信号以默认处置**生效**）；`137` = 被 **SIGKILL** 杀。⚠️ **PID 1 不装 handler 时，SIGTERM 会被内核忽略**（`sleep`/`sh` 做 PID 1 实测均如此）→ 表现成 **137**；**Go 程序做 PID 1** 还会因 runtime 回退拿到 **2** | |
| 为什么 `docker stop` 默认是"先 143 再 137" | **实测修正**：原话不准确。`stop` 先对 PID 1 发 **SIGTERM**，等 `--time`（默认 **10s**）后升级 **SIGKILL**。但**结局由"PID 1 是谁 + 装没装 handler"决定**：装了且善后 → **0**（4-B）；忽略/收不到 → 超时 **137**（4-C/4-D/补B）；Go 无 handler → **2**（4-A）。→ 所以 **`143` 反而是最少见的那个** | |
| `OOMKilled=true` 与 `137` 的关系（谁因谁果） | cgroup 内存上限被超 → 内核 OOM killer 直接发 **SIGKILL**（不可捕获）→ 退出码 137；dockerd 再从 cgroup 事件里读到 OOM 标记，写进 `State.OOMKilled=true`。→ **OOM 一定是 137，但 137 不一定 OOM**（`docker kill`、`rm -f`、stop 超时、宿主 OOM 都给 137） | |
| 排障为什么必须"先看在不在，再看为什么退" | ① 第 1 步决定后续命令**能不能用**：容器不在，`exec` 直接报 `is not running`；② 先拿退出码 = 先给死因**分类**，避免在错误方向上翻日志；③ 反过来做还会**破坏现场**（先 `rm` 再 `inspect` 就没了） | |
| 容器"磁盘满"与宿主磁盘满为什么可能不一致 | 容器看到的是自己的**挂载命名空间**（镜像层 ro + 可写层 rw + 卷 + tmpfs）；宿主 `df` 看的是**宿主文件系统**。不一致的三种情形：① 写满的是 tmpfs（内存，宿主 `df` 看不到）② 挂在别的分区/卷上 ③ 文件在宿主上被 `rm` 了但进程（含容器内）仍持 fd → 空间不还（`lsof +L1`） | |

---

## 命令

| 场景 | 命令 | 说明 |
|---|---|---|
| 一眼看状态 | `docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'` | STATUS 列直接写 `Exited (n)` |
| 一眼看退因（**本日主力**） | `docker inspect 名 --format '{{.State.ExitCode}} oom={{.State.OOMKilled}} {{.State.Error}} {{.State.FinishedAt}}'` | 一次拿齐 4 个关键字段 |
| 按退出码筛容器 | `docker ps -a --filter 'exited=137'` | 找"谁被 SIGKILL 了" |
| **看"谁杀了它"（退出码查不到的那一半）** | `docker events --since <Start> --until <现在>`；`--filter event=oom` / `--filter container=名` | ⚠️ **`--until` 别用 `FinishedAt`**（会切掉 `oom`/`die`）；实测输出：`container oom ...` + `container die (... exitCode=137, execDuration=2)` |
| 看 Created 容器的错误 | `docker inspect 名 --format '{{.State.Error}}'` | runc 的原始报错 —— **从没跑起来的容器唯一线索** |
| 看内存限制与 swap | `docker inspect 名 --format '{{.HostConfig.Memory}} {{.HostConfig.MemorySwap}}'` | `MemorySwap` 默认 = **2 × Memory** |
| 清理前预检（**必做**） | `docker system df`；`docker ps -a --filter status=exited`；`docker image ls -f dangling=true` | 先看清爆炸半径；`Created` 的容器也会被删 |
| 确认容器到底在不在跑 | `docker inspect -f '{{.State.Status}}' 名` | ⚠️ `docker stats` 对已退出容器会返回 `0B/0B` 假数据，别信它 |
| 看起止时间（活多久） | `docker inspect 名 --format '{{.State.StartedAt}} → {{.State.FinishedAt}}'` | 秒级就死 → 优先怀疑 OOM / 启动即崩 |
| 看内存限制值 | `docker inspect 名 --format '{{.HostConfig.Memory}}'` | 已退出容器看不了 `stats`，只能看**限制值** |
| 看日志尾部并跟随 | `docker logs --tail 100 -f 名` | 容器已退出也能看 |
| 看 PID 1 到底是什么 | `docker inspect 名 --format '{{.Config.Cmd}} {{.Config.Entrypoint}}'` | 查 **127** 必用的第一条 |
| 忽略 ENTRYPOINT 直接进容器 | `docker run --rm -it --entrypoint sh 镜像:tag` | 镜像没 shell（scratch/distroless）时无效 |
| 进容器看环境 | `docker exec -it 名 sh` | ⚠️ 容器**必须在运行** |
| 宿主视角看容器内进程 | `docker top 名` | 对应 Day 1「容器进程在宿主 `ps` 里看得见」 |
| 资源占用 | `docker stats --no-stream` | 一次快照，不刷屏 |
| 磁盘明细 | `docker system df -v` | 四类账：镜像层 / 可写层 / 卷 / 构建缓存 |
| 清理 | `docker system prune`；`docker volume prune` | 卷默认只删**匿名**卷；`-a` 会扩大删除范围，**先 `df -v` 看清** |
| 容器改了啥 | `docker diff 名` | ⚠️ 要在**删容器之前**跑 |
| 看挂载 | `docker inspect -f '{{json .Mounts}}' 名` | 查 tmpfs / bind / 卷 |
| 看环境变量 | `docker inspect -f '{{json .Config.Env}}' 名` | 查"配置从 env 读"这一类丢失 |

---

## 易错点

| 错法 | 现象 | 正确做法 |
|---|---|---|
| 以为 `docker stop` 一定会得到 `143` | 实测四种结局（0 / 2 / 137 / 143），就是没有"默认 143" | 先搞清楚 **PID 1 是谁、装没装 handler**；信号被内核忽略时只能等超时 → SIGKILL |
| 把"没装 handler → 信号被忽略"当**通用**规律 | 会推出"没 handler 就该 143"，实测全错（快问快答第 4、5 题） | 这个"忽略"保护**只对 PID 1 成立**：非 PID 1 没 handler → **143**；Go 做 PID 1（runtime 自带 handler）→ **2**；`sleep`/`sh` 做 PID 1 → 超时 **137** |
| 用 `sysctl` 去查"谁杀了进程" | 什么都查不到 | `sysctl` 是**读写内核参数**的（如 `net.ipv4.ip_forward`）；查信号/杀进程用 `docker events` +（VM 内）`journalctl -k \| grep -i oom` |
| 把 `docker start` 的返回码 `1` 当成容器退出码 | 记成"127 那个场景返回 1" | `docker start` 失败返回的是 **CLI 自己的** `1`；容器退出码永远看 `docker inspect -f '{{.State.ExitCode}}'` |
| 把 `Exited (143)` 当成"优雅关闭成功" | ❌ 143 只说明被 SIGTERM 杀死 | **成功 = `ExitCode 0` + 日志有善后输出**（实测 4-B：日志有"停止接收新连接/刷盘/注销"） |
| 把 137 一律当 OOM | 只查 `OOMKilled`，别的原因全漏了 | **137 是「被 SIGKILL」的统称**：`docker kill`、`docker rm -f`、`stop` 超时、宿主 OOM 都给 137（实测 4-C：`137` + `OOMKilled=false`）。要区分看 `OOMKilled=true` 或 `docker events` 的 `oom` 事件 |
| 以为 `-m 32m` 就是硬限制 | 实测吃到 **56 MiB** 才死 | `MemorySwap` **默认 = 2 × `Memory`**；要硬限制就 `--memory-swap` 设成与 `-m` 相同 |
| 用 `State.FinishedAt` 当 `docker events --until` | `oom`/`die` 事件**全看不到**（事件时间戳晚于 FinishedAt） | `--until` 用**"现在"或更晚**的时间；`die` 事件里带 `exitCode` + `execDuration`，是直接证据 |
| 用 `docker stats` 判断容器状态 | 已退出容器返回 **`0B / 0B`、PIDS=0，不报错** —— 看着像"容器闲着" | 先 `docker inspect -f '{{.State.Status}}'` 确认在跑；stats **只对运行中容器有效** |
| 用 `docker logs` 查 `127`（exec 形式） | 日志**空**，什么都看不到 | exec 形式下容器压根没跑起来（`Created`）：线索在 **`State.Error`**；shell 形式才有 sh 的 `not found` 日志 |
| 以为"CMD 写错 = Exited (127)" | 实测两种形态：`Created` + `State.Error` vs `Exited (127)` + logs | 看 `docker ps -a` 的 STATUS：**`Created` = 从没跑过**（`StartedAt` 是 `0001-01-01` 零值、`Pid=0`） |
| 把 shell 形式 CMD 的锅直接算在"sh 不转发信号"上 | 本轮**无法区分**"sh 不转发"与"PID 1 忽略" —— 信号压根没被处理（实测：`sleep` 直接做 PID 1 也是 137） | 先把 **PID 1 语义**搞清楚；shell 形式确实有风险，而 **build 时 Docker 自己就会警告**（`JSONArgsRecommended ... related to OS signals`） |
| 把 `137` 当"故障专属" | 4-C 的 137 是 `docker stop` 超时打死的，根本不是故障 | 退出码只说"**怎么死的**"，不说"**是不是故障**"；结合 `docker events` / 自己有没有下过 `stop` 判断 |
| `docker system prune` 一把梭 | ⚠️ **你所有实验容器全没了**（连 `Created`、从没跑起来的也删） | 先 `docker system df` + `docker ps -a --filter status=exited` 预检；**绝不能顺手加 `-a`**（会删掉 `webapp:v1/v2/v3`、`kindest/node` 1.3GB+） |
| 以为 `prune` 会删卷 | 实测 4 个卷**全保留**（kind 的两个、`webvol`、`webvol2`） | `docker system prune` **不碰卷**；卷要 `docker volume prune`（默认还只删**匿名**卷） |
| 容器 `Exited (0)` 却以为没事 | 服务静默消失，排查跑偏 | 服务型进程必须**前台常驻**；`CMD` 写成"启动脚本跑完就退"必踩此坑 |
| 用 `docker exec` / `docker top` 去查已退出的容器 | `Error response from daemon: container ... is not running` | 已停止的容器只能用 `logs` / `inspect` / `cp` / `diff`；要进 rootfs：`docker commit` 做临时快照，或 `docker run --entrypoint sh` 起个同款容器 |
| 在宿主 `df` 里找容器的"磁盘满" | 两边数值对不上 | 容器有独立**挂载命名空间**；要在**容器内** `df -h` / `du` 才有意义 |
| 只看 `docker ps`（不加 `-a`） | "容器不见了" | 退出的容器不在 `docker ps` 里，永远用 `-a` |

---

## 我的疑问

| # | 题目 | 考点 | 状态 |
|---|---|---|---|
| 1 | **PID 1 的"默认处置信号被忽略"规则，内核文档（`signal(7)`）原文怎么写的？** 实测已确认现象（`sleep`/`sh`/Go 做 PID 1 均收不到 SIGTERM 的效果），但**原文没核对过** | 内核 init 保护语义 —— 这是今天最关键的一条 | ⬜ **待查内核文档** |
| 2 | Go runtime 的 `dieFromSignal()` 里那个 `exit(2)` 回退，官方文档/源码怎么描述的？实测 4-A 得 `2`、补 C 得 `143`，差值全部来自"是不是 PID 1" | Go runtime 信号处理 | ⬜ 待查 Go 源码 `runtime/signal_unix.go` |
| 3 | `docker stop` 的 10s 超时是 **CLI** 在计时还是 **dockerd**？`-t 0` / `-t 30` 分别会发生什么？ | 谁负责把 SIGTERM 升级成 SIGKILL | ⬜ |
| 4 | 4-B 里 `signal.Notify` 收到的是 `terminated`（`syscall.SIGTERM.String()`）——怎么打印出 `SIGTERM` 字样更清楚？ | 小改进，日志可读性 | ⬜ 可选 |
| 5 | `--memory-swap` 具体怎么换算（`-m 32m` + `--memory-swap 64m` 时容器最多能吃到多少）？ | cgroup v2 内存限制语义 | ⬜ 待实测 |

---

## 今日善后清单（收尾）

| # | 事项 | 状态 |
|---|---|---|
| 1 | 实验容器清理 | ✅ `docker system prune` 删掉 **14 个已停止容器**（含 `Created` 的 e1a）；`kind-control-plane` 全程 Up |
| 2 | 保留给 Day 6 用 | `day5-badcmd` / `day5-badcmd-shell` / `day5-oom` / `day5-sig` 四个镜像（做 `--cap-drop` 实验正好要用） |
| 3 | 原始日志归档 | ✅ `code/week1/day5/logs/`：`exp1-5.log` / `exp-round2.log` / `exp6-prune.log` |
| 4 | 脚本可复跑 | ✅ `run.sh` / `run2.sh` / `prune.sh`（各自 `cd "$(dirname "$0")"`，不依赖外部路径） |
| 5 | 排障索引同步 | ✅ `docs/docker/05-排障索引.md` §二 新增「按退出码排障」+「Day 5 实测三条颠覆性结论」 |
| 6 | Day 4 遗留题闭环 | ✅ 回执在 `notes/week1/day4.md` |
| 7 | 进度表更新 | ✅ `plan/求职学习计划.md` §0 现状 + §7 勾选表（第 1 周 → 🟡 Day 1~5 完成） |
| 8 | 遗留待查 | ⬜ 内核 `signal(7)` 的 init 保护原文、Go `dieFromSignal()` 源码（见「我的疑问」） |
| 9 | 快问快答自测（12 题） | ✅ 结果 3✅/8🔶/1❌；回执 + 错题清单已并入本文 |
| 10 | 笔记整理 | ✅ 顺序调整为：速览 → 任务 → 环境 → 实测 → 自测/回执 → 附录 → 四段 → 善后/明日起点（收尾全部放文末） |

---

## 明天（Day 6）起点

| 项 | 内容 |
|---|---|
| 主题 | 容器安全 + Dockerfile 收尾（`USER` 非 root / `--cap-drop=ALL` / `--read-only` / `.dockerignore` / `HEALTHCHECK`） |
| 现成素材 | `webapp:v3`（12.6MB）+ 今天的 `day5-sig` 镜像（拿来试 `--cap-drop` / `--read-only`） |
| 已埋的钩子 | ① `scratch` 里没 shell → 排障要用 `--entrypoint`（Day 3 已踩）② 今天证明了"**只有 PID 1 才谈信号语义**"③ `docker_test` 容器已被 prune 删掉（镜像还在） |
| 每日一题预判 | 概念题：为什么"容器里是 root"比"宿主上是 root"风险低？挂 `docker.sock` / `--privileged` 后还成立吗？ |
