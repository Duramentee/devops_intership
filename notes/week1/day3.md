# Day 3 · 多阶段构建与镜像瘦身

> 日期：2026-09-13 · 代码：`code/week1/day3/`（`Dockerfile`、`Dockerfile.scratch`）· 原笔记备份：`/tmp/day3-notes-backup.md`
> 关联文档：`docs/docker/03-Dockerfile词典.md` §六（多阶段构建）· §四（缓存与顺序）· `docs/docker/01-架构与原理.md` §七/§八
> 产出：`webapp:v1` 449MB → `v2` 25.3MB（alpine 多阶段）→ `v3` 12.6MB（scratch）· 二进制始终为 **8037381 字节（7.67MiB）**

---

## 1. 结论速览

| # | 结论 |
|---|---|
| 1 | 多阶段构建**不是"删东西"，而是"隔离"**：builder 的文件在自己的文件系统里，最终镜像的层根本不含它们，`COPY --from` 是唯一通道 |
| 2 | **判定"什么会进镜像"的规则只有一条：指令执行后留在文件系统里的所有改动 = 一层**。Docker 不区分产物与中间产物 |
| 3 | 体积有**两个尺度**：`DISK USAGE`（本地解压落盘）与 `CONTENT SIZE`（压缩后、实际传输）；比较时必须用同一列 |
| 4 | v1 体积构成：`COPY /target/ /` **254MB**（Go 工具链）+ `RUN go build` **91.8MB**（其中 82.4MB 是 GOCACHE）+ alpine rootfs 8.98MB，三层占 79% |
| 5 | **静态链接是上 `scratch` 的前提**：Go 默认静态（runtime + 标准库 + 代码打进一个 ELF）；`CGO_ENABLED=0` 把"恰好静态"变成"保证静态" |
| 6 | **`scratch` 的代价是可运维性归零**：没有 shell、CA 证书、tzdata、`/etc/passwd`。v2 多出的 12.7MB 就是为这些付的费用 |
| 7 | 构建缓存是 **cache key 链（内容寻址）**：父层 key + 指令字符串 + 输入内容哈希；**与 overlay2 无关**（overlay2 管的是运行期层挂载） |

---

## 2. 机制

### 2.1 多阶段构建是什么

一个 Dockerfile 中写**多个 `FROM`**，每个 `FROM` 起一个**独立阶段**（可用 `AS 名字` 命名）。每个阶段有**自己的文件系统**，阶段之间只能通过 `COPY --from=<阶段>` **单向搬运文件**；**只有最后一个阶段的结果成为最终镜像**。

### 2.2 builder 阶段为什么不进最终镜像

镜像是"层"叠加的，而层**只由被采纳的指令**产生。builder 阶段写下的 254MB 工具链与 82.4MB GOCACHE 全在**builder 自己的文件系统**里；最终镜像从 runtime 阶段开始计算层，不用 `COPY --from` 显式搬运，那些内容**根本无法进入**。机制是**隔离**，不是"删除"。

| 实测对照 | v1（单阶段） | v2（多阶段） |
|---|---|---|
| 运行时 `/app`（v1 为 `/home/test`）内容 | `main.go`、`go.mod`、`webapp`（源码一并交付） | 只有 `webapp` |

### 2.3 静态链接与 `scratch` 的前提

| 问题 | 答案 |
|---|---|
| Go 二进制为什么能独立运行 | 编译期把 **runtime（调度器 + GC）+ 标准库 + 你的代码** 复制进产物，形成静态 ELF：运行时不查找 `.so`，也不查找动态链接器。工具链只在编译那一刻需要 |
| `CGO_ENABLED=0` 的作用 | 关闭 cgo → 不调用 C 编译器、不链接 libc/musl → 产出纯静态 ELF |
| v1 为什么也是静态的 | 只是环境巧合：`golang:alpine` 内**没有 gcc**，cgo 不可用。一旦换成带 gcc 的基础镜像或 `apk add gcc`，同一份代码会变成动态链接 → 在 `scratch` 中报 `exec /app: no such file or directory`。显式声明才是**保证** |
| 为什么 `WORKDIR` 在 `scratch` 中也有效 | 它只是镜像配置字段（OCI 配置里的 `process.cwd`），由运行时在 `execve` 前 `chdir`，不依赖 shell |
| `CGO_ENABLED=0` 为什么没有改变体积 | v1/v2/v3 的二进制都是 8037381 字节 —— 多阶段只改**打包方式**，不改**编译结果**；该开关的价值是**可复现** |

