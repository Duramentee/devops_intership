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
| 3 | **自己写多阶段 `Dockerfile`**（先写完再对照）→ `docker build -t webapp:v2 .` | ⬜ |
| 4 | `docker images` 对比 v1 / v2；`docker history webapp:v2` 数层数 | ⬜ |
| 5 | `docker run -d --name web2 -p 8081:8080 webapp:v2` + `curl localhost:8081` | ⬜ |
| 6 | 冲极限：运行阶段换 `scratch` 或 `distroless`，记录踩到的坑 | ⬜ |
| 7 | 把前后对比写进本笔记的「实测记录」 | ⬜ |

---

## 实测记录（收尾时填）

> ⚠️ 体积有**两个尺度**：`DISK USAGE` = 本地解压落盘（各层累加）；`CONTENT SIZE` = 压缩后、真正要传输的体积。差 5 倍是正常的。**比较只用同一个尺度**（Day 2 记的 ≈360MB 是按 `history` 几层相加，和 449MB 不矛盾）。

| 版本 | 写法 | DISK USAGE | CONTENT SIZE | 层数 | 备注 |
|---|---|---|---|---|---|
| v1 | 单阶段 `golang:1.25.1-alpine` | **449MB** | 88.9MB | 17 | Day 2 基线（10 层基础镜像 + 7 层自己） |
| v2 | 多阶段（alpine 做 runtime） | | | | |
| v3 | 多阶段（scratch / distroless） | | | | |

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

### Linux 题 · Day 3 命令（find）

在 `/data` 下找出：**普通文件** + 名字以 `.tar.gz` 结尾 + **修改超过 30 天** + **大于 50MB**。
① 先只打印结果不删；② 确认后再删。并说明：为什么 `-name` 的参数要**加引号**、而**路径**里不能带通配符？

**我的答案：**

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

## 易错点

| 错法 | 现象 | 正确做法 |
|---|---|---|
| 把 overlay2 当成**构建缓存失效**的原因 | 结论对（改代码 → 后面全重建），但归因错，换个场景就推不出正确结论 | 构建缓存 = builder 逐层算 **cache key**（父层 key + 指令字符串 + **输入内容哈希**）的链式比对，**与 overlay2 无关**；overlay2 管的是**运行期**只读镜像层 + 顶层可写层的联合挂载 |
| 以为「Dockerfile 里没写的东西就不会进镜像」 | `RUN go build` 顺手写下的 82.4MB GOCACHE 全进了那一层 | 规则是「指令执行后**留在文件系统里的所有改动 = 一层**」；解法 = 让垃圾产生在别的阶段（多阶段构建） |
| 把 Go 的静态链接当成「跟 C++ 静态编译一样要加开关」 | 概念混淆 | C/C++ **默认动态**链接（依赖 libstdc++/libc，要 `-static` 才静态）；**Go 默认静态**（runtime+标准库+代码全打进一个 ELF）。要担心的反而是「怎么**保证**它是静态的」→ 显式 `CGO_ENABLED=0` |
| 认为 v1 的二进制是静态「因为我写对了」 | 实际是巧合：`golang:alpine` 没 gcc → cgo 不可用 | 显式 `CGO_ENABLED=0`，把「恰好能跑」变成「保证能跑」 |
| 拿 `docker images` 单个数字做跨天比较 | 449MB vs 昨天的 ≈360MB，看着矛盾 | 认清是两个**尺度**（落盘 vs 压缩传输）；跨天比较要看同一列 |
| 用 `ldd` 退出码 1 判断「命令写错了」 | musl ldd 对静态文件报 `Not a valid dynamic program` 并 exit 1 | exit 1 是 ldd 的报错语义，正好证明是静态二进制 |

## 我的疑问

| # | 题目 | 考点 / 解答 |
|---|---|---|
| 1 | Go 到底怎么构建的？没有像 C++ 那样链接 `.so`，为什么产物能单独跑？ | 编译期把 **runtime（调度器+GC）+ 标准库 + 你的代码**复制进产物 → 静态 ELF。工具链只在**编译那一刻**需要 |
| 2 | 91.8MB 那层，扣掉 7.7MB 二进制剩下的是什么？ | **GOCACHE 82.4MB**（`/root/.cache/go-build`）+ ≈1.7MB `/tmp` 中间产物。已实测闭合 |
| 3 | alpine 根文件系统（8.98MB）运行期要吗？ | 静态二进制**不需要**；但 `sh`（排障）、`ca-certificates`（HTTPS 客户端）、`tzdata`、`/etc/passwd` 决定「**能跑 ≠ 好用**」。这就是 `scratch` 的取舍点 |
| 4 | 待确认：`scratch` 版仍能正常 `curl` 吗？发 HTTPS 会怎样？ | 跑 v3 时验证（预告：HTTP 能通，HTTPS 会报证书错） |
