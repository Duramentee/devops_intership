# Day 6 · 容器安全与 Dockerfile 加固

> 日期：2026-09-16 · 代码：`code/week1/day6/` · 原笔记备份：`/tmp/day6-notes-backup.md`
> 关联文档：`docs/docker/01-架构与原理.md` §8（USER / UID）、§10（capability）· `docs/docker/03-Dockerfile词典.md` §八
> 产出：`webapp:v4` = 25.3MB / 8.3MB（与 v2 相同，说明加固不增加体积）· 运行身份 uid 10001 · `docker ps` 显示 `(healthy)` · 在 `--cap-drop=ALL` 与 `--read-only --tmpfs /tmp` 下均能正常响应

---

## 1. 结论速览

| # | 结论 |
|---|---|
| 1 | 容器的权限 = **uid（只是一个数字）+ 一组 capability 位**，实际判定看位图。证据：**同一个 uid=0**，没有 `NET_BIND_SERVICE` 时绑 80 被拒，只保留该位就成功 |
| 2 | **非 root 时 `CapPrm`/`CapEff` 被内核清空**，`--cap-add` 只写入 `CapBnd`（能力上限）→ 容器层提权对非 root 无效 |
| 3 | **Docker 的默认值是放宽过的**：`ping_group_range = 0 2147483647`（内核默认为空区间）、`ip_unprivileged_port_start = 0`（内核默认 1024）→ 测 capability 前必须先读 sysctl 基线值（本日有一组实验因未控制该变量而结论无效） |
| 4 | `--read-only` 属于**挂载标志**层（报错 `Read-only file system`），与 capability 无关；配合 `--tmpfs /tmp` 提供可写点 |
| 5 | **加固四件套**：非 root（`USER`）+ 镜像内无源码与工具链（多阶段 + `.dockerignore`）+ `--cap-drop=ALL` + `--read-only --tmpfs` |
| 6 | **元数据指令不产生镜像层**：`EXPOSE`/`USER`/`HEALTHCHECK`/`CMD` 在 build 日志中没有独立步骤（`stage-1` 只有 3 步）→ 加固不会让镜像变大（v4 = v2） |
| 7 | 非 root 的**代价**：`find /` 会报 `/root: Permission denied`（权限 700）→ 排障时也会被自己的权限挡住；且**逃逸后不是普通用户，而是宿主 root** |

---

## 2. 机制

### 2.1 容器内的 root 与宿主 root 差在哪

| 问题 | 答案 |
|---|---|
| 容器内 `root` 的 uid？宿主 root 呢？ | **都是 0**，身份数字完全相同 |
| 那"危险程度不同"差在哪？ | 不在身份，而在**可见范围（namespace）+ 能力（capability）**被内核做了减法 |
| 三层限制 | ① **namespace**：看不到宿主进程 / 文件树 / 网络栈 ② **capability**：root 的全部权限被拆成约 40 位，默认只保留 14 个 ③ **seccomp / AppArmor**：过滤系统调用 |

### 2.2 capability 字段与位图读法

**`/proc/self/status` 中的 5 个字段**

| 字段 | 含义 |
|---|---|
| `CapBnd` | **能力上限**：本进程一生能获得的能力上限；`exec` setuid-root 程序也只能涨到该上限以内 |
| `CapPrm` / `CapEff` | 当前可用 / 当前生效的能力（实际判定看 `CapEff`） |
| `CapInh` / `CapAmb` | 跨 `execve` 传递用，默认全 0 |

**位图读法（实测默认值 `0xa80425fb`）**

| 字节 | 二进制 | 置 1 的位 → 能力名 |
|---|---|---|
| `0xfb` | `1111 1011` | 0 `CHOWN` · 1 `DAC_OVERRIDE` · 3 `FOWNER` · 4 `FSETID` · 5 `KILL` · 6 `SETGID` · 7 `SETUID` |
| `0x25` | `0010 0101` | 8 `SETPCAP` · 10 `NET_BIND_SERVICE` · 13 `NET_RAW` |
| `0x04` | `0000 0100` | 18 `SYS_CHROOT` |
| `0xa8` | `1010 1000` | 27 `MKNOD` · 29 `AUDIT_WRITE` · 31 `SETFCAP` |

