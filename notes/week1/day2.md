# Day 2 · 镜像分层与 Dockerfile

> 日期：2026-09-12 · 代码：`code/week1/day2/`（`main.go`、`go.mod`、`Dockerfile`、`webapp`）· 原笔记备份：`/tmp/day2-notes-backup.md`
> 关联文档：`docs/docker/01-架构与原理.md` §七（分层与 CoW）/ §八（构建缓存）· `docs/docker/03-Dockerfile词典.md` §一（构建流程）/ §四（缓存与顺序）
> 产出：`webapp:v1`（单阶段，449MB / 88.9MB / 17 层）· 服务 `curl localhost:8080` → `<h1>Hello DevOps</h1>`

---

## 1. 结论速览

| # | 结论 |
|---|---|
| 1 | 镜像 = 一组**只读层**叠加（overlay2 联合挂载）；容器启动时最上面加一层**可写层** |
| 2 | **每条 Dockerfile 指令生成一层**；相同层可被多个镜像共享 |
| 3 | 缓存以**层**为单位、按指令顺序逐层比对：某层输入变化 → **该层及其后所有层**全部重建 |
| 4 | 单阶段镜像之所以大：**构建工具链与构建缓存都留在层里**（Go 工具链 254MB + GOCACHE 91.8MB），随镜像一起交付 |
| 5 | `docker history` 中 `<missing>` **不是错误**：表示该中间层没有独立的 image ID |
| 6 | 读日志的前提是应用把日志写到 **stdout/stderr**；写进文件则只有容器内可见 |

---

## 2. 机制

### 2.1 镜像分层与可写层

| 动作 | 发生什么 |
|---|---|
| 读只读层中的文件 | 直接读，不复制 |
| 写 / 删只读层中的文件 | 先复制到可写层（copy-up）再修改；删除则记录 whiteout，**下层始终只读** |
| 容器启动 | 在镜像最上面挂一层**可写层**（容器层），生命周期随容器对象 |

### 2.2 缓存失效规则

| 问题 | 答案 |
|---|---|
| 缓存以什么为单位 | **层**，按指令顺序逐层比对 |
| 何时失效 | 该层的输入变化：`COPY` 的文件内容、`RUN` 的命令字符串、`FROM` 的基础镜像 |
| 失效范围 | **从失效层开始，之后所有层全部重建** |
| 唯一例外 | 指令只写元数据（`EXPOSE`/`USER`/`CMD`/`LABEL`）时不产生层，也不参与缓存比对 |

**直接证据（本日实测）**：改动 `main.go` 一个字符 → `COPY ./go.mod` 及其之前全部 `CACHED`，`COPY ./main.go`、`go mod tidy`、`go build` 全部重建。

---

## 3. 命令

| 场景 | 命令 | 说明 |
|---|---|---|
| 构建镜像 | `docker build -t webapp:v1 .` | 结尾的 `.` = **构建上下文**（整个目录按需送给 builder）；输出中的 `CACHED` = 该层命中缓存 |
| 起容器 | `docker run -d --name web -p 8080:8080 webapp:v1` | `-p 宿主:容器`；两侧的 8080 属于**不同 net namespace** |
| 验证服务 | `curl localhost:8080` | 失败先看 `docker ps` 的 STATUS，再看 `docker logs web` |
| 看日志 | `docker logs web` | 应用必须把日志写到 **stdout/stderr** 才能收到 |
| 看分层 | `docker history webapp:v1` | 每条指令一行，`CREATED BY` 对应指令；按 `SIZE` 列定位占用最大的层 |
| 看启动命令的真实形态 | `docker inspect web --format '{{json .Config.Cmd}}'` | **数组** = exec form（不经 shell）；**字符串** = shell form |
| 容器内看 PID 1 | `docker exec web ps aux` | 容器视角（PID 从 1 编号）；需镜像内有 `ps` |
| 宿主视角看进程 | `docker top web` | ⚠️ 输出的是**宿主 PID**，不能用来判断容器内的 PID 1 |
| 排障三连 | `docker inspect` → `docker logs` → `docker exec` | 先看"在不在/怎么退出"，再看日志，最后进入环境 |

---

## 4. 实测数据（原始输出）

| 项 | 数值 |
|---|---|
| 基础镜像 | `golang:1.25.1-alpine` |
| 镜像总层数 | **17 层** = 基础镜像自带 10 层 + 自己 7 层 |
| 体积构成 | `COPY /target/` **254MB**（Go 工具链）+ `RUN go build` **91.8MB**（产物 + GOCACHE）+ `RUN go mod tidy` 3.87MB |
| 缓存断点 | 改 `main.go` 一个字符 → `COPY ./go.mod` 及更早的层全部 `CACHED`；`COPY ./main.go`、`tidy`、`build` 全部重建 |

