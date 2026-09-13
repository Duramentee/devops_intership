# Day 2 学习笔记 · 镜像分层与 Dockerfile

> 日期：2026-09-12
> 对应模块：`docs/k8s_in_action/01-容器与K8s入门.md`（p.49-54：Docker 三大概念 + 镜像分层）
> 代码目录：`code/week1/day2/`
> 模板：概念 / 命令 / 易错点 / 我的疑问

---

## 今日任务清单

| # | 任务 | 完成 |
|---|---|---|
| 1 | `docker run --rm hello-world` —— 跑通第一个容器 | ⬜ |
| 2 | **验证「容器 = 被隔离的普通进程」**：`docker run -d --name t1 alpine sleep 300` → 宿主机 `ps -ef \| grep sleep` 能看到它 → `docker exec t1 ps aux` 看容器内 PID → `docker rm -f t1` 后宿主进程也消失 | ⬜ |
| 3 | Go 服务落到 `code/week1/day2/`：`main.go` → `go mod init duramentee/devops_intership_day2` → `go build -o webapp main.go` | ✅ |
| 4 | **自己写 Dockerfile**（先写完再找人看）→ `docker build -t webapp:v1 .` | ✅ |
| 5 | `docker run -d --name web -p 8080:8080 webapp:v1` + `curl localhost:8080` | ✅ |
| 6 | `docker history webapp:v1` —— 看清「每条指令 = 一层」，记下各层大小 | ✅ |
| 7 | 改一行 `main.go` 再 build —— 观察 `CACHED` 从**哪一层开始**失效 | ✅ |

> 实测记录（2026-09-12）：基础镜像 = `golang:1.25.1-alpine`，镜像总层 17 层 = 基础镜像自带 10 层 + 自己 7 层。
> 体积构成：`COPY /target/` **254MB**（Go 工具链）+ `RUN go build` **91.8MB**（产物 + GOCACHE）+ `RUN go mod tidy` 3.87MB。
> 缓存实测：改 `main.go` 一个字符 → `COPY ./go.mod` 及之前 **全部 CACHED**，`COPY ./main.go`、`tidy`、`build` **全部重建**。

---

## 每日一题（先自己写答案 → 再找人批改）

### 容器题 · 顺序题

```dockerfile
FROM golang
COPY . .
RUN go mod download
RUN go build -o app .
```

改一行代码后重新 build，为什么每次都要**重装依赖**（`go mod download` 这一层缓存失效）？这个顺序该怎么调？为什么？

**我的答案：**

用了 COPY . . 这个指令过于粗糙, 每次main.go改动都会触发变动导致缓存失效重新构建 最好是把 COPY 指令分开写, 把go.mod和其他的分开拷贝

---

## 概念

> 学完填：镜像为什么要分层、"可写层 / 写时复制"是什么、缓存命中规则。

| 要点 | 用自己的话写一遍 |
|---|---|
| 镜像 = ？ | 一堆**只读层**叠起来（overlay2 联合挂载）。`FROM` 提供基础层，之后**每条 Dockerfile 指令生成一层**；相同层可被多个镜像共享 |
| 容器启动时加的层 | 在最上面加一层**可写层**（容器层）。读：直接读下层；写/删：copy-up 到可写层（删除记白障），**下层始终只读** |
| 缓存为什么会失效 | 缓存以**层**为单位、**按指令顺序逐位比对**。某层的输入变了（`COPY` 的文件内容 / `RUN` 的命令字符串 / `FROM` 的镜像）→ 该层**及其后所有层**全部重建 |
| 单阶段镜像为什么这么胖 | 构建工具链（Go 工具链 254MB）和构建缓存（GOCACHE 91.8MB）**都被留在了层里** —— 编译器跟着镜像一起发货。解法见 Day 3 多阶段构建 |
| `<missing>` 是什么 | **不是错误**。表示该层没有独立的 image ID（中间层未单独成镜像）。层链最上面 = 最新层（`docker history` 从上到下是 新→旧） |

