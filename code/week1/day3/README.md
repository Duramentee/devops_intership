# Day 3 · 多阶段构建：把镜像压小

> 目标：把 Day 2 那个 ≈360MB 的镜像压到 **10MB 量级**，并说清「builder 阶段为什么不会进最终镜像」。
> 配套：`plan/week1/任务明细.md` 的 Day 3 节 · `docs/docker/04-Dockerfile词典.md` §六（多阶段构建）
> 笔记落点：`notes/week1/day3.md`
> **基线**：Day 2 的 `webapp:v1` = 17 层 / ≈360MB（其中 254MB 是 Go 工具链、91.8MB 是构建缓存）

---

## 一、今日流程（照着走，不要跳步）

| 顺序 | 时段 | 做什么 | 产出 |
|---|---|---|---|
| 0 | 15 min | **开场抽背**（考 Day 2 的坑）：① `CMD ["./app", ">>", "log"]` 实际会发生什么 ② `docker top` 给的 PID 是容器内的 PID 1 吗 ③ 哪一层失效会导致后面全废 | 口述 |
| 1 | 20 min | **立基线**：`docker images` 记下 `webapp:v1` 体积 → `docker history webapp:v1` 找出体积前三的层 | 3 个数字 |
| 2 | 20 min | 读机制：多阶段 = 多个 `FROM` + `COPY --from` | 笔记草稿 |
| 3 | 60 min | **自己写多阶段 `Dockerfile`**（先写完，再看任何参考） | `Dockerfile` |
| 4 | 30 min | build → 对比 v1/v2 体积 → run + curl | 跑通的容器 |
| 5 | 20 min | 冲极限：运行阶段换 `scratch` / `distroless`，记录踩到的坑 | 踩坑记录 |
| 6 | 20 min | **Linux 每日一题**（`docs/linux/Linux-每日一题.md` 的 Day 3 题：find） | 答案 |
| 7 | 30 min | **容器每日一题**（见本文件第四节） | 答案 |
| 8 | 20 min | 收尾：结论写进 `notes/week1/day3.md`（概念 / 命令 / 易错点 / 我的疑问） | 笔记 |

> **铁律：先做后看。** 步骤 3 的 Dockerfile 必须自己写完再对照 —— 尤其是"两个阶段各自该放什么"，想清楚比抄对更值钱。

---

## 二、产出物清单（本目录）

| 文件 | 来源 / 说明 | 谁产出 |
|---|---|---|
| `main.go` | **从 Day 2 复制**：`cp ../day2/main.go ../day2/go.mod .` | 命令 |
| `Dockerfile` | **今天的主角：多阶段版 —— 自己写** | 你写 |
| `Dockerfile.single`（可选） | 把 Day 2 的单阶段版复制过来当对照物 | 你复制 |
| 镜像体积对照表 | v1 / v2 / v3(scratch) 各多少 MB，写进 `notes/week1/day3.md` | 你记 |

> ⚠️ 端口用 **8081**（`-p 8081:8080`），因为 Day 2 那个 `web` 容器可能还在占用 8080。或者先 `docker rm -f web`。

---

## 三、分步任务与验证

### 步骤 1 · 立基线（没有基线就没有对比）

| 场景 | 命令 | 要记下什么 |
|---|---|---|
| 看镜像体积 | `docker images webapp` | `webapp:v1` 的 SIZE |
| 看层构成 | `docker history webapp:v1` | 体积前三的层分别是谁、多大 |
| 看总层数 | `docker history webapp:v1 \| wc -l` | 层数（基线 = 17 行） |

> 这一步的结论直接决定了：**要砍掉哪两层，才能瘦下来**。

### 步骤 2 · 写多阶段 Dockerfile（先自己写！）

**只给骨架，内容你填。** 一份多阶段 Dockerfile 至少要让下面几个问题有答案：

| # | 必须回答的问题 | 你用了哪条指令 / 参数 |
|---|---|---|
| 1 | 两个阶段（builder / runtime）**各自**用什么基础镜像？为什么第二个可以这么小？ | |
| 2 | builder 阶段要 COPY 什么、跑什么？产物落在哪个路径？ | |
| 3 | **怎么把产物从 builder 捞到 runtime 阶段**？哪个指令、哪个参数？ | |
| 4 | 捞过来的产物路径写绝对路径还是相对路径？为什么？ | |
| 5 | runtime 阶段的 `CMD` 怎么写？（回忆 Day 2 的 exec form） | |
| 6 | 如果 runtime 用 `scratch`，编译时必须加哪个开关？**不加会怎样**？ | |
| 7 | `-ldflags "-s -w"` 是干什么的？（选做） | |