共 **14 个**，与 Docker 默认能力清单逐项一致。
`--cap-drop=ALL` 之后 **`CapEff` / `CapPrm` / `CapBnd` 全部归零** → 连"镜像内放置 setuid-root 二进制再提权"这条路也完全阻断。

### 2.3 非 root 时 `--cap-add` 为什么无效

| 组 | 身份 | `CapPrm` / `CapEff` | `CapBnd` | 绑 80（阈值 1024） |
|---|---|---|---|---|
| K1 | root + 默认 | `a80425fb` | `a80425fb` | — |
| K2 | 非 root + 默认 | **`0000000000000000`** | `a80425fb` | ❌ 被拒 |
| K3 | 非 root + drop ALL + add `NET_BIND_SERVICE` | **`0000000000000000`** | **`0x400`**（位 10） | ❌ 被拒 |
| K4 | root + drop ALL + add 该位 | — | — | ✅ 绑上（退出码 143） |
| K5 | 非 root + add 该位 + 阈值 0 | — | — | ✅ 绑上（退出码 143） |

**结论**：非 root 时 `CapPrm`/`CapEff` 被内核清空，`--cap-add` 只写入 `CapBnd`，因此不生效。要让非 root 真正获得能力，只能使用 **file capabilities**（`setcap`）或 **ambient capabilities**。
**绑低端口的完整判定条件**：`端口 < net.ipv4.ip_unprivileged_port_start` **且** `CapEff` 中没有 `CAP_NET_BIND_SERVICE` 时才拒绝 —— 两个条件缺一不可。

### 2.4 逃逸路径

| 场景 | 为什么等价于宿主 root |
|---|---|
| `-v /var/run/docker.sock:...` | 可通过该 socket 命令宿主 dockerd 启动 `--privileged` 容器并挂载宿主 `/`（合法操作，不是漏洞） |
| `--privileged` | 直接取消 capability 限制并放行设备 |
| `--pid=host` + `CAP_SYS_PTRACE` | 可以 ptrace / 杀死宿主进程 |
| 内核漏洞 | 唯一需要真实漏洞的路径 |

因此规范做法是**不使用 root 运行**（K8s 中即 `runAsNonRoot`）：非 root 进程即使逃逸，也最多是普通用户。

### 2.5 Docker 注入的 sysctl 默认值

下表是本节所有相关实验的**前置背景**：不写 `--sysctl` 时，容器里这两个参数**不是内核默认值**，而是 Docker 注入的值。

| 参数 | 内核默认 | Docker 默认 | 影响 |
|---|---|---|---|
| `net.ipv4.ping_group_range` | `1 0`（空区间） | `0 2147483647` | 任何 gid 都能创建 ICMP **datagram** socket，无需 root 或 `NET_RAW` 即可 `ping` |
| `net.ipv4.ip_unprivileged_port_start` | `1024` | `0` | 任何 uid 都能绑低端口，不再需要 `NET_BIND_SERVICE` |

→ **Docker 的默认值 ≠ 最小权限**：`--cap-drop=ALL` 只处理 capability，这些放宽的 sysctl 仍然生效，必须用 `--sysctl` 显式覆盖。

### 2.6 案例：`--cap-drop=ALL` 之后 `ping` 为什么仍然成功

**第一步：ICMP 有两条实现路径，开关不同**

| 路径 | 系统调用 | 内核检查什么 | 开关 |
|---|---|---|---|
| raw | `socket(AF_INET, SOCK_RAW, IPPROTO_ICMP)` | 当前用户命名空间里有 `CAP_NET_RAW` | `--cap-add=NET_RAW` |
| datagram | `socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)` | 进程 gid 是否落在 `net.ipv4.ping_group_range` 区间内 | `--sysctl net.ipv4.ping_group_range=...` |

