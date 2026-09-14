# Day 3 学习笔记 · 多阶段构建：把镜像压小

> 日期：2026-09-13
> 对应模块：`docs/k8s_in_action/01-容器与K8s入门.md`（Dockerfile 与镜像分层）
> 参考：`docs/docker/04-Dockerfile词典.md` §六（多阶段构建）
> 代码目录：`code/week1/day3/`
> 模板：概念 / 命令 / 易错点 / 我的疑问

---

## 今日任务清单

| # | 任务 | 完成 |
|---|---|---|
| 1 | **立基线**：`docker images webapp` 记下 v1 体积；`docker history webapp:v1` 找出体积前三的层 | ✅ DISK USAGE 449MB / CONTENT SIZE 88.9MB；前三层 = 254M + 91.8M + 8.98M |
| 2 | 读机制：多阶段构建为什么能让 builder 阶段不进最终镜像 + **量出产物真实大小与链接方式** | ✅ 二进制 7.7M（只占那层 8%）、GOCACHE 82.4M、**静态链接** |
| 3 | **自己写多阶段 `Dockerfile`**（先写完再对照）→ `docker build -t webapp:v2 .` | ✅ 阶段1 原样搬运（只加 `AS builder`）；阶段2 = `alpine:3.22` + `WORKDIR /app` + `COPY --from` + `CMD ["./webapp"]` |
| 4 | `docker images` 对比 v1 / v2；`docker history webapp:v2` 数层数 | ✅ v2 = 25.3MB / 8.3MB / 6 层；v3 = 12.6MB / 4.51MB / 4 层 |
| 5 | `docker run -d --name web2 -p 8081:8080 webapp:v2` + `curl localhost:8081` | ✅ `<h1>Hello DevOps</h1>` |
| 6 | 冲极限：运行阶段换 `scratch` 或 `distroless`，记录踩到的坑 | ✅ `Dockerfile.scratch` 构建成功、容器能跑；踩坑：`-p` 端口写错一次 |
| 7 | 把前后对比写进本笔记的「实测记录」 | ✅ |

---

## 实测记录（收尾时填）

> ⚠️ 体积有**两个尺度**：`DISK USAGE` = 本地解压落盘（各层累加）；`CONTENT SIZE` = 压缩后、真正要传输的体积。差 5 倍是正常的。**比较只用同一个尺度**（Day 2 记的 ≈360MB 是按 `history` 几层相加，和 449MB 不矛盾）。

| 版本 | 写法 | DISK USAGE | CONTENT SIZE | 层数 | 相对 v1（DISK/CONTENT） |
|---|---|---|---|---|---|
| v1 | 单阶段 `golang:1.25.1-alpine` | **449MB** | 88.9MB | 17 | 基线 |
| v2 | 多阶段，runtime = `alpine:3.22` | **25.3MB** | 8.3MB | 6 | **−94.4% / −90.7%** |
| v3 | 多阶段，runtime = `scratch` | **12.6MB** | 4.51MB | 4 | **−97.2% / −94.9%** |

> 验收线（`code/week1/day3/README.md`）：**< 50MB** —— v2/v3 都过。

**`DISK USAGE` 到底怎么算的（✍️ 我用三个数字反推，算式闭合）**

| 版本 | 解压后的层合计 | + 压缩后的 blob | ≈ DISK USAGE |
|---|---|---|---|
| v1 | ≈360MB | 88.9MB | **448.9 ≈ 449** ✅ |
| v2 | ≈17MB（alpine 8.98 + 产物 7.67） | 8.3MB | 25.3 ✅ |
| v3 | 7.67MB（只有产物） | 4.51MB | **12.18 ≈ 12.6** ✅ |

→ 结论：Docker v28+ 用 containerd 镜像存储时，**解压后的快照和压缩后的 blob 会在本地各留一份**，所以 `DISK USAGE ≈ 解压总量 + 传输体积`（约等于 `CONTENT SIZE` 的 3 倍）。⚠️ 这是我根据你的输出反推的，不同 Docker 版本可能不同；**比较只比同一列**。

**v1 体积构成（要砍的就是这三层，占 79%）**

