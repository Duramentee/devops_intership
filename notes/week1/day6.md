# Day 6 学习笔记 · 容器安全 + Dockerfile 收尾

> 日期：2026-09-16
> 对应模块：`docs/docker/04-Dockerfile词典.md`（§二 USER/HEALTHCHECK、§五 .dockerignore、§七 反模式）
> 参考：`docs/k8s_in_action/06-机制与安全.md` §4 安全进阶（securityContext / capabilities，下周要用）
> 代码目录：`code/week1/day6/`
> 模板：概念 / 命令 / 易错点 / 我的疑问

---

## 今日速览（讲完再回填，只留结论）

| # | 结论 |
|---|---|
| 1 | |
| 2 | |
| 3 | |
| 4 | |
| 5 | |

---

## 今日任务清单

| # | 任务 | 完成 |
|---|---|---|
| 1 | 预判表 5 条（先写后跑） | |
| 2 | 自己写加固版 `Dockerfile`（非 root + HEALTHCHECK + `.dockerignore`） | |
| 3 | 构建 `webapp:v4` + 跑通 + `(healthy)` | |
| 4 | `--cap-drop=ALL` / `--read-only` 对照实验 | |
| 5 | 镜像体检（工具链 / 源码 / 密钥 / `.git`） | |
| 6 | Linux 每日一题（僵尸进程） | |
| 7 | 容器每日一题（root 风险） | |
| 8 | 四段收尾 | |

---

## 机制笔记（我的理解，待纠错）

### 1. 「容器里的 root」到底是什么

| 问题 | 我的答案 |
|---|---|
| 容器里 `root` 的 uid 是多少？宿主 root 呢？ | |
| 那"危险度不同"差在哪？（身份 / 视野 / 能力） | |
| namespace 与 capability 各是哪一道闸门？ | |

### 2. 默认给了哪些 capability（实测 `CapEff` 对照）

| 场景 | `CapEff`（十六进制） | 换算成"还剩什么能力" |
|---|---|---|
| 默认 | | |
| `--cap-drop=ALL` | | |

> 参考：Docker 默认保留 ≈14 个（CHOWN / DAC_OVERRIDE / FOWNER / FSETID / KILL / SETGID / SETUID / SETPCAP / NET_BIND_SERVICE / NET_RAW / SYS_CHROOT / MKNOD / AUDIT_WRITE / SETFCAP），丢掉 `CAP_SYS_ADMIN` / `CAP_SYS_MODULE` / `CAP_SYS_PTRACE` / `CAP_NET_ADMIN` 等。

### 3. 逃逸路径（"低风险"的边界）

| 场景 | 为什么等于宿主 root | 我的补充 |
|---|---|---|
| `-v /var/run/docker.sock:...` | | |
| `--privileged` | | |
| `--pid=host` + `SYS_PTRACE` | | |
| 内核漏洞 | | |

---

## 命令表（今天用到的，一律表格）

| 场景 | 命令 | 说明 |
|---|---|---|
| | | |

---

## 易错点（今天踩的坑）

| 坑 | 现象 | 正确做法 |
|---|---|---|
| | | |

---

## 我的疑问

1.

---

## 实测记录

### 实验 1 · 预判 vs 实测（回填第二节表格）

| # | 实验 | 预判 | 实测 | 差异说明 |
|---|---|---|---|---|
| 1 | | | | |
| 2 | | | | |
| 3 | | | | |
| 4 | | | | |
| 5 | | | | |

### 实验 2 · 构建与运行

| 项 | 数值 / 输出 |
|---|---|
| `webapp:v4` SIZE / CONTENT / 层数 | |
| `docker inspect -f '{{.Config.User}}'` | |
| `docker exec` 看到的真实 UID | |
| `docker ps` 的 STATUS | |
| `curl` 结果 | |

### 实验 3 · 最小能力 / 只读根

| 场景 | 命令 | 结果 |
|---|---|---|
| `--cap-drop=ALL` | | |
| `--read-only --tmpfs /tmp` | | |

### 实验 4 · 镜像体检

| 查什么 | 命令 | 结果 |
|---|---|---|
| Go 工具链 | | |
| 源码 `.go` | | |
| `.git` | | |
| Env / 密钥 | | |

---

## 每日一题（Day 6）

### 容器题（概念题）

> 为什么"容器里是 root"比"宿主上是 root"风险低？低在哪一层？如果挂载了 `docker.sock` 或用了 `--privileged`，这个结论还成立吗？

**我的答案：**

（待答）

### Linux 题（进程题 · 僵尸）

> ① 一条命令列出所有僵尸进程（含 PID 与父 PID）；② 为什么 `kill -9` 杀不掉它？③ 真正应该怎么处理？

**我的答案：**

（待答）