**第二步：两条路径的默认状态恰好一条开、一条关**

| 项 | 控制哪条路径 | 默认状态 | `--cap-drop=ALL` 之后 |
|---|---|---|---|
| `CAP_NET_RAW` | raw | Docker 默认授予（在默认的 14 个能力里） | **被移除** → raw 路径关闭 |
| `net.ipv4.ping_group_range` | datagram | Docker 注入 `0 2147483647`（允许全部 gid） | **不受 capability 影响，仍然允许** |

**第三步：`ping` 自己会回退**

busybox `ping` 先尝试 raw socket；被拒绝（EPERM）时回退到 datagram socket。所以：

| 场景 | 实际走的路径 | 结果 |
|---|---|---|
| 默认容器 | raw（有 `NET_RAW`） | 成功 |
| `--cap-drop=ALL` | raw 被拒 → 回退 datagram | **成功**（datagram 被 Docker 放宽的 `ping_group_range` 允许） |
| `--cap-drop=ALL` + 区间被置空 `'1 0'` | 两条路径都被关闭 | 失败（`permission denied (are you root?)`，退出码 1） |

**验证实验（对应 §4 实验 1b）**：A 只读 `ping_group_range` 得 `0 2147483647`（Docker 注入）→ B 用 `--sysctl net.ipv4.ping_group_range='1 0'` 置空区间后失败 → C 在 B 基础上只加回 `--cap-add=NET_RAW` 又成功。

**结论**：`--cap-drop=ALL` 只处理 capability；Docker 为兼容性主动放宽的 sysctl 不受它影响 → **"Docker 的默认值" ≠ "最小权限"**，要真正收紧必须显式 `--sysctl` 覆盖。

### 2.7 绑低端口判定式的四种组合（自查用）

| 阈值 `ip_unprivileged_port_start` | 端口 | 条件一：端口 < 阈值 | `CapEff` 有 `NET_BIND_SERVICE` | 结果 |
|---|---|---|---|---|
| `0`（**Docker 默认**） | 443 | 不成立 | ✗ | ✅ 允许（capability 不参与判定） |
| `0` | 8443 | 不成立 | ✗ | ✅ 允许 |
| `1024`（内核默认 / `--sysctl` 调回） | 443 | 成立 | ✗（非 root 时 `CapEff` = 0） | ❌ 拒绝 |
| `1024` | 8443 | 不成立 | ✗ | ✅ 允许 |

→ 记两句：① 判定式的**两个条件必须同时成立才拒绝**；② 不写 `--sysctl` 时阈值是 Docker 给的 **`0`**，因此默认容器里"绑低端口被拒"**不会发生** —— 想复现必须先把阈值调回 1024。

---

## 3. 命令

| 场景 | 命令 | 说明 |
|---|---|---|
| 读 capability 位图 | 容器内 `grep ^Cap /proc/self/status` | `Eff` = 当前生效，`Bnd` = 能力上限 |
| 全部移除 / 加回一个能力 | `--cap-drop=ALL` / `--cap-add=NET_RAW` | ⚠️ 名字**不带 `CAP_` 前缀**；`drop` 写在 `add` 之前 |
| 以非 root 运行 | 镜像内 `USER 10001:10001` / 运行期 `-u 10001:10001` | 非 root 时 `CapPrm`/`CapEff` 被内核清空 |
| 读 sysctl 基线值 | `cat /proc/sys/net/ipv4/ip_unprivileged_port_start` | Docker 默认 `0`，内核默认 `1024` |
| 只读根 + 可写 /tmp | `--read-only --tmpfs /tmp` | 属于挂载标志层 |
| 禁止提权 | `--security-opt no-new-privileges` | 使 setuid / file capabilities 全部失效 |
| 查看镜像身份与环境变量 | `docker inspect -f '{{.Config.User}}'`、`{{.Config.Env}}` | 空 = root；Env 中的密钥是明文的 |
| 镜像内容检查（不依赖镜像内的工具） | `docker run --rm --entrypoint find <img> / -name '*.go'`、`docker export $(docker create <img>) \| tar -tvf -` | 非 root 会报 `/root: Permission denied`，属正常现象 |
| 建用户 | Alpine：`adduser -D -u 10001 app`；Debian：`useradd -m -u 10001 app` | 详见 `docs/docker/03-Dockerfile词典.md` §八 |