| 层（CREATED BY） | 大小 | 谁带进来的 | 运行期需要吗 |
|---|---|---|---|
| `COPY /target/ /` | **254MB** | 不是自己写的 —— `golang` 官方镜像构建时把 Go 工具链拷进 `/usr/local/go` | ❌ 纯编译期资产（编译器/链接器/预编译标准库源码） |
| `RUN /bin/sh -c go build -o webapp ./main.go` | **91.8MB** | 自己 Day 2 的 `RUN` | ⚠️ 98% 是垃圾：真产物只 7.7MB，**82.4MB 是 GOCACHE**（`/root/.cache/go-build`）+ ≈1.7MB `/tmp` 中间文件 |
| `ADD alpine-minirootfs-3.22.1-x86_64.tar.gz /` | **8.98MB** | alpine 最小根文件系统 | 🔶 静态二进制**不需要**；但决定「能不能排障 / 能不能发 HTTPS / 时区对不对」 |

**踩坑记录：**

| 现象 | 我怎么判断的 | 解法 |
|---|---|---|
| `docker images` 显示 449MB，但 Day 2 笔记记的是 ≈360MB，看着像矛盾 | 输出多了 `DISK USAGE` / `CONTENT SIZE` 两列 | 新 CLI（v28+）给了**两个尺度**：落盘 vs 压缩传输；前者含共享层摊分。只记「两个尺度不同」，不背数字 |
| `docker run --rm --entrypoint sh ... -c 'ldd ...'` 返回**退出码 1**，以为命令写错 | 输出是 `/lib/ld-musl-x86_64.so.1: /home/test/webapp: Not a valid dynamic program` | musl 版 `ldd` 对**静态**文件就这表现，exit 1 是它的报错语义 —— 恰恰证明是静态二进制 |
| `RUN go build -o /out/webapp`，可 `/out` 从没建过 | build **居然成功了** | 新版 Go 会**自动创建 `-o` 的父目录**，不用 `RUN mkdir -p /out` |
| `docker run -p 8082:8081 webapp:v3`，`curl localhost:8082` 报 `Recv failure: Connection reset by peer` | 对比 v2 是通的 → 网络/DNAT 没问题；`docker exec web2 netstat -tlnp` 看到 `:::8080 LISTEN 1/webapp` → 应用听的是 **8080** | `-p` 的**右**边必须等于应用真正 listen 的端口：`-p 8082:8080`。`EXPOSE` 跟发布端口无关 |
| 以为 `curl (56) Recv failure` 是「容器没起来 / 网络不通」 | 三种 curl 失败的机制不同（见「命令」表） | 56 = 包到了容器但该端口没人听 → 查**端口号**；7 = 包没离开宿主 → 查 `-p`；28 = 包被静默丢弃 → 查防火墙/路由 |
| `scratch` 容器想 `docker exec -it web3 sh` 进去 | 镜像里**根本没有** `/bin/sh` | 只能从容器外排障：`docker logs` / `docker port` / `docker inspect`；生产上用 `distroless`/`alpine` 换回可运维性 |

---

## 抽背回执（Day 2 的坑 · 2026-09-13）

| # | 题 | 判定 | 要点 |
|---|---|---|---|
| 1 | `CMD ["./webapp", ">>", "x.log", "2>&1", "&"]` 实际执行什么 | ✅ 对 | exec form **不经 shell** → JSON 数组里**每个元素 = 一个 argv 元素**（不是"引号数"）；`./webapp` 收到 4 个参数 `>>`、`x.log`、`2>&1`、`&`。日志走 stdout（被 Docker 收走）→ 只能 `docker logs` 看；既没重定向也没后台 |
| 2 | `docker top web` 的 PID 是谁 | ✅ 对 | 那是**宿主 PID**。容器视角的 PID 1 用 `docker exec web ps aux`；宿主侧对应 PID 用 `docker inspect -f '{{.State.Pid}}' web`。⚠️ 前提：镜像里**得有 `ps`** —— 今天换 `scratch` 后 `exec` 会直接失败 |
| 3 | 改 `main.go` 后 `CACHED` 断在哪 | ✅ 结论对，机制要订正 | 断点 = `COPY ./main.go` 那一层，它及其后（`tidy`/`build`）全部重建；之前的 `COPY ./go.mod` 仍 CACHED。**机制订正**：build cache 是 builder 逐层算 **cache key**（父层 key + 指令字符串 + 输入内容哈希）比出来的，**跟 overlay2 无关**。overlay2 管的是**运行时**容器可写层与镜像层的联合挂载；分层缓存是"内容寻址"。两件事别混成一件 |
| 4 | 终端断开时发什么信号、`nohup` 干了什么 | ⚠️ 半对 | 信号对：**SIGHUP(1)**（根本不存在 NOHUP 这个信号）。重定向说反了：stdout 是终端时 → 重定向到 **`nohup.out`**（不是 stderr），同时 **stderr 合并进同一文件**，stdin 接 `/dev/null`；stdout 已重定向时则不动 stderr |

