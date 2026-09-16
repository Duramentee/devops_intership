# Day 6 · 容器安全 + Dockerfile 收尾

> 目标：把 Day 3 那个「能跑、够小」的镜像，升级成**能拿去面试**的版本（非 root / 最小能力 / 只读根 / 无密钥）。
> 配套：`docs/docker/04-Dockerfile词典.md` §二（`USER`/`HEALTHCHECK`）、§五（`.dockerignore`）、§七（反模式清单）· `plan/week1/任务明细.md` Day 6 节
> 笔记落点：`notes/week1/day6.md`
> **基线**：`webapp:v2` = 25.3MB / 8.3MB / 6 层（alpine 多阶段）· `webapp:v3` = 12.6MB / 4.51MB / 4 层（scratch）

---

## 一、今日流程

| 顺序 | 时段 | 做什么 | 产出 |
|---|---|---|---|
| 0 | 15 min | **开场抽背**（考 Day 5 的坑）：PID 1 信号语义 / 137 vs 143 / `-m` 硬限制 | 口述 |
| 1 | 20 min | 读机制：为什么「容器里的 root」≠「宿主上的 root」 | 机制笔记 |
| 2 | 15 min | **预判表**（见第二节）：跑之前先写答案，不许先跑 | 5 条预判 |
| 3 | 60 min | **写加固版 `Dockerfile`（你自己写，不许先看参考）** + `.dockerignore` | `Dockerfile` / `.dockerignore` |
| 4 | 30 min | 构建 `webapp:v4` → 用 `--cap-drop=ALL` / `--read-only` 跑 → 非 root 验证 | 跑通的容器 |
| 5 | 20 min | 体检镜像：有没有混进 Go 工具链 / 源码 / 密钥 | 体检报告 |
| 6 | 20 min | **Linux 每日一题**（`docs/linux/Linux-每日一题.md` Day 6：僵尸进程） | 答案 |
| 7 | 30 min | **容器每日一题**（见第四节） | 答案 |
| 8 | 20 min | 收尾：四段写进 `notes/week1/day6.md` | 笔记 |

> **铁律：先做后看。** 步骤 3 必须自己写完再对照任何参考。

---

## 二、预判表（先填，再跑 —— 跑完回填「实测」列）

| # | 实验 | 跑前预判 | 实测 |
|---|---|---|---|
| 1 | `docker run --rm alpine:3.22 ping -c1 8.8.8.8` → 再加 `--cap-drop=ALL` 重跑 | 两次结果一样吗？为什么 | |
| 2 | `docker run --rm alpine:3.22 sh -c 'grep ^Cap /proc/self/status'` → 对比 `--cap-drop=ALL` | `CapEff` 十六进制差在哪几位 | |
| 3 | 非 root（uid=10001）容器监听 **80** 端口 | 成功 / 失败，什么报错 | |
| 4 | `docker run --rm --read-only alpine touch /f` | 什么报错 | |
| 5 | `docker inspect -f '{{.Config.User}} {{.Config.Env}}' webapp:v2` | 你现在这个镜像是 root 吗？Env 里有秘密吗 | |

---

## 三、任务清单

### 步骤 1 · 准备上下文

```bash
cp ../day3/main.go ../day3/go.mod .
```

### 步骤 2 · 写加固版 `Dockerfile`（今天的主角，你写）

**只给问题，不给代码。** 一份"能拿去面试"的 Dockerfile 至少要让下面每条有答案：

| # | 必须回答的问题 | 你用的指令 / 参数 |
|---|---|---|
| 1 | 运行阶段换成 **非 root**：用户在哪一步建？（scratch 阶段建不了用户，怎么办） | |
| 2 | 二进制从 builder 捞过来时，**属主**怎么一起带过来？否则非 root 进程能执行它吗？ | |
| 3 | `USER` 写在 `COPY` 之前还是之后？ | |
| 4 | `HEALTHCHECK` 的**判定语义**是什么（哪个退出码算健康）？ | |
| 5 | 你的运行阶段**有没有 shell / wget**？如果没有，`HEALTHCHECK` 还能怎么写？ | |
| 6 | 端口用 8080 还是 80？跟「非 root」有什么关系？ | |
| 7 | `.dockerignore` 至少要排除哪几类东西？ | |
| 8 | 镜像里还有源码 / 工具链吗？怎么**证明**（给命令）？ | |