### 2.4 瘦身的三层收益

| 收益 | 说明 |
|---|---|
| 传输更快 | 影响 `CONTENT SIZE`（pull / push） |
| 攻击面更小 | 镜像内没有编译器、包管理器、shell，逃逸后手里没有可用工具 |
| K8s 场景启动更快 | 节点磁盘占用小 + 拉取镜像快 → 滚动升级 / 扩容 / 故障重建都更快 |

### 2.5 "能跑 ≠ 好用"的量化

v3（12.6MB）能够运行，是因为静态 ELF 不需要 libc 与动态链接器；但它**失去**了：shell（`docker exec` 排障）、CA 证书（HTTPS 出站）、tzdata（本地时区）、`/etc/passwd`。v2 多出的 12.7MB 正是为这些能力付的费用 —— 生产环境常用 `distroless` 或 `alpine` 折中。

### 2.6 两套缓存不要混：Docker 层缓存 vs Go 构建缓存

| 项 | Docker 层缓存（决定输出里的 `CACHED`） | Go 构建缓存（GOCACHE） |
|---|---|---|
| 是什么 | 构建器对每一层计算出的 cache key | Go 工具链自己的编译中间产物目录（`/root/.cache/go-build`） |
| 键的组成 | 父层 key + 指令字符串 + **输入文件内容哈希** | Go 对各包输入（源码、编译标志、工具链版本）的哈希 |
| 作用 | 决定"这一层能否复用旧结果" | 决定"这个包能否跳过重新编译" |
| 会不会进镜像 | 不会（缓存在构建器侧） | **会** —— 它写在 `RUN` 那一层的文件系统里（本日实测 82.4MB 全部进了镜像） |
| 相关命令 | `docker build` 的 `CACHED`、`docker builder prune` | `go env GOCACHE` |

→ v1 那个 91.8MB 的层 = 7.7MB 产物 + 82.4MB GOCACHE：**Go 的构建缓存被 Docker 当作"层的内容"存了下来**。它与"Docker 层缓存是否命中"是两件独立的事。

---

## 3. 命令

| 场景 | 命令 | 说明 |
|---|---|---|
| 看镜像体积（两个尺度） | `docker images webapp` | `DISK USAGE` 落盘量 / `CONTENT SIZE` 传输量；新 CLI 的 `ID` 是**镜像配置 ID**，不是层 ID |
| 找占用最大的层 | `docker history webapp:v1` | 每条指令一行，`CREATED BY` 对应指令；`<missing>` 表示该中间层无独立 image ID，**不是错误** |
| 数层数 | `docker history webapp:v1 \| wc -l` | v1 = 17（基础镜像 10 + 自己 7） |
| 看产物真实大小 | `docker run --rm webapp:v1 ls -lh /home/test/webapp` | 7.7M，仅占那 91.8MB 层的 8% |
| 看构建缓存多大 | `docker run --rm webapp:v1 du -sh /root/.cache/go-build` | 82.4M；算式相符：7.7 + 82.4 ≈ 90.1 ≈ 91.8 MB |
| 判断静态 / 动态链接 | `docker run --rm --entrypoint sh webapp:v1 -c 'ldd /home/test/webapp'` | musl：`Not a valid dynamic program` = **静态**（exit 1 是 ldd 的报错方式）；列出 `xxx.so => /path` = 动态 |
| 覆盖入口命令进入镜像排查 | `docker run --rm --entrypoint sh webapp:v1 -c 'ls /usr/local/go'` | `--entrypoint` 覆盖 `ENTRYPOINT`；镜像内**必须真有 sh** 才可用 |
| 容器内看监听端口 | `docker exec web2 netstat -tlnp` | `:::8080 LISTEN 1/webapp` —— 8080 是**容器内**端口；PID 1 = 应用本身 ；⚠️ 精简镜像可能没有 `netstat` |
| 从宿主侧看端口映射 | `docker port web3` | 不需要进入容器，**`scratch` 也可用** |
| 看完整 CMD（不截断） | `docker inspect -f '{{json .Config.Cmd}}' web2` | `docker ps` 的 `COMMAND` 列是截断显示 |
| 使用非默认文件名的 Dockerfile | `docker build -f Dockerfile.scratch -t webapp:v3 .` | `-f` 指定文件名；默认只找 `Dockerfile` |
| 看运行中容器的资源占用 | `docker stats [容器]` | 底层读取 **cgroup 统计**；`CPU %` / `MEM USAGE` / `PIDS` 为**瞬时**，`NET I/O` / `BLOCK I/O` 为**自启动累计**；脚本中用 `--no-stream` 取一次 |