> 结论：4 题里 3 题站得住，**唯一系统性问题是「把运行时机制（overlay2）套到构建期行为（cache key）上」**，以及信号/重定向细节记串。今天做多阶段构建时，注意区分「构建期发生的事」和「运行期发生的事」。

---

## 每日一题（先自己写答案 → 再找人批改）

### 容器题 · 命令题

① 一条命令看「镜像每层多大」？
② 一条命令看「运行中容器的资源占用」？
③ `scratch` 镜像里**没有 shell**，这对排障意味着什么、怎么补救？

**我的答案：**

① `docker history <镜像>`，读 `SIZE` 列 ✅
② （未答）
③ `scratch` 没 shell → `ps`/`du`/`netstat` 等全用不了 ✅；补救：`docker logs` 能用，其他不清楚

**批改：**

| # | 判定 | 要点 |
|---|---|---|
| ① | ✅ 对 | 补充：输出**从新到旧**（最上面 = 最新层）；`<missing>` 不是错误；要看**完整指令**加 `--no-trunc`；体积大户就是 `SIZE` 列排序（v1：254M / 91.8M / 8.98M） |
| ② | ❌ 未答 | **`docker stats [容器]`**（底层就是读 **cgroup 账本**，Day 1 讲的 cgroup 限制在这里可视化了）。⚠️ **瞬时 vs 累计要分清**：`CPU %`（两次采样区间的占比）、`MEM USAGE/LIMIT`、`PIDS` = **瞬时**；`NET I/O`、`BLOCK I/O` = 自容器启动**累计**。脚本里用 `--no-stream` 只取一次 |
| ③ | 🔶 对一半 | 现象对（`docker exec` 报 `exec: "sh": executable file not found in $PATH`）；补救思路只给了一条，见下表 |

**③ 补救四个层次（从零成本到要改镜像）**

| 思路 | 做法 | 特点 |
|---|---|---|
| 1. 容器外排障（**先想这个**） | `docker logs` / `inspect`（`State.ExitCode`）/ `stats` / `top` / `port` / **`docker diff web3`**（看可写层改了什么）/ `docker cp web3:/app/webapp ./` | **完全不依赖镜像内容**，scratch 也能用 |
| 2. 临时调试容器共享命名空间 | `docker run -it --rm --pid=container:web3 --network=container:web3 alpine:3.22 sh` | K8s 里对应 `kubectl debug --image=...` |
| 3. 用带调试工具的变体镜像 | `distroless` 的 `-debug` 标签（自带 busybox）；或自己多阶段里加一个 `AS debug` 阶段 | 长期可维护 |
| 4. 把**静态** busybox 塞进镜像 | 阶段 2 加 `COPY --from=busybox:1.36 /bin/busybox /bin/busybox`，然后 `docker exec web3 /bin/busybox sh` | 用 ~1MB 换回一个 shell |

### Linux 题 · Day 3 命令（find）

在 `/data` 下找出：**普通文件** + 名字以 `.tar.gz` 结尾 + **修改超过 30 天** + **大于 50MB**。
① 先只打印结果不删；② 确认后再删。并说明：为什么 `-name` 的参数要**加引号**、而**路径**里不能带通配符？

**我的答案：**

```bash
find "/data" -type f -name "*.tar.gz" -mtime +30 -size +50M
```

**批改：结构全对 ✅，但题目第 ② 问和两个「为什么」都没答。**

