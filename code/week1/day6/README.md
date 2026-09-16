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
| 2 | 20 min | **先跑 5 条命令、抄原始输出**（见第二节：抄数 → 对账，不填预判） | 5 条原始输出 |
| 3 | 60 min | **写加固版 `Dockerfile`（你自己写，不许先看参考）** + `.dockerignore` | `Dockerfile` / `.dockerignore` |
| 4 | 30 min | 构建 `webapp:v4` → 用 `--cap-drop=ALL` / `--read-only` 跑 → 非 root 验证 | 跑通的容器 |
| 5 | 20 min | 体检镜像：有没有混进 Go 工具链 / 源码 / 密钥 | 体检报告 |
| 6 | 20 min | **Linux 每日一题**（`docs/linux/Linux-每日一题.md` Day 6：僵尸进程） | 答案 |
| 7 | 30 min | **容器每日一题**（见第四节） | 答案 |
| 8 | 20 min | 收尾：四段写进 `notes/week1/day6.md` | 笔记 |

> **铁律：先做后看。** 步骤 3 必须自己写完再对照任何参考。

---

## 二、实验顺序：先跑 → 抄数 → 对账（**不填预判**）

> ⚠️ 为什么不预判：预判只在「能用已有机制外推」时有效（Day 2 缓存断点、Day 5 退出码都属于这类）。**capability 是全新概念，没有可外推的模型**，硬填就是猜谜 —— 没有惊讶，就没有学习。所以这里改成三步：**先跑 → 把原始输出抄下来 → 再对着底料做解释**。

### 第 1 步 · 先跑 5 条，只抄原始输出（不要求你做任何判断）

| # | 命令 | 抄什么 | 输出 |
|---|---|---|---|
| 1 | `docker run --rm alpine:3.22 sh -c 'grep ^Cap /proc/self/status'` | `CapEff` 十六进制 | |
| 1b | 同上再加 `--cap-drop=ALL` | 再抄一次 | |
| 2 | `docker run --rm --cap-drop=ALL alpine:3.22 ping -c1 8.8.8.8` | 报错**原文** | |
| 3 | `docker run --rm -u 10001 alpine:3.22 sh -c 'nc -l -p 80'` | 报错**原文** | |
| 4 | `docker run --rm --read-only alpine:3.22 touch /f` | 报错**原文** | |
| 5 | `docker inspect -f '{{.Config.User}}|{{.Config.Env}}' webapp:v2` | 两个字段的值 | |

### 第 2 步 · 底料（这是知识，不是答案）

| 底料 | 内容 |
|---|---|
| capability 是什么 | 内核把「root 的全能」拆成 ~40 个**独立的位**。进程能不能干某事 = **对应位有没有置 1**，**跟 uid 是不是 0 无关**。`CapEff` 就是这个位图（十六进制 = 64 个二进制的压缩写法） |
| Docker 默认给 ≈14 个 | `CHOWN` `DAC_OVERRIDE` `FOWNER` `FSETID` `KILL` `SETGID` `SETUID` `SETPCAP` `NET_BIND_SERVICE` `NET_RAW` `SYS_CHROOT` `MKNOD` `AUDIT_WRITE` `SETFCAP` |
| 默认砍掉的（危险那批） | `SYS_ADMIN` `SYS_MODULE` `SYS_PTRACE` `NET_ADMIN` `SYS_TIME` `SYS_RAWIO` … |

### 第 3 步 · 对账（有依据可推，不是猜）

| # | 问题 | 状态 |
|---|---|---|
| 1 | 从 `0xa80425fb` 里能不能**对出**那 14 个默认能力的名字（位图 ↔ 清单互验）？ | ✅ 已对出，一字不差 |
| 2 | 绑 80 端口失败、而默认清单里有 `NET_BIND_SERVICE` —— 怎么用它解释「root 才能绑 1024 以下端口」？ | 待做 |
| 3 | `--read-only` 的报错含 `Read-only file system` —— 限制加在**哪一层**？（cgroup / 挂载标志 / capability） | 待做 |
| 4 | ⚠️ **意外**：`--cap-drop=ALL` 后 `ping 8.8.8.8` **竟然成功了**，与「raw socket 需要 `CAP_NET_RAW`」矛盾 → 用下面的对照实验定位 | 待做 |

**「ping 之谜」对照实验（一次只改一个变量）**