---

## 4. 实测数据（原始输出）

### 4.1 三版体积对照

| 版本 | 写法 | DISK USAGE | CONTENT SIZE | 层数 | 相对 v1 |
|---|---|---|---|---|---|
| v1 | 单阶段 `golang:1.25.1-alpine` | **449MB** | 88.9MB | 17 | 基线 |
| v2 | 多阶段，runtime = `alpine:3.22` | **25.3MB** | 8.3MB | 6 | **−94.4% / −90.7%** |
| v3 | 多阶段，runtime = `scratch` | **12.6MB** | 4.51MB | 4 | **−97.2% / −94.9%** |

> 验收线（见 `code/week1/day3/README.md`）：**< 50MB** —— v2 / v3 均通过。

### 4.2 `DISK USAGE` 的构成（据三个数字反推，算式相符）

| 版本 | 解压后的层合计 | + 压缩后的 blob | ≈ DISK USAGE |
|---|---|---|---|
| v1 | ≈360MB | 88.9MB | **448.9 ≈ 449** ✅ |
| v2 | ≈17MB（alpine 8.98 + 产物 7.67） | 8.3MB | 25.3 ✅ |
| v3 | 7.67MB（仅产物） | 4.51MB | **12.18 ≈ 12.6** ✅ |

→ 结论：Docker v28+ 使用 containerd 镜像存储时，**解压后的快照与压缩后的 blob 会在本地各留一份**，因此 `DISK USAGE ≈ 解压总量 + 传输体积`（约等于 `CONTENT SIZE` 的 3 倍）。✍️ 这是根据本机输出反推的，不同 Docker 版本可能不同；**比较只用同一列**。

### 4.3 v1 的体积构成（需要去掉的就是这三层，合计 79%）

| 层（CREATED BY） | 大小 | 来源 | 运行期是否需要 |
|---|---|---|---|
| `COPY /target/ /` | **254MB** | 非自己编写：`golang` 官方镜像在构建时把 Go 工具链复制进 `/usr/local/go` | ❌ 纯编译期资产（编译器 / 链接器 / 预编译标准库源码） |
| `RUN /bin/sh -c go build -o webapp ./main.go` | **91.8MB** | Day 2 自己写的 `RUN` | ⚠️ 其中 98% 是无用中间产物：真产物仅 7.7MB，**82.4MB 是 GOCACHE**（`/root/.cache/go-build`），另有约 1.7MB `/tmp` 中间文件 |
| `ADD alpine-minirootfs-3.22.1-x86_64.tar.gz /` | **8.98MB** | alpine 最小根文件系统 | 🔶 静态二进制**不需要**；但它决定"能否排障 / 能否发 HTTPS / 时区是否正确" |

### 4.4 踩坑记录