| 项 | 判定 |
|---|---|
| `-type f` / `-name` / `-mtime +30` / `-size +50M` 结构 | ✅ 选项全对 |
| ② 「确认后再删」 | ❌ 没答 |
| 两个「为什么」 | ❌ 没答 |

**四个必须知道的坑（按危险度排）**

| 坑 | 真相 |
|---|---|
| `-mtime +30` **不是**「30 天前」 | `-mtime` 以 **24 小时整数周期**计数，**小数直接丢弃**（`find` 自己文档原话）；所以 `+30` = 数出来 >30 个整天 = 文件至少 **31 天前**修改。要精确到分钟用 `-mmin +43200`（30×24×60） |
| `-size +50M` 的 `M` **不是精确字节** | `c`=字节, `w`=2字节, `b`=512字节块, `k`=KiB, `M`=MiB；而且单位是**向上取整**后比较（1 字节的文件用 `-size 1M` 也能匹配）。要精确：`-size +52428800c` |
| 删除要额外一条 | `-delete`（**隐含 `-depth`**，必须放**最后**）或 `-exec rm -v {} +`（可留日志）；`-exec rm {} \;` 是每个文件起一次 `rm`，慢 |
| `-type f` **不匹配符号链接** | 默认 `-P`（不跟随）；要跟随用 `find -L`（此时要防目录环，配 `-maxdepth`） |

**标准两条命令**

| 步骤 | 命令 | 说明 |
|---|---|---|
| ① 先看 | `find /data -type f -name '*.tar.gz' -mtime +30 -size +50M -print` | `-print` 其实是默认动作，显式写更好读；再加 `-ls` 可看大小/时间 |
| ① 附：先数数 | 同上命令 + ` \| wc -l` | 删之前先知道会影响几个文件 |
| ② 再删 | `find /data -type f -name '*.tar.gz' -mtime +30 -size +50M -delete` | 或 `-exec rm -v {} +` |

**两个「为什么」的答案**

| 问题 | 答案 |
|---|---|
| 为什么 `-name` 的参数要**加引号** | 不加引号时 **shell 抢在 find 前面做 glob 展开**：① 当前目录**恰好有**匹配文件 → 文件名列表被塞进命令行，find 收到一堆多余参数（甚至语义全错）② 无匹配 → **bash 原样传过去（碰巧「对」）**，**zsh 直接报 `no matches found`**。「有时对有时错」正是最危险的。加引号 = 让 shell 不做 glob，交给 find 自己的 **fnmatch** 去匹配 |
| **路径**为什么不能带通配符 | `find /data/*.tar.gz` → shell 先展开，find 拿到的是**一组起始路径**（每个当独立起点，不再递归筛），且无匹配时命令根本跑不起来。find 不会自己猜「路径模式」—— 要按路径筛用 `-path`（匹配**整条路径**）/`-ipath`/`-regex`（配 `-regextype`）。所以规矩是：**路径只给起点目录，筛选交给 `-name`/`-path`** |

---

## 概念

> 学完填：多阶段构建是什么、builder 为什么不进最终镜像、scratch 的前提是什么。

