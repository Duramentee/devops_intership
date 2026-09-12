# Day 2 · 镜像分层与 Dockerfile

> 目标：亲手写出第一个 Dockerfile，并用实验证明「镜像 = 只读层叠加，缓存按指令顺序命中」。
> 配套：`plan/week1/任务明细.md` 的 Day 2 节 · `docs/k8s_in_action/01-容器与K8s入门.md`（p.49-54）
> 笔记落点：`notes/week1/day2.md`（收尾时把四段写满）

---

## 一、今日流程（照着走，不要跳步）

| 顺序 | 时段 | 做什么 | 产出 |
|---|---|---|---|
| 0 | 15 min | **开场抽背**：`docs/linux/Linux-故障索引.md` 随机挑 2 行，按「现象 → 机制 → 命令」复述 | 口述 |
| 1 | 20 min | 把 Go 服务落到本目录，**本地先跑通**（不碰 Docker） | `main.go` / `go.mod` / `webapp` |
| 2 | 20 min | 读机制（p.49-54），写清「镜像分几层、容器启动多了哪一层」 | 笔记草稿 |
| 3 | 60 min | **自己写 `Dockerfile`**（先写完，再看任何参考） | `Dockerfile` |
| 4 | 30 min | build + run + curl，把容器跑通 | 运行中的 `web` 容器 |
| 5 | 20 min | `docker history` 看分层 → **改一行代码再 build**，观察 `CACHED` | 实验记录 |
| 6 | 20 min | **Linux 每日一题**（`docs/linux/Linux-每日一题.md` 的 Day 2 题） | 答案 |
| 7 | 30 min | **容器每日一题**（见本文件第四节） | 答案 |
| 8 | 20 min | 收尾：结论写进 `notes/week1/day2.md`（概念 / 命令 / 易错点 / 我的疑问） | 笔记 |

> **铁律：先做后看。** 第 3 步的 Dockerfile 必须自己写完再对照，否则只是复述别人的答案。

---

## 二、产出物清单（本目录）

| 文件 | 来源 / 说明 | 谁产出 |
|---|---|---|
| `main.go` | Go HTTP 服务，源码照抄 `labs/实践任务.md` 第五部分（任务 8） | 你抄 |
| `go.mod` | `go mod init docker-demo` 生成 | 命令生成 |
| `webapp` | 本地 `go build` 产物，**不要提交、不要 COPY 进镜像** | 命令生成 |
| `Dockerfile` | **今天的主角 —— 自己写** | 你写 |
| `.dockerignore` | Day 6 补，今天先记一笔它解决什么问题 | 待办 |
| 实验记录 | 各层大小 / `CACHED` 从哪层失效，写进 `notes/week1/day2.md` | 你记 |

---

## 三、分步任务与验证 

### 步骤 1 · 本地先跑通（不碰 Docker）

| 场景 | 命令 | 期望现象 |
|---|---|---|
| 初始化模块 | `go mod init docker-demo` | 生成 `go.mod` |
| 编译 | `go build -o webapp main.go` | 目录里出现 `webapp` |
| 起服务 | `./webapp &` | 无报错，占用 8080 |
| 验证 | `curl localhost:8080` | 输出 `<h1>Hello DevOps</h1>` |
| 收尾 | `kill %1` | 进程结束，端口释放 |

> 本地跑不通就别急着写 Dockerfile —— Docker 只会把报错藏进 build log，更难查。

### 步骤 2 · 写 Dockerfile（先自己写！）

**只给骨架，内容你填。** 一份能用的 Dockerfile 至少要让下面几个问题有答案：

| # | 必须回答的问题 | 你用了哪条指令 |
|---|---|---|
| 1 | 基础镜像选什么？`go build` 在哪一阶段跑？ | |
| 2 | 依赖清单（`go.mod` / `go.sum`）什么时候拷进去？和 `COPY . .` 谁先谁后？为什么？ | |
| 3 | 编译在哪一层执行？编译产物叫什么？ | |
| 4 | 容器起来后的**入口进程**是什么？（`CMD` / `ENTRYPOINT`） | |
| 5 | 服务监听 8080，要不要 `EXPOSE`？它到底管什么？ | |

### 步骤 3 · 构建与运行

| 场景 | 命令 | 说明 |
|---|---|---|
| 构建 | `docker build -t webapp:v1 .` | 观察每步是 `CACHED` 还是重新执行 |
| 后台运行 | `docker run -d --name web -p 8080:8080 webapp:v1` | `-d` 后台，`--name` 方便后续操作 |
| 验证 | `curl localhost:8080` | 期望 `<h1>Hello DevOps</h1>` |
| 看日志 | `docker logs web` | curl 失败时**先看这里** |
| 进容器 | `docker exec -it web sh` | 看容器内目录结构，对照 Dockerfile |
| 清理 | `docker rm -f web` | 重建前先删，避免容器名冲突 |

### 步骤 4 · 分层实验（今天的重点）

| 场景 | 命令 | 要观察什么 |
|---|---|---|
| 逐层看 | `docker history webapp:v1` | 每条 Dockerfile 指令 = 一层，记下各层 SIZE |
| 改代码 | 改 `main.go` 里的一句话 | 只动一个字，制造最小差异 |
| 重新构建 | `docker build -t webapp:v1 .` | **从哪一层开始 `CACHED` 消失？为什么是那一层？** |
| 记录结论 | — | 把「哪条指令导致后续层全部失效」写进笔记 |

> 今天唯一必须得出结论的实验：**缓存按层命中，改动层之后的所有层全部重建。**

### 步骤 5 · 验收（全部打勾才算完成）

- [ ] `curl localhost:8080` 有响应
- [ ] `docker images` 里有 `webapp:v1`
- [ ] 能用 `docker history webapp:v1` 指出「哪层是编译、哪层是拷源码」
- [ ] 能解释「`COPY go.mod go.sum ./` 为什么单独一层、放在 `COPY . .` 之前」
- [ ] 改一行代码后能**先预判** `CACHED` 从哪层失效，再用 build 输出验证
- [ ] `notes/week1/day2.md` 四段写满

---

## 四、每日一题（先自己写答案 → 再找人批改）

题目与作答区都在 `notes/week1/day2.md` 的「每日一题」一节：

- **容器题（顺序题）**：`FROM golang` → `COPY . .` → `RUN go mod download` → `RUN go build -o app .`，为什么改一行代码就要重装依赖？顺序该怎么调？
- **Linux 题（排障）**：`df -h` 显示 `/` 使用率 100%，但 `du -sh /*` 合计只有一半 —— 写 3 个可能原因 + 各自的验证命令。

> 答不出来比答对更有价值：今天暴露的坑，面试时就不会踩。

---

## 五、卡住了怎么办

| 情况 | 做法 |
|---|---|
| 完全没思路 | 说「给我一个提示」，只要**方向**不要答案 |
| 有思路但不确定 | 先写下来发批改，按「哪里对 / 哪里错 / 为什么」改 |
| 机制没懂 | 说「讲一下 XX 的机制」，按「现象 → 机制 → 命令 → 失败模式」讲 |
| build 失败 | 先读 build 输出**最后 3 行**，再 `docker logs web`，最后才问 |