| 现象 | 判断过程 | 解法 |
|---|---|---|
| `docker images` 显示 449MB，而 Day 2 记录为 ≈360MB，看似矛盾 | 输出多了 `DISK USAGE` / `CONTENT SIZE` 两列 | 新 CLI 提供**两个尺度**（落盘 vs 压缩传输）；只记"两个尺度不同"，不必背数字 |
| `docker run --rm --entrypoint sh ... -c 'ldd ...'` 返回**退出码 1**，误以为命令写错 | 输出为 `/lib/ld-musl-x86_64.so.1: /home/test/webapp: Not a valid dynamic program` | musl 版 `ldd` 对**静态**文件就是这个表现，exit 1 是它的报错语义 → 恰好证明是静态二进制 |
| `RUN go build -o /out/webapp`，但 `/out` 从未创建 | build 却**成功** | 新版 Go 会**自动创建 `-o` 的父目录**，无需 `RUN mkdir -p /out` |
| `docker run -p 8082:8081 webapp:v3`，`curl localhost:8082` 报 `Recv failure: Connection reset by peer` | 对照 v2 是通的 → 网络/DNAT 无问题；`docker exec web2 netstat -tlnp` 显示 `:::8080 LISTEN 1/webapp` → 应用监听 **8080** | `-p` 的**右侧**必须等于应用真正 listen 的端口：`-p 8082:8080`；`EXPOSE` 与发布端口无关 |
| 把 `curl (56) Recv failure` 当成"容器没起来 / 网络不通" | 三种 curl 失败的机制不同 | **56** = 包已到容器但该端口无人监听（查端口号）；**7** = 包未离开宿主（查 `-p`）；**28** = 包被静默丢弃（查防火墙 / 路由） |
| `scratch` 容器执行 `docker exec -it web3 sh` | 镜像里**根本没有** `/bin/sh` | 只能从容器外排查：`docker logs` / `docker port` / `docker inspect` |

---

## 5. 易错点

| 错法 | 现象 | 正确做法 |
|---|---|---|
| 把 overlay2 当成**构建缓存失效**的原因 | 结论对（改代码 → 后续全重建），但归因错误，换场景就推不出正确结论 | 构建缓存 = builder 逐层计算 **cache key**（父层 key + 指令字符串 + **输入内容哈希**）的链式比对，与 overlay2 无关；overlay2 管的是**运行期**只读镜像层 + 可写层的联合挂载。**这是同一类错误的第 2 次** |
| 认为"Dockerfile 里没写的东西不会进镜像" | `RUN go build` 顺带写下的 82.4MB GOCACHE 全部进入了该层 | 规则是"指令执行后留在文件系统里的所有改动 = 一层"；解法是让中间产物产生在**另一个阶段** |
| 把 Go 的静态链接等同为"C++ 那样要加开关" | 概念混淆 | C/C++ **默认动态**链接（依赖 libstdc++/libc，需 `-static` 才静态）；**Go 默认静态**。需要关心的是"如何**保证**静态" → 显式 `CGO_ENABLED=0` |
| 认为 v1 的二进制是静态"因为我写对了" | 实际是巧合：`golang:alpine` 没有 gcc，cgo 不可用 | 显式 `CGO_ENABLED=0`，把"恰好能跑"变为"保证能跑" |
| 用 `docker images` 的单个数字做跨天比较 | 449MB 与昨天的 ≈360MB 看似矛盾 | 认清存在两个**尺度**；跨天比较必须看同一列 |
| 用 `ldd` 的退出码 1 判断"命令写错了" | musl 的 ldd 对静态文件报 `Not a valid dynamic program` 并 exit 1 | exit 1 是 ldd 的报错语义，恰好证明是静态二进制 |
| 把 `-p` 右侧填成 `EXPOSE` 的值，或左右写反 | `curl` 报 `(56) Connection reset by peer`，但容器状态是 Up | `-p 宿主:容器`，**右侧 = 应用真正 listen 的端口**，与 `EXPOSE` 无关 |
| 把三种 `curl` 失败都当成"网络不通" | 排查方向全部错误 | **7** = 宿主无人监听（查 `-p`）；**56** = 已到容器但端口无人监听（查端口号）；**28** = 包被丢弃（查防火墙 / 路由） |
| 认为多阶段构建是"把 builder 阶段删掉" | 说不清 builder 的内容去哪了 | 是**隔离**：builder 的文件在它自己的文件系统里，最终镜像的层**不含**它们；`COPY --from` 是唯一通道 |
| 认为 `scratch` 只是"体积小一点" | 上线后才发现进不去容器、HTTPS 报证书错误 | `scratch` 的代价是**可运维性归零**：无 shell、无 CA、无 `passwd`/时区。生产常用 `distroless` / `alpine` |

---

## 6. 每日一题（面试自测）

### 6.1 容器题：查看层大小 / 查看资源占用 / `scratch` 如何排障

**我的原答**：① `docker history <镜像>` 读 `SIZE` 列 ✅ ② 未答 ③ `scratch` 无 shell → `ps`/`du`/`netstat` 均不可用 ✅；补救只想到 `docker logs`