---

## 4. 实测数据（原始输出）

**实验 1 · capability 位图**

| # | 实验 | 原始输出 |
|---|---|---|
| 1 | 默认 `CapEff` | `a80425fb`（Eff / Prm / Bnd 三者相同） |
| 1b | `--cap-drop=ALL` 后的 `CapEff` | `0000000000000000`（`CapBnd` 也归零） |
| 2 | `ping` 报错原文 | `ping: permission denied (are you root?)`（退出码 1） |
| 3 | 绑 80 报错原文 | `nc: bind: Permission denied`（阈值 1024，退出码 1） |
| 4 | `--read-only` 报错原文 | `touch: /f: Read-only file system`（退出码 1）；加 `--tmpfs /tmp` 后可写（退出码 0） |
| 5 | `Config.User` / `Config.Env` | v2：`User=`（空）/ `Env=[PATH=...]`；v4：`User=10001:10001` |

**实验 1b · `ping` 在 `--cap-drop=ALL` 下仍能成功的原因（A/B/C）**

| 组 | 变量 | 实测结果 | 结论 |
|---|---|---|---|
| A | 只读 `ping_group_range` | `0	2147483647` | **Docker 注入**（内核默认为空区间 `1 0`） |
| B | 区间置空 `--sysctl net.ipv4.ping_group_range='1 0'`，无 `NET_RAW` | ❌ `permission denied (are you root?)`，退出码 1 | 两条路径同时被关闭 |
| C | B + `--cap-add=NET_RAW` | ✅ 正常回包，退出码 0 | raw 路径只认 `CAP_NET_RAW` |

| 路径 | 系统调用 | 内核检查什么 | 开关 |
|---|---|---|---|
| raw | `socket(AF_INET, SOCK_RAW, IPPROTO_ICMP)` | `ns_capable(net->user_ns, CAP_NET_RAW)` | `--cap-add=NET_RAW` |
| datagram | `socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)` | gid 是否落在 `net.ipv4.ping_group_range` 内 | `--sysctl net.ipv4.ping_group_range=...` |

**排除法**：A 组成功时 `CAP_NET_RAW` = 0，raw 路径不可能成立 → 走的一定是 datagram 路径。两条路径相互独立，各有开关。

**实验 1c · 绑 80 的完整矩阵（阈值 1024）**

| 组 | uid | `CapEff` 中有该位 | 结果 |
|---|---|---|---|
| F2 | 0 | ✗ | ❌ 被拒 —— 推翻"是 root 就能绑低端口" |
| K4 | 0 | ✓ | ✅ 绑上 —— 同一个 uid，仅位图不同，结果相反 |
| E2 / G2 | 10001 | 名义有 / 仅 `CapBnd` 有 | ❌ 被拒 |
| K5 与 D~G | 任意 | 任意（阈值 = 0） | ✅ 全部能绑 —— 判定条件第一个条件不成立，capability 不参与判定 |

**实验 2 · 构建与运行（`webapp:v4`）**

| 项 | 数值 / 输出 |
|---|---|
| SIZE / CONTENT SIZE | **25.3MB / 8.3MB**（与 v2 相同；v3 scratch 版为 12.6MB / 4.51MB） |
| build 日志 | 两阶段：`[builder 6/6]` + `[stage-1 3/3]`；`stage-1` 只有 `FROM` / `RUN adduser` / `COPY` 三步 |
| `docker inspect -f '{{.Config.User}}'` | `10001:10001`（v2 为空） |
| 容器内真实身份 | `Uid: 10001 10001 10001 10001` |
| `docker ps` | `Up About a minute (healthy)` |
| `curl localhost:8083` | `<h1>Hello DevOps</h1>` |

**实验 3 / 4 · 加固对照与镜像内容检查**