| 组 | 命令 | 看什么 |
|---|---|---|
| A | `docker run --rm --cap-drop=ALL alpine:3.22 cat /proc/sys/net/ipv4/ping_group_range` | 这条 sysctl 的值。`0 2147483647` = 允许任意 gid 建 ICMP **datagram** socket（**不检查 `CAP_NET_RAW`**） |
| B | `docker run --rm --cap-drop=ALL --sysctl net.ipv4.ping_group_range='1 0' alpine:3.22 ping -c1 8.8.8.8` | 区间掏空 + 没有 RAW → 还通吗 |
| C | `docker run --rm --cap-drop=ALL --cap-add=NET_RAW --sysctl net.ipv4.ping_group_range='1 0' alpine:3.22 ping -c1 8.8.8.8` | 只把 RAW 加回来 → 又通了吗 |

| B 结果 | C 结果 | 结论 |
|---|---|---|
| 失败 | 成功 | ✅ 走的是 datagram 路径：raw 只认 `CAP_NET_RAW`，datagram 只认 `ping_group_range`（两条路互相独立） |
| 还通 | 成功 | ❌ 假设不成立 → `docker info \| grep -i userns`（若容器在 user namespace 里，它在该 ns 内是"全能力"的） |

**实测结果（已跑完）**

| 组 | 实测输出 | 退出码 |
|---|---|---|
| A | `0\t2147483647` ← Docker 默认注入（内核默认是 `1 0` 空区间） | 0 |
| B | `ping: permission denied (are you root?)` | 1 |
| C | 正常回包 `64 bytes from 8.8.8.8` | 0 |

→ 结论：`--cap-drop=ALL` 下 ping 走的是 **datagram 路**（排除法：raw 不可能）；**"Docker 默认值" ≠ "最小权限"**。详见 `docs/docker/02-底层原理.md` §6.5。

**观察组 2 的坑（已踩）：绑 80 实验被默认值短路**

| 项 | 实测 |
|---|---|
| `net.ipv4.ip_unprivileged_port_start` | `0`（内核默认 **1024**，**Docker 改成 0**） |
| 后果 | D/E/F/G 四组**全部成功**（退出码 143 = 被 `timeout` 的 SIGTERM 杀），`NET_BIND_SERVICE` 根本没参与判定 |
| 修正 | 用 `--sysctl net.ipv4.ip_unprivileged_port_start=1024` 重做 → `exp2b.sh`（F2/E2/G2 三组） |

**观察组 2b/2c 结论（已跑完）**

| 组 | uid | `CapEff` 有位？ | 阈值 | 绑 80 |
|---|---|---|---|---|
| F2 | 0 | ✗ | 1024 | ❌ `Permission denied` |
| **K4** | **0** | ✓（只留该位） | 1024 | ✅ 绑上（143）← 同一个 uid，唯一位图不同结果相反 |
| E2 / G2 | 10001 | 名义有 / 仅 Bnd 有 | 1024 | ❌ 被拒 |
| K5 / D~G | 任意 | 任意 | **0** | ✅ 全都能绑 |

| 测量 | K2（非 root 默认） | K3（非 root drop ALL + add） |
|---|---|---|
| `CapEff` | **`0`** | **`0`** |
| `CapBnd` | `a80425fb` | **`0x400`**（位 10 = `NET_BIND_SERVICE`） |

→ **非 root 时 P/E 被清空，`--cap-add` 只进 `CapBnd`（天花板）→ 不生效**。详见 `docs/docker/02-底层原理.md` §6.6。

**`Cap*` 五字段速查（今天的新知识点）**

| 字段 | 含义 |
|---|---|
| `CapBnd` | **天花板**：本进程一生能拿到的能力上限；`exec` setuid-root 程序也只能涨到 Bnd 内。`--cap-drop=ALL` 会把它归零 → 连 setuid 提权也堵死 |
| `CapPrm` / `CapEff` | 当前**可用** / **生效**的能力（干活靠这两个） |
| `CapInh` / `CapAmb` | 跨 `execve` 传递用，默认全 0 |

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
| **有没有 setuid 二进制**（潜在提权入口） | `docker run --rm --entrypoint find webapp:v4 / -perm -4000 -type f` | 空 = 没有 |

> ⚠️ 如果运行阶段选了 **scratch**：镜像里**连 `find` 都没有**（上一行的 `--entrypoint find` 会报 `no such file or directory`）。改用不依赖镜像内工具的：
> `docker export $(docker create webapp:v4) \| tar -tvf -`（列出整个 rootfs）

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