**批改**

| # | 判定 | 要点 |
|---|---|---|
| ① | ✅ 正确 | 补充：输出**从新到旧**（最上面是最新层）；`<missing>` 不是错误；要看完整指令加 `--no-trunc`；占用最大的层按 `SIZE` 列排序（v1：254M / 91.8M / 8.98M） |
| ② | ❌ 未答 | **`docker stats [容器]`**（底层读取 **cgroup 统计**）。⚠️ **瞬时与累计要分清**：`CPU %`、`MEM USAGE/LIMIT`、`PIDS` 为**瞬时**；`NET I/O`、`BLOCK I/O` 为**自容器启动累计**。脚本中加 `--no-stream` 只取一次 |
| ③ | 🔶 对一半 | 现象正确（`docker exec` 报 `exec: "sh": executable file not found in $PATH`）；补救思路只给出一条，见下表 |

**③ 四个层次的补救方案（从零成本到需要改镜像）**

| 思路 | 做法 | 特点 |
|---|---|---|
| 1. 容器外排查（**优先考虑**） | `docker logs` / `inspect`（`State.ExitCode`）/ `stats` / `top` / `port` / **`docker diff web3`**（看可写层改了什么）/ `docker cp web3:/app/webapp ./` | **完全不依赖镜像内容**，`scratch` 也可用 |
| 2. 临时调试容器共享命名空间 | `docker run -it --rm --pid=container:web3 --network=container:web3 alpine:3.22 sh` | K8s 中对应 `kubectl debug --image=...` |
| 3. 使用带调试工具的镜像变体 | `distroless` 的 `-debug` 标签（自带 busybox）；或在多阶段中加一个 `AS debug` 阶段 | 长期可维护 |
| 4. 把**静态** busybox 复制进镜像 | 阶段 2 加 `COPY --from=busybox:1.36 /bin/busybox /bin/busybox`，再 `docker exec web3 /bin/busybox sh` | 用约 1MB 换回一个 shell |

### 6.2 Linux 题：`find` 复合条件

**题目**：在 `/data` 下找出**普通文件** + 名字以 `.tar.gz` 结尾 + **修改超过 30 天** + **大于 50MB**。① 先只打印结果不删；② 确认后再删。并说明：为什么 `-name` 的参数要加引号、而路径里不能带通配符？

**我的原答**

```bash
find "/data" -type f -name "*.tar.gz" -mtime +30 -size +50M
```

**批改：结构全对，但第 ② 问与两个"为什么"均未作答**

**四个必须知道的点（按危险程度排序）**

| 点 | 真相 |
|---|---|
| `-mtime +30` **不是**"30 天前" | `-mtime` 以 **24 小时整数周期**计数，**小数部分直接丢弃**（`find` 文档原文）→ `+30` 表示"数出来 >30 个整天"，即文件至少 **31 天前**修改。要精确到分钟用 `-mmin +43200`（30×24×60） |
| `-size +50M` 的 `M` **不是精确字节** | 单位：`c` = 字节、`w` = 2 字节、`b` = 512 字节块、`k` = KiB、`M` = MiB；且比较前会**向上取整**（1 字节的文件用 `-size 1M` 也能匹配）。要精确：`-size +52428800c` |
| 删除需要额外一条 | `-delete`（**隐含 `-depth`**，必须放在**最后**）或 `-exec rm -v {} +`（可留日志）；`-exec rm {} \;` 是每个文件启动一次 `rm`，较慢 |
| `-type f` **不匹配符号链接** | 默认 `-P`（不跟随）；需要跟随时用 `find -L`（此时要防目录环，配合 `-maxdepth`） |

**标准两条命令**

| 步骤 | 命令 |
|---|---|
| ① 先查看 | `find /data -type f -name '*.tar.gz' -mtime +30 -size +50M -print`（`-print` 是默认动作，显式写出更易读；加 `-ls` 可看大小与时间） |
| ① 附：先计数 | 上述命令 + ` \| wc -l` —— 删除前先确认影响多少个文件 |
| ② 再删除 | `find /data -type f -name '*.tar.gz' -mtime +30 -size +50M -delete`（或 `-exec rm -v {} +`） |