### 步骤 3 · 构建 & 运行

| 场景 | 命令 | 期望现象 |
|---|---|---|
| 构建 | `docker build -t webapp:v4 .` | 成功 |
| 默认跑 | `docker run -d --name web4 -p 8083:8080 webapp:v4` | — |
| 验证身份 | `docker exec web4 id` | ⚠️ 镜像里没 `id` 命令就换 `grep ^Uid /proc/1/status` |
| 验证接口 | `curl localhost:8083` | `<h1>Hello DevOps</h1>` |
| 验证健康检查 | `docker ps --format 'table {{.Names}}\t{{.Status}}'` | STATUS 列出现 `(healthy)` |
| 最小能力 | `docker run --rm --cap-drop=ALL -p 8084:8080 -d --name web4c webapp:v4` | 还能提供 HTTP 服务吗 |
| 只读根 | `docker run --rm --read-only --tmpfs /tmp -p 8085:8080 webapp:v4` | 能起吗；写文件呢 |

### 步骤 4 · 体检镜像（"里面有没有不该有的东西"）

| 查什么 | 命令 | 看什么 |
|---|---|---|
| 层构成 | `docker history webapp:v4` | 有没有几百 MB 的层 |
| 配置里有没有密钥 | `docker inspect -f '{{.Config.Env}}' webapp:v4` | `ENV`/`ARG` 都会留在镜像里 |
| 整个 rootfs 清单 | `docker export $(docker create webapp:v4) \| tar -tvf - \| head -50` | 不用进容器就能列文件 |
| 有没有源码 | `docker run --rm --entrypoint find webapp:v4 / -name '*.go'` | 空 = 干净 |
| 有没有 .git | 同上换 `-name '.git'` | 空 = 干净 |

> ⚠️ `docker export` 那条命令的 `$(docker create ...)` 会**留下一个未启动的容器**，记得 `docker rm`。

### 步骤 5 · 验收（全打勾才算完成）

- [ ] `docker images` 里 `webapp:v4` 仍然 **< 50MB**
- [ ] `docker inspect -f '{{.Config.User}}' webapp:v4` **不是空、不是 root/0**
- [ ] `docker ps` 里该容器显示 **`(healthy)`**
- [ ] `--cap-drop=ALL` 下服务**照常**响应（说明它本来就不需要那些能力）
- [ ] `--read-only` 下服务**照常**响应
- [ ] 镜像里查不到 `.go` 源码 / `.git`
- [ ] 能说出 ≥3 条"写 Dockerfile 的安全习惯"（自检题）

---

## 四、每日一题（先自己写答案 → 再找人批改）

作答区在 `notes/week1/day6.md`。

- **容器题（概念题）**：为什么"容器里是 root"比"宿主上是 root"风险低？**低在哪一层**？如果挂载了 `docker.sock` 或用了 `--privileged`，这个结论还成立吗？
- **Linux 题（进程题）**：① 一条命令列出系统里所有僵尸进程（含 PID 与父 PID）；② 为什么 `kill -9` 杀不掉它？③ 真正应该怎么处理？

---

## 五、卡住了怎么办

| 情况 | 做法 |
|---|---|
| 完全没思路 | 说"给我一个提示"，只给方向不给答案 |
| 有思路但不确定 | 先写下来发我，按"哪里对、哪里错、为什么"批改 |
| 机制没懂 | 说"讲一下 XX 的机制"，按「现象 → 机制 → 命令 → 失败模式」讲 |
