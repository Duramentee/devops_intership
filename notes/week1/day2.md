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
| 3 | Go 服务落到 `code/week1/day2/`：贴 `main.go` → `go mod init docker-demo` → `go build -o webapp main.go` | ⬜ |
| 4 | **自己写 Dockerfile**（先写完再找人看）→ `docker build -t webapp:v1 .` | ⬜ |
| 5 | `docker run -d --name web -p 8080:8080 webapp:v1` + `curl localhost:8080` | ⬜ |
| 6 | `docker history webapp:v1` —— 看清「每条指令 = 一层」，记下各层大小 | ⬜ |
| 7 | 改一行 `main.go` 再 build —— 观察 `CACHED` 从**哪一层开始**失效 | ⬜ |

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

### Linux 题 · Day 2 排障（磁盘空间）

现象：`df -h` 显示 `/` 使用率 100%，但 `du -sh /*` 合计只有一半。写出 **3 个可能原因**，每个配一条**验证命令**。

**我的答案：**

---

## 概念

> 学完填：镜像为什么要分层、"可写层 / 写时复制"是什么、缓存命中规则。

| 要点 | 用自己的话写一遍 |
|---|---|
| 镜像 = ？ | |
| 容器启动时加的层 | |
| 缓存为什么会失效 | |

## 命令

| 场景 | 命令 | 说明 |
|---|---|---|
| | | |

## 易错点

| 错法 | 现象 | 正确做法 |
|---|---|---|
| | | |

## 我的疑问

| # | 题目 | 考点 |
|---|---|---|
| | | |
