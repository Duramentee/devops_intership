# Day 5 学习笔记 · 排障工具链 + 故意制造故障

> 日期：2026-09-15
> 对应模块：`docs/docker/05-排障索引.md`（五步定位法 / 退出码 / 现象索引）
> 参考：`docs/linux/Linux-故障索引.md`（信号语义、进程生命周期、fd）
> 代码目录：`code/week1/day5/`
> 模板：概念 / 命令 / 易错点 / 我的疑问

---

## 今日速览（先看这 5 条）

| # | 结论 |
|---|---|
| 1 | **排障是分层定位，不是猜**：容器在不在 → 怎么退的 → 日志说了什么 → 环境对不对 → 资源够不够（顺序不可颠倒） |
| 2 | **退出码 = 主进程的死亡原因**：`0` 正常结束（服务型进程**反而异常**）/ `1` 应用报错 / `127` 找不到命令 / `137` = 128+9 被 SIGKILL（多半 OOM）/ `143` = 128+15 收到 SIGTERM |
| 3 | **137 与 143 是"优雅关闭"的分水岭**：143 = "请你退"（进程能善后）；137 = "直接打死"（没有任何机会） |
| 4 | **`0` 是最容易被忽略的"故障"**：容器 = 主进程的生命周期，主进程跑完 → 容器退出，哪怕它"没报错" |
| 5 | **磁盘要和容器一起看**：镜像层 + 可写层 + 卷 + 构建缓存，四个都算 `docker system df` 的账 |

---

## 今日任务清单

| # | 任务 | 完成 |
|---|---|---|
| 1 | `CMD` 指向不存在的文件 → 抓 `Exited (127)`，用退出码判断原因 | ⬜ |
| 2 | 起一个立刻退出的容器 → 用 `logs` 找原因（区分 0 与 1） | ⬜ |
| 3 | 用 `-m` 限制内存制造 OOM → 抓 137 + `OOMKilled=true` | ⬜ |
| 4 | 用 `docker stop` 制造 SIGTERM → 抓 143，与 137 对比 | ⬜ |
| 5 | `docker stats --no-stream` 看资源；`docker system df -v` 看磁盘占用 | ⬜ |
| 6 | `docker system prune` 清理（**先看清再删**，别误删卷） | ⬜ |
| 7 | 补做 Day 4 的两道每日一题（容器题 + Linux shell 题） | ✅ 已批改（回执在 `notes/week1/day4.md`） |
| 8 | 四段收尾（概念 / 命令 / 易错点 / 我的疑问） | 🔶 讲义基线已写，**实测后改成自己的话** |

---

## ⚠️ 当前阻塞：Docker 用不了

| 现象 | 命令 | 输出 |
|---|---|---|
| 任何 `docker` 子命令都失败 | `docker images` | `The command 'docker' could not be found in this WSL 2 distro` |
| 真实原因（不是没装） | `ls -l /usr/bin/docker` | 软链指向 `/mnt/wsl/docker-desktop/cli-tools/usr/bin/docker`，**该目标不存在** |
| 旁证 | `ls -d /mnt/wsl/docker-desktop*` | `no matches found` → Docker Desktop 的 VM **没跑起来** |

→ **解法**：Windows 侧启动 Docker Desktop，等鲸鱼图标变绿；若仍报错，检查 Settings → Resources → WSL Integration 是否对本 distro 打开。
→ 下面的「实测记录」等 Docker 恢复后再回填。

---

## 实测记录

### 退出码对照（本日实测）

| 制造方式 | `State.ExitCode` | `State.OOMKilled` | 机制 | 命令 |
|---|---|---|---|---|
| | | | | |

### 五步定位法逐条演练

| 步 | 问什么 | 命令 | 本日实测输出 |
|---|---|---|---|
| 1 | 容器还在吗 | `docker ps -a` | |
| 2 | 怎么退的 | `docker inspect 名 --format '{{.State.ExitCode}} {{.State.OOMKilled}} {{.State.FinishedAt}}'` | |
| 3 | 日志说了什么 | `docker logs --tail 100 名` | |
| 4 | 环境对不对 | `docker exec -it 名 sh` | |
| 5 | 资源够不够 | `docker stats --no-stream`；`docker system df -v` | |

---

## 每日一题（Day 5 · 排障题）

> 容器 `Exited (137)`。写出排查顺序（≥4 步），并回答：**137 与 143 的区别是什么？为什么这个区别对「优雅关闭」很关键？**
>
> ⚠️ 先自己写答案，再看 `docs/docker/05-排障索引.md` §二。

**我的答案：**

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

## Linux 每日一题（Day 5 · 参数扩展）