**两个方向的提示（不给答案）：**
- 问题 1 的答案藏在 Day 2 的 `docker history` 里 —— 那 254MB 的 `COPY /target/` 是谁带进来的？它**运行时**真的需要吗？
- 问题 3 的关键词是 `--from`，去 `docs/docker/04-Dockerfile词典.md` §二 查 `COPY` 那一行。

### 步骤 3 · 构建与对比

| 场景 | 命令 | 期望现象 |
|---|---|---|
| 构建 v2 | `docker build -t webapp:v2 .` | 注意输出里**出现了几个 `FROM` 阶段** |
| 对比体积 | `docker images webapp` | v2 应显著小于 v1 |
| 数层数 | `docker history webapp:v2 \| wc -l` | 层数应远少于 17 |
| 跑起来 | `docker run -d --name web2 -p 8081:8080 webapp:v2` | — |
| 验证 | `curl localhost:8081` | `<h1>Hello DevOps</h1>` |
| 看日志 | `docker logs web2` | 能看到启动日志 |

### 步骤 4 · 冲极限：`scratch` / `distroless`

| 方案 | 体积 | 代价 |
|---|---|---|
| `golang:alpine`（Day 2 单阶段） | ≈360MB | 把编译器也发货了 |
| `alpine`（多阶段 runtime） | ≈10~20MB | 有 `sh`，能进去排障 |
| `distroless` | 更小 | 没有 shell，但有证书/基础文件 |
| `scratch`（空镜像） | 最小（≈产物本身） | ⚠️ 什么都没有：**无 shell、无 CA 证书、无时区、无 libc** |

⚠️ **三个预警**（不告诉你解法，自己踩）：
1. 换 `scratch` 后容器可能直接起不来 —— 先看 `docker logs`，再想"二进制的运行依赖"。
2. 就算起来了，如果程序要发 HTTPS 请求，可能报证书错误 —— 想想 `scratch` 里缺什么。
3. `docker exec -it web2 sh` 会报 `no such file or directory` —— 这不是命令写错了，是镜像里**真没有 shell**。那怎么排障？先自己想，再看 `docs/docker/05-排障索引.md` §五。

### 步骤 5 · 验收（全部打勾才算完成）

- [x] `docker images` 里 `webapp:v2` 明显小于 `webapp:v1`（目标 < 50MB，冲进 10MB 更好）—— **实测 v2 = 25.3MB，v3 = 12.6MB**
- [x] `curl localhost:8081` 有响应 —— `<h1>Hello DevOps</h1>`；v3 `-p 8082:8080` 同样有响应
- [x] 能**指着 `docker history webapp:v2`** 说出"Go 工具链那 254MB 去哪了" —— 留在 builder 阶段的文件系统里，没被采纳进最终镜像
- [x] 能解释"builder 阶段为什么不会被打包进最终镜像"（自检题）—— 层只由被采纳的指令产生，`COPY --from` 是唯一通道
- [x] `scratch`/`distroless` 至少试过一次，踩的坑记进笔记 —— `Dockerfile.scratch` 已跑通；坑：无 shell 无法 `exec`、`-p` 端口写错
- [x] `notes/week1/day3.md` 四段写满

---

## 四、每日一题（先自己写答案 → 再找人批改）

题目与作答区都在 `notes/week1/day3.md` 的「每日一题」一节：

- **容器题（命令题）**：① 一条命令看"镜像每层多大"？② 一条命令看"运行中容器的资源占用"？③ `scratch` 镜像没有 shell，对排障意味着什么、怎么补救？
- **Linux 题（命令题）**：在 `/data` 下找出「普通文件 + `.tar.gz` 结尾 + 修改超过 30 天 + 大于 50MB」，先打印后删除；并解释 `-name` 为什么要加引号、路径为什么不能带通配符。

> 答不出来比答对更有价值：今天暴露的坑，面试时就不会踩。

---

## 五、卡住了怎么办

| 情况 | 做法 |
|---|---|
| 完全没思路 | 说「给我一个提示」，只要**方向**不要答案 |
| 有思路但不确定 | 先写下来发批改，按「哪里对 / 哪里错 / 为什么」改 |
| 机制没懂 | 说「讲一下 XX 的机制」，按「现象 → 机制 → 命令 → 失败模式」讲 |
| build 失败 | 先读 build 输出**最后 3 行**；scratch 相关问题先查 `docs/docker/05-排障索引.md` |
| 镜像压不下去 | 先 `docker history` 找体积大户，再想"这层运行时需要吗" |