**两个"为什么"**

| 问题 | 答案 |
|---|---|
| 为什么 `-name` 的参数要**加引号** | 不加引号时 **shell 会抢在 find 之前做 glob 展开**：① 当前目录**恰好有**匹配文件 → 文件名列表被塞进命令行，find 收到多余参数，语义全错 ② 无匹配时 → **bash 原样传递（碰巧"正确"）**，**zsh 直接报 `no matches found`**。"有时对有时错"正是最危险的情形。加引号 = 让 shell 不做 glob，交给 find 自己的 **fnmatch** 匹配 |
| **路径**为什么不能带通配符 | `find /data/*.tar.gz` → shell 先展开，find 拿到的是一**组起始路径**（各自作为独立起点，不再递归筛选），且无匹配时命令根本无法启动。find 不会自行解释"路径模式"—— 要按路径筛选需用 `-path`（匹配**整条路径**）/ `-ipath` / `-regex`（配合 `-regextype`）。规则是：**路径只给起点目录，筛选交给 `-name`/`-path`** |

---

## 7. 遗留疑问

| # | 问题 | 解答 / 状态 |
|---|---|---|
| 1 | Go 如何构建？不像 C++ 那样链接 `.so`，为什么产物能单独运行 | 编译期把 runtime（调度器 + GC）+ 标准库 + 代码复制进产物 → 静态 ELF；工具链只在编译那一刻需要 |
| 2 | 91.8MB 那层扣除 7.7MB 二进制后剩下什么 | **GOCACHE 82.4MB**（`/root/.cache/go-build`）+ 约 1.7MB `/tmp` 中间产物；已实测相符 |
| 3 | alpine 根文件系统（8.98MB）运行期是否需要 | 静态二进制**不需要**；但 `sh` / `ca-certificates` / `tzdata` / `/etc/passwd` 决定"能否排障、能否发 HTTPS、时区是否正确"—— 这正是 `scratch` 的取舍点 |
| 4 | `scratch` 版发 HTTPS 会怎样 | HTTP 已验证：`curl localhost:8082` → `<h1>Hello DevOps</h1>`。HTTPS **未测**：预计报 `x509: certificate signed by unknown authority`（镜像内无 CA 证书），补救 = 从 builder `COPY --from` `/etc/ssl/certs/ca-certificates.crt`，或改用 `distroless` |

---

## 附：面试要点与薄弱点

**5 条可直接讲的结论**

1. **隔离 ≠ 删除**：builder 的内容进不了最终镜像，是因为最终镜像的层**不含**它；`COPY --from` 是唯一通道。
2. **"指令执行后留在文件系统里的改动 = 一层"** —— Docker 不区分产物与中间产物，这是"镜像变胖"的第一性原理，也是多阶段构建存在的理由。
3. **静态 vs 动态 = 能否使用 `scratch` 的开关**：`CGO_ENABLED=0` 把"偶然"变为"保证"；判断用 `ldd`（musl 报 `Not a valid dynamic program`，**exit 1 不是错误**）。
4. **构建缓存是 cache key 链（内容寻址），不是 overlay2**。
5. **"能跑 ≠ 好用"**：`scratch` 省下的 12.7MB，代价是 shell / CA 证书 / 时区 / `passwd` 全部缺失。

**薄弱点（需持续注意）**

| 薄弱点 | 状态 |
|---|---|
| 构建期与运行期混淆（overlay2 / cache key） | 已订正。这是同类错误的**第 2 次**；遇到"为什么缓存失效 / 为什么数据没了"先问：**这是哪个阶段的事？** |
| `docker stats` 是"资源占用"的标准答案 | 已补（cgroup 统计；瞬时与累计要分清） |
| "加引号""路径不能带通配符"只答命令、未答原理 | 已补 —— `find` 类题目的区分点在机制 |
| 容易在"子命令里写 shell 语法" | 已在 exec form / `ldd` / `-p` 三个场景各遇到一次，规律是：先确认**这句话是谁在解释**（shell？Docker？find？） |

**待办**：HTTPS 出站实验（选做）：加 `COPY --from=builder /etc/ssl/certs/ca-certificates.crt ...` 前后各跑一次对比。