| 要点 | 用自己的话写一遍 |
|---|---|
| 多阶段构建 = ？ | 一个 Dockerfile 里写**多个 `FROM`**，每个 `FROM` 起一个**独立阶段**（可用 `AS 名字` 命名）。每个阶段有**自己的文件系统**，阶段之间只能靠 `COPY --from=<阶段>` **单向搬文件**；**只有最后一个阶段的结果成为最终镜像** |
| 为什么 builder 阶段不进最终镜像 | 镜像是「层」拼的，而层**只由被采纳的指令**产生。builder 那边写的 254MB 工具链 + 82.4MB GOCACHE 全在 **builder 自己的文件系统**里；最终镜像从 runtime 阶段开始算层 —— 不用 `COPY --from` 显式搬，那边的东西**根本进不来**。机制是**隔离**，不是「删掉」 |
| `COPY --from=builder` 做了什么 | 从**另一个阶段**（而不是构建上下文）取文件，拷进当前阶段。源路径是**相对那个阶段根文件系统**的路径 → 写绝对路径（`/out/app`）最稳 |
| 为什么二进制能跑在 `scratch` 里（前提） | Go 二进制默认**静态链接**：runtime（调度器+GC）+ 标准库 + 你的代码全在一个 ELF 里，运行时不找 `.so`、不找动态链接器。前提 = **必须真静态**（显式 `CGO_ENABLED=0`） |
| `CGO_ENABLED=0` 管什么 | 关掉 cgo → 不调 C 编译器、不链接 libc/musl → 产出纯静态 ELF。⚠️ v1 恰好是静态的，原因只是 `golang:alpine` 里**没有 gcc**（cgo 不可用）—— 这是**环境巧合**；一旦换带 gcc 的基础镜像或 `apk add gcc`，同一份代码就变动态链接 → `scratch` 里报 `exec /app: no such file or directory`。显式声明才是**契约** |
| 镜像变小的**三层收益** | ① 传输快（`CONTENT SIZE` 那个尺度：pull/push）② 攻击面小（没编译器、没包管理器、没 shell，逃逸后手里没工具）③ **K8s 场景的启动速度** —— 节点磁盘占用小 + 拉镜像快 → 滚动升级 / 扩容 / 故障重建都更快 |
| 「垃圾进镜像」的通用规律 | Docker **不区分**「我要的产物」和「过程中的缓存」，规则只有一条：**指令执行后留在文件系统里的所有改动 = 一层**。所以瘦身靠「让垃圾产生在别的阶段」，不是「事后删文件」 |
| v2 的 `/app` 里为什么只有一个文件 | builder 阶段的文件系统**根本不参与**最终镜像，`COPY --from` 是**唯一通道**。实测：v1 的 `/home/test` 里有 `main.go`/`go.mod`/`webapp`（源码跟着发货），v2 的 `/app` 只有 `webapp` |
| 「能跑 ≠ 好用」的量化 | v3（12.6MB）能跑 = 静态 ELF 不需要 libc/链接器；但**失去**：shell（exec 排障）、CA 证书（HTTPS 出站）、tzdata（本地时区）、`/etc/passwd`。v2 多出的 12.7MB 就是为这些付的钱 |
| `WORKDIR` 为什么不依赖 shell | 它只是**镜像配置字段**（OCI 配置里的 `process.cwd`），由容器运行时在 `execve` 前 `chdir`。所以 `scratch` 里 `WORKDIR /app` + `CMD ["./webapp"]` 照样成立 |
| `CGO_ENABLED=0` 这次为什么没改变体积 | v1/v2/v3 的二进制都是 **8037381 字节**（7.67MiB），一模一样 → 多阶段只改**打包方式**，不改**编译结果**；这个开关的价值是**可复现**（把「碰巧静态」变「保证静态」），不是减体积 |

## 命令

| 场景 | 命令 | 说明 |
|---|---|---|
| 看镜像体积（两个尺度） | `docker images webapp` | `DISK USAGE` 落盘 / `CONTENT SIZE` 压缩传输；新 CLI 的 `ID` 是**镜像配置 ID**，不是层 ID |
| 找体积大户 | `docker history webapp:v1` | 每条指令一行，`CREATED BY` 对应指令；`<missing>` 表示该中间层没独立 image ID，**不是错误** |
| 数层数 | `docker history webapp:v1 \| wc -l` | v1 = 17（基础镜像 10 + 自己 7） |
| 看产物真实大小 | `docker run --rm webapp:v1 ls -lh /home/test/webapp` | 7.7M —— 只占那 91.8MB 层的 8% |
| 看构建缓存多大 | `docker run --rm webapp:v1 du -sh /root/.cache/go-build` | 82.4M；算式闭合：$7.7+82.4=90.1 \approx 91.8$ MB |
| 判断二进制静态/动态 | `docker run --rm --entrypoint sh webapp:v1 -c 'ldd /home/test/webapp'` | musl：`Not a valid dynamic program` = **静态**（exit 1 是 ldd 的报错方式）；列出 `xxx.so => /path` = **动态** |
| 覆盖镜像入口命令（进镜像里排障） | `docker run --rm --entrypoint sh webapp:v1 -c 'ls /usr/local/go'` | `--entrypoint` 覆盖 `ENTRYPOINT`，`-c` 后是 shell 脚本；镜像里**必须真有 sh** 才可用 |
| 容器内看谁在监听端口 | `docker exec web2 netstat -tlnp` | `:::8080 LISTEN  1/webapp` —— `8080` 是**容器内**端口；`PID 1` = 应用本身（exec form 的功劳）。⚠️ 精简镜像可能没 `netstat` |
| 从宿主侧看端口映射 | `docker port web3` | 不需要进容器，**`scratch` 也能用** |
| 看容器内进程 | `docker exec web2 ps aux` | 需镜像里有 `ps`（alpine 自带 busybox ps；`scratch` 没有） |
| 看完整 CMD（不截断） | `docker inspect -f '{{json .Config.Cmd}}' web2` | `docker ps` 的 `COMMAND` 列是**截断**显示 |
| 非默认文件名的 Dockerfile | `docker build -f Dockerfile.scratch -t webapp:v3 .` | `-f` 指定文件名；默认只找 `Dockerfile` |