## 命令

| 场景 | 命令 | 说明 |
|---|---|---|
| 构建镜像 | `docker build -t webapp:v1 .` | 结尾的点号 `.` = **构建上下文**（整个目录会按需送给 builder）；输出里 `CACHED` = 该层命中缓存 |
| 起容器 | `docker run -d --name web -p 8080:8080 webapp:v1` | `-p 宿主:容器`；两边的 8080 属于**不同网络命名空间** |
| 验证服务 | `curl localhost:8080` | 失败先看 `docker ps` 的 STATUS，再看 `docker logs web` |
| 看日志 | `docker logs web` | 应用把日志写 **stdout/stderr** 才收得到（写文件 = 只有容器内可见） |
| 看分层 | `docker history webapp:v1` | 每条指令一行；`CREATED BY` 对应哪条指令；记 SIZE 定位体积大户 |
| 看启动命令真实形态 | `docker inspect web --format '{{json .Config.Cmd}}'` | **数组** = exec form（不经 shell）；**字符串** = shell form |
| 容器内看 PID 1 | `docker exec web ps aux` | 容器视角（PID 从 1 编号） |
| 宿主视角看进程 | `docker top web` | ⚠️ 输出的是**宿主 PID**，不是 1 —— 别拿它判断 PID 1 |
| 排障三连 | `docker inspect` → `docker logs` → `docker exec` | 先看「在不在/怎么退」，再看日志，最后进环境 |

## 易错点

| 错法 | 现象 | 正确做 |
|---|---|---|
| 用 `ps -ef` 查僵尸进程，以为能看到 `Z` | `ps -ef` 的固定列是 `UID PID PPID C STIME TTY TIME CMD`，**没有 STAT 列**；只能靠 CMD 列里的 `<defunct>` 字样碰运气 | 使用 `ps -aux`查, 有一列(第八列)为STAT, 在该列会显示Z, 说明这是一个僵尸进程, 或者用``ps -eo pid,ppid,stat,cmd`查也可以 |
| 认为僵尸进程「不占内存所以无所谓」 | 不占 CPU / 用户内存，但**仍占内核 `task_struct` 和 PID 表项**；大量堆积会耗尽 PID、导致 fork 失败 | 治本的做法是直接改代码, 要求父进程wait()子进程, 治标的做法是把父进程kill了,让init进程收养这个子进程然后回收该进程 |
| 把「终端关闭 → 服务消失」归因成 `kill -15` / SIGTERM | 终端断开时内核发的是 **SIGHUP(1)**；信号记错后 `nohup` 为什么能救命也讲不通 | 终端断开时, 内核给该终端的前台进程组/会话首进程(通常是 shell)发的是 **SIGHUP(1)** 信号, shell 退出时再向自己的作业补发同一个信号, 而不是 SIGTERM(15); nohup 的作用是把这个进程对 **SIGHUP** 的处置设为 **SIG_IGN**(子进程继承), 同时若 stdin 是终端则重定向到 `/dev/null`, 若 stdout 是终端则重定向到 **`nohup.out`**(此时 stderr 也合并进同一文件) |
| 用 `jobs` 取后台服务的 PID | `jobs` 只属于当前 shell；服务脱离终端后 shell 与作业表一起消失，脚本/非交互场景拿不到 | 使用 echo $! 取到最后一个进程的PID, $! 在这里就是最近一个后台进程的 PID, 但是要注意启动后立刻就要取, 否则可能就取到别的进程了 |
| 反复 `kill` 僵尸进程想「杀掉」它 | 僵尸已不再被调度，信号发过去无人处理，纯属无效；真正该处理的是**它的父进程** | 治本的做法是直接改代码, 要求父进程wait()子进程, 治标的做法是把父进程kill了,让init进程收养这个子进程然后回收该进程 |

## 我的疑问

| # | 题目 | 考点 |
|---|---|---|
| | | |