| 场景 | 命令 | 结果 |
|---|---|---|
| 全部移除 capability | `docker run -d --name web4c -p 8084:8080 --cap-drop=ALL webapp:v4` | ✅ `curl` 正常（服务本身不需要这些能力） |
| 只读根文件系统 | `docker run -d --name web4r -p 8085:8080 --read-only --tmpfs /tmp webapp:v4` | ✅ `curl` 正常 |
| Go 工具链 | `docker images webapp` | ✅ 未进入最终镜像（v1 449MB → v4 25.3MB） |
| 源码 `.go` | `docker run --rm --entrypoint find webapp:v4 / -name '*.go'` | ✅ 无命中 |
| `.git` | 构建上下文仅 446B，且 Dockerfile 中没有 `COPY . .` | ✅ 不会进入镜像 |
| setuid 文件 | `docker run --rm --entrypoint find webapp:v4 / -perm -4000 -type f` | ✅ 无命中（没有提权入口） |
| 环境变量 / 密钥 | `docker inspect -f '{{.Config.Env}}'` | ✅ 只有 `PATH` |

---

## 5. 易错点

| 坑 | 现象 | 正确做法 |
|---|---|---|
| `go mod tidy` 放在"只复制了 go.mod"的那一层 | `tidy` 需要扫描源码才能判断依赖，而此时源码还没进入 | 用 `go mod download` |
| `CMD /app/webapp`（shell form） | PID 1 变成 `/bin/sh -c` → `docker stop` 的信号被 shell 拦截，超时后收到 137 | exec form `CMD ["/app/webapp"]` |
| 认为 `USER` 必须写在 `COPY` 之前 | `COPY` 的文件属主只由 `--chown` 决定，与 `USER` 无关 | `USER` 只要排在需要 root 的指令（如 `RUN adduser`）之后 |
| 认为非 root 可以用 `--cap-add` 提升权限 | 非 root 的 `CapPrm`/`CapEff` = 0，`--cap-add` 只写入 `CapBnd` | 绑 **1024 以上**端口；对外暴露用宿主侧 `-p 80:8080` |
| 未读 sysctl 基线值就测 capability | 四组实验全部成功，**结论是错的** | 先 `cat /proc/sys/...`，必要时用 `--sysctl` 调回内核默认值 |
| 用输出文案判断实验成败 | `punt!` 只在成功路径出现，`(are you root?)` 也不是真实原因 | **只看退出码**（143 / 124 = 绑定成功；1 = 被拒） |
| `adduser` / `useradd` 混用、UID 与 GID 不配对 | 构建失败，或 gid 仍为 0 | 见 `docs/docker/03-Dockerfile词典.md` §8.1 / §8.3 |
| 把 `--read-only` 与 tmpfs 的 `noexec` 混为一谈 | 两个不同属性：`--read-only` 下写 `/var/run` 报 `Read-only file system`（**根文件系统只读**，属挂载标志）；tmpfs 的 `noexec` 是"**能写、不能执行**" | 需要可写的目录就显式挂：`--tmpfs /var/run`；需要能执行就加 `exec`：`--tmpfs /tmp:rw,exec` |

---

## 6. 每日一题（面试自测）

### 6.1 容器题：为什么"容器里是 root"比"宿主上是 root"风险低？

**答案骨架**

| 层次 | 内容 |
|---|---|
| ① namespace | 容器 root **看不到**宿主进程 / 文件树 / 网络栈，想操作的对象在路径上不存在 |
| ② capability | root 的全部权限被拆成约 40 位，Docker 默认只保留 **14 个**，`SYS_ADMIN` / `SYS_MODULE` / `SYS_PTRACE` / `NET_ADMIN` 默认没有 |
| ③ seccomp / AppArmor | 默认 profile 再过滤一批系统调用 |

**关键点**：这三层都是内核中的减法限制，进程身份本身就是 uid=0。所以一旦有路径绕过（`--privileged` / 挂载 `docker.sock` / 内核漏洞），后果**不是"普通用户"而是宿主 root** —— 这才是 `runAsNonRoot` 的真正理由。