## 易错点

| 错法 | 现象 | 正确做法 |
|---|---|---|
| 把 overlay2 当成**构建缓存失效**的原因 | 结论对（改代码 → 后面全重建），但归因错，换个场景就推不出正确结论 | 构建缓存 = builder 逐层算 **cache key**（父层 key + 指令字符串 + **输入内容哈希**）的链式比对，**与 overlay2 无关**；overlay2 管的是**运行期**只读镜像层 + 顶层可写层的联合挂载 |
| 以为「Dockerfile 里没写的东西就不会进镜像」 | `RUN go build` 顺手写下的 82.4MB GOCACHE 全进了那一层 | 规则是「指令执行后**留在文件系统里的所有改动 = 一层**」；解法 = 让垃圾产生在别的阶段（多阶段构建） |
| 把 Go 的静态链接当成「跟 C++ 静态编译一样要加开关」 | 概念混淆 | C/C++ **默认动态**链接（依赖 libstdc++/libc，要 `-static` 才静态）；**Go 默认静态**（runtime+标准库+代码全打进一个 ELF）。要担心的反而是「怎么**保证**它是静态的」→ 显式 `CGO_ENABLED=0` |
| 认为 v1 的二进制是静态「因为我写对了」 | 实际是巧合：`golang:alpine` 没 gcc → cgo 不可用 | 显式 `CGO_ENABLED=0`，把「恰好能跑」变成「保证能跑」 |
| 拿 `docker images` 单个数字做跨天比较 | 449MB vs 昨天的 ≈360MB，看着矛盾 | 认清是两个**尺度**（落盘 vs 压缩传输）；跨天比较要看同一列 |
| 用 `ldd` 退出码 1 判断「命令写错了」 | musl ldd 对静态文件报 `Not a valid dynamic program` 并 exit 1 | exit 1 是 ldd 的报错语义，正好证明是静态二进制 |
| 把 `-p` 右边填成 `EXPOSE` 的值 / 写反 | `curl` 报 `(56) Connection reset by peer`，容器却明明 Up | `-p 宿主:容器`，**右边 = 应用真正 listen 的端口**，跟 `EXPOSE` 无关 |
| 三种 `curl` 失败都当成「网络不通」 | 排错方向全错 | **7** = 宿主没人监听（查 `-p`）；**56** = 到容器了但端口没人听（查端口号）；**28** = 包被丢（查防火墙/路由） |
| 以为多阶段是「把 builder 阶段删掉」 | 说不清 builder 的东西去哪了 | 是**隔离**：builder 的文件在它自己的文件系统里，最终镜像的层**不含**它们；`COPY --from` 是**唯一通道** |
| 以为 `scratch` 只是「体积小一点」 | 到线上才发现进不去容器、HTTPS 报证书错 | `scratch` 的代价是**可运维性归零**：无 shell、无 CA、无 `passwd`/时区。生产常用 `distroless`/`alpine` |

## 我的疑问