> 已知 `f=/backup/app_2025.tar.gz`，**只用参数扩展**取出：
> ① 文件名（去目录）② 去掉最后一个扩展名（`app_2025.tar`）③ 只取扩展名（`gz`）④ 变量为空时输出 `unknown`。

**我的答案：**

---

## 概念

> 学完填：为什么容器"没报错"也会退出、退出码是谁记录的、137/143 差在哪、排障为什么要按顺序。
> ⚠️ 下表是**讲义基线**（先看懂机制），实测后**用自己的话重写一遍**才算学会。

| 要点 | 机制（先看懂） | 我的重写（实测后填） |
|---|---|---|
| 容器为什么会 `Exited (0)`，为什么这算故障 | 容器生命周期 = **PID 1 的生命周期**：主进程跑完 → 容器退出。对**服务型**进程来说「正常结束」= 没有进程守着端口 = 服务没了；带 `--restart` 会陷入无限重启（K8s 里就是 `CrashLoopBackOff`）。容器不是虚拟机，**没有 init 兜底**（除非 `--init` / CMD 里自己 exec） | |
| 退出码是谁写进容器对象里的（dockerd 还是内核） | 内核在进程退出时产生 wait status；**dockerd（经 containerd-shim）是父进程**，调 `wait()` 拿到后写进 `State.ExitCode`。所以退出码是「**父进程视角的记录**」。→ 同一机制解释僵尸进程：没人 `wait()` 就变 `Z` | |
| `137` vs `143`：机制差在哪 | `137` = 128+**9** = **SIGKILL**；`143` = 128+**15** = **SIGTERM**。`128+n` 是 shell 传统编码，含义是「被信号 n 杀死」。分水岭：**SIGTERM 可被捕获/忽略**（能善后），**SIGKILL 不可捕获、不可忽略**（没有任何机会） | |
| 为什么 `docker stop` 默认是"先 143 再 137" | `stop` 先对 PID 1 发 **SIGTERM**，等 `--time`（默认 **10s**）优雅退出；超时才升级 **SIGKILL**。→ 同一个容器可能 143 也可能 137，取决于**应用有没有在 10s 内退干净** | |
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
| 把 137 一律当 OOM | 只查 `OOMKilled`，别的原因全漏了 | **137 是「被 SIGKILL」的统称**：`docker kill`、`docker rm -f`、`stop` 超时、宿主 OOM 都给 137。要区分看 `OOMKilled=true` 或 `docker events --filter event=oom` |
| 把 143 当"服务崩了" | 误判为应用故障 | 143 常是 `docker stop` 的**正常产物**；关键看应用**是否在 10s 内自己退干净**（日志里应有善后输出） |
| 容器 `Exited (0)` 却以为没事 | 服务静默消失，排查跑偏 | 服务型进程必须**前台常驻**；`CMD` 写成"启动脚本跑完就退"必踩此坑 |
| 用 `docker exec` 去查已退出的容器 | `Error response from daemon: Container ... is not running` | 已停止的容器只能用 `logs` / `inspect` / `cp`；要进 rootfs：`docker commit` 做临时快照，或 `docker run` 挂它的卷 |
| `CMD` 写成 **shell 形式**导致收不到信号 | `docker stop` 要等满 10s 才被 137 打死，日志里**没有**优雅退出 | `CMD ["app"]`（**exec 形式**）→ 应用才是 PID 1；shell 形式下 PID 1 是 `sh`，**信号不会转发**给子进程（对应 `Linux-故障索引.md` §2 机制 5） |
| `docker system prune` 一把梭 | 误删镜像 / 构建缓存 | 先 `docker system df -v` 看清；卷单独 `docker volume prune`（默认只删**匿名**卷） |
| 在宿主 `df` 里找容器的"磁盘满" | 两边数值对不上 | 容器有独立**挂载命名空间**；要在**容器内** `df -h` / `du` 才有意义 |
| 只看 `docker ps`（不加 `-a`） | "容器不见了" | 退出的容器不在 `docker ps` 里，永远用 `-a` |

---

## 我的疑问

| # | 题目 | 考点 | 状态 |
|---|---|---|---|
| 1 | `docker stop` 的 10s 超时是 **CLI** 在计时还是 **dockerd**？`-t 0` / `-t 30` 分别会发生什么？ | 谁负责把 SIGTERM 升级成 SIGKILL | ⬜ |
| 2 | shell 形式的 `CMD` 下，SIGTERM 是**完全收不到**，还是"收到了但不转发"？ | 信号 + PID 1 特殊语义 | ⬜ |
| 3 | "137 不一定 OOM"——那怎么才能确定**到底**是谁杀的？（`docker kill` / `rm -f` / stop 超时 / 宿主 OOM 怎么区分） | 事件流 `docker events` + 退出码的局限 | ⬜ |