> 本节数据在 Day 3 被进一步拆解（工具链 254MB 的来源、GOCACHE 82.4MB 的算法、DISK USAGE 与 CONTENT SIZE 两个尺度）→ 见 `notes/week1/day3.md` §4。

---

## 5. 易错点

| 错法 | 现象 | 正确做法 |
|---|---|---|
| 把 `CACHED` 断点的原因归为 overlay2 | 结论对但归因错误，换场景就推不出正确结论 | 缓存是 builder 逐层计算 **cache key**（父层 key + 指令字符串 + 输入内容哈希）的链式比对，与 overlay2 无关；overlay2 管的是运行期层挂载 |
| 用 `docker top web` 判断容器内的 PID 1 | 输出的是宿主 PID | 容器视角用 `docker exec web ps aux`；宿主侧对应 PID 用 `docker inspect -f '{{.State.Pid}}' web` |
| 在 exec form 里写 shell 语法 | `CMD ["./webapp", ">>", "x.log", "2>&1", "&"]` 会静默变成 **4 个参数**（exec form 不经 shell，JSON 数组每个元素就是一个 argv 元素） | 需要重定向/后台就改用 shell form，或在应用内自行写日志（日志走 stdout，由 `docker logs` 收集） |
| 在 `RUN`（构建期）里做运行期的事 | 例如用 `RUN touch /var/log/app.log` 建运行日志 | 区分阶段：**构建期用 `RUN`，运行期用 `CMD`/`ENTRYPOINT`** |
| 以为日志会自动收集 | 应用把日志写进文件时 `docker logs` 为空 | 让应用输出到 stdout/stderr，或 `docker exec` 进入容器读文件 |
| 改了代码、镜像也重建了，但服务行为没变 | 三类常见原因：① 起的是**旧容器**（没 `docker rm` 旧容器，新容器可能因端口被占没起来，`curl` 打到旧容器）② 本地编译产物被 `COPY . .` 带进镜像，**覆盖**了镜像内编译结果 ③ 多阶段 `COPY --from` 指到了旧阶段名/错路径 | ① `docker ps -a --format '{{.Names}} {{.Image}} {{.Status}}'` + `docker images` 看 tag 指向的 image ID ② 写 `.dockerignore` 排除本地二进制 ③ 核对 `COPY --from=<阶段名>` 与实际产物路径 |

---

## 6. 每日一题（面试自测）

### 容器题：为什么每次改代码都要重装依赖

**题目**：给定下面的 Dockerfile，改一行代码后重新 build，为什么 `go mod download` 这一层缓存每次都会失效？该怎样调整顺序？为什么？

```dockerfile
FROM golang
COPY . .
RUN go mod download
RUN go build -o app .
```

**我的原答**：`COPY . .` 这条指令过于粗糙，`main.go` 每次改动都会让这一层的输入变化，导致后续缓存全部失效；应把 `COPY` 拆开写，把 `go.mod` 与其他文件分开复制。

**判定：方向正确** —— 标准答案与理由如下：

| 项 | 内容 |
|---|---|
| 根因 | `COPY . .` 的输入是**整个上下文**，任何一个文件变化都会使该层的 cache key 变化 → 其后的层（`download` / `build`）全部重建 |
| 正确顺序 | `COPY go.mod go.sum ./` → `RUN go mod download` → `COPY . .` → `RUN go build` |
| 为什么有效 | 依赖层（`go mod download`）只依赖 `go.mod`/`go.sum` 两个几乎不变的文件；改源码只让 `COPY . .` 之后的层失效，依赖层保持 `CACHED` |
| 补充 | 只复制了 `go.mod` 时**不能用 `go mod tidy`**（tidy 需要扫描源码判断依赖，此时源码尚未进入镜像），要用 `go mod download`；该结论在 Day 6 被再次验证 |

> 相关机制：`docs/docker/03-Dockerfile词典.md` §四（缓存与顺序）与 `docs/docker/01-架构与原理.md` §八（构建缓存规则）。

---

## 7. 遗留疑问

| # | 问题 | 状态 |
|---|---|---|
| 1 | 单阶段的 254MB 工具链与 91.8MB 构建缓存能否不进最终镜像 | ✅ 已在 Day 3 解决（多阶段构建 → 25.3MB / 12.6MB） |
| 2 | `CMD` 用 exec form 还是 shell form，对信号有什么影响 | ✅ 已在 Day 5 解决（PID 1 信号语义，见 `notes/week1/day5.md` §2.3） |