**挂载 `docker.sock` 或使用 `--privileged` 后结论是否成立**：不成立。前者可以命令宿主 dockerd 启动 `--privileged` 容器并挂载宿主 `/`（合法操作，非漏洞）；后者直接取消 ②③ 两层限制并放行设备。

**我的复述（原始版本）**：容器里需要 uid + 权限位图，即便是 uid 为 0（root），但权限位不开、能力也不够，所以风险会比较低；挂上那两个之后结论就不成立，应该是会导致容器 root 逃逸到宿主机。

**批注（5.5 / 8，3 个已修正的点）**：① 漏了 namespace 这一层（"低在哪一层"的一半）② 措辞应改为"**uid=0 ≠ 有能力**" ③ `--privileged` 不是"导致逃逸"，而是**当场取消限制**；`docker.sock` 也不需要漏洞。

**背诵版**：容器里的 root 和宿主 root 是**同一个 uid 0**；风险较低是因为内核做了**三层减法** —— namespace 让它看不到宿主、capability 只保留约 40 个能力位中的 **14 个**、seccomp 再过滤一批系统调用。但这三层都是减法，一旦绕过（`--privileged` / `docker.sock` / 内核漏洞），进程**本来就是 uid 0**，后果不是普通用户而是**宿主 root** —— 所以要 `runAsNonRoot`。

### 6.2 Linux 题：僵尸进程

**问题**：① 用一条命令列出所有僵尸进程（含 PID 与父进程 PID）；② 为什么 `kill -9` 杀不掉它？③ 正确处理方式？

**答案**

| 问 | 答案 |
|---|---|
| ① | `ps -eo pid,ppid,stat,cmd \| awk '$3 ~ /^Z/'`（`STAT` 中的 `Z` = defunct）；也可直接读 `/proc/<pid>/stat` 第 3 字段 |
| ② | 僵尸进程**已经结束**：不再运行、不占 CPU / 内存，只剩内核中一条 `task_struct`（保存退出码等父进程读取）。信号只对"活着的进程"有意义，因此 `kill` 会返回成功但状态不变 |
| ③ | **不能杀它，只能让父进程回收（`wait()`）**：① 父进程实现回收逻辑（`waitpid` / 处理 `SIGCHLD`）② 父进程不处理时，**结束父进程**，僵尸由 `init`(PID 1) 接管回收 ③ 重启宿主机只是掩盖问题，不算处理 |

**与容器的联系**：容器内的 PID 1 必须负责回收，否则容器内会累积僵尸进程 —— 这就是 `docker run --init`（tini）的用途；K8s 中同理。

**我的复述（原始版本）**：`ps -aux` 看 `STAT` 列，为 `Z` 就是僵尸；再记住 PID 用 `ps -ef` 查父 PID。僵尸本身是个死进程，`kill -9` 强制杀也没用；真正的处理要么改代码让父进程 `wait` 子进程，要么让 init 收养它。

**批注（6 / 8，4 个已修正的点）**：① 题目要求**一条命令**且含 PID 与 PPID（`ps -aux` 用了两步，且 BSD 风格列不固定，用户名长时 PID 列会错位）② 机制描述缺一句"信号只对活着的进程有意义" ③ 让 init 收养的前提是**父进程先退出** ④ 漏了加分点：容器内 PID 1 必须回收（`--init`）。

---

## 7. 遗留疑问（带进第 2 周验证）

1. `--cap-add` 对非 root 只写入 `CapBnd`、完全不生效 —— K8s 中 `securityContext.capabilities.add` 给**非 root** 容器加能力，是否同样无效？
2. Docker 的 `HEALTHCHECK` 在 K8s 中会被忽略 —— 那探针应该配置在哪一层？（第 2 周：liveness / readiness）
3. `USER` 未设置 `HOME` 时，Go 程序中 `os.UserHomeDir()` 会返回什么？（`$HOME` 未设置 → 可能落到 `/root`）