| # | 题目 | 考点 / 解答 |
|---|---|---|
| 1 | Go 到底怎么构建的？没有像 C++ 那样链接 `.so`，为什么产物能单独跑？ | 编译期把 **runtime（调度器+GC）+ 标准库 + 你的代码**复制进产物 → 静态 ELF。工具链只在**编译那一刻**需要 |
| 2 | 91.8MB 那层，扣掉 7.7MB 二进制剩下的是什么？ | **GOCACHE 82.4MB**（`/root/.cache/go-build`）+ ≈1.7MB `/tmp` 中间产物。已实测闭合 |
| 3 | alpine 根文件系统（8.98MB）运行期要吗？ | 静态二进制**不需要**；但 `sh`（排障）、`ca-certificates`（HTTPS 客户端）、`tzdata`、`/etc/passwd` 决定「**能跑 ≠ 好用**」。这就是 `scratch` 的取舍点 |
| 4 | `scratch` 版能正常 `curl` 吗？发 HTTPS 会怎样？ | ✅ **HTTP 已验证**：`curl localhost:8082` → `<h1>Hello DevOps</h1>`。HTTPS **未测**（`scratch` 里没 CA 证书，预计报 `x509: certificate signed by unknown authority`；补救 = 从 builder `COPY --from` `/etc/ssl/certs/ca-certificates.crt`，或换 `distroless`） |

---

## 收尾 · 今日总结（2026-09-13）

**一句话**：多阶段构建不是「删东西」，而是**把编译期的东西隔离在另一个文件系统里** —— 两边的唯一通道是 `COPY --from`。

| 三个数字 | 值 |
|---|---|
| 镜像体积 | **449MB → 25.3MB → 12.6MB**（−97.2%） |
| 真产物 | **7.67MiB**（8037381 字节），三个版本**始终没变** |
| 被丢掉的 | 254MB 工具链 + 82.4MB GOCACHE + 8.98MB rootfs |

**今天真正学到的 5 条（面试能讲的）**

1. **隔离 ≠ 删除**：builder 的东西进不了最终镜像，是因为最终镜像的层**根本不含**它；`COPY --from` 是唯一通道。
2. **「指令执行后留在文件系统里的改动 = 一层」** —— Docker 不区分产物和垃圾，这是「镜像变胖」的第一性原理，也是多阶段构建存在的理由。
3. **静态 vs 动态 = 「能不能上 `scratch`」的开关**：`CGO_ENABLED=0` 把「碰巧」变「契约」；判断用 `ldd`（musl 报 `Not a valid dynamic program`，**exit 1 不是错误**）。
4. **构建缓存是 cache key 链（内容寻址），不是 overlay2**：父层 key + 指令字符串 + 输入内容哈希。
5. **「能跑 ≠ 好用」**：`scratch` 省下的 12.7MB，代价是 shell / CA 证书 / 时区 / `passwd` 全没。

**今天暴露的盲区（要盯）**

| 盲区 | 状态 |
|---|---|
| 构建期 vs 运行期混淆（overlay2 / cache key） | 已订正。**这是同一类错的第 2 次**；以后遇到「为什么缓存失效 / 为什么数据没了」先问一句：**这是哪个期的事？** |
| `docker stats`（「资源占用」的标准答案） | 已补（cgroup 账本；瞬时 vs 累计要分清） |
| 「加引号」「路径不能带通配符」只答了命令、没答原理 | 已补 —— `find` 类题目**机制才是区分点**，命令背下来不难 |
| 只会「在子命令里写 shell 语法」这类错法 | 已从 exec form / `ldd` / `-p` 三个场景各撞一次，规律：**先确认「这句话是谁在解释」**（shell？Docker？find？） |

**遗留 / 明天入口**

| 项 | 说明 |
|---|---|
| HTTPS 出站实验（选做） | 加 `COPY --from=builder /etc/ssl/certs/ca-certificates.crt ...` 前后各跑一次对比 |
| 明日 Day 4 | 数据与网络：可写层丢数据 → volume / bind mount；默认 bridge **不能**按名解析 → `mynet` 内嵌 DNS；`-p` 的 DNAT 三视角对齐 |
| 环境清理 | `docker rm -f web2 web3`（Day 4 会重建 `web2`，8081 端口要空出来）；镜像 `webapp:v2/v3` **先别删** |
