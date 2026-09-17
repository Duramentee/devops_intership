# Day 6 学习笔记 · 容器安全 + Dockerfile 收尾

> 日期：2026-09-16 · 代码：`code/week1/day6/`（`Dockerfile` = 加固版、`Dockerfile.skeleton`、`cap-ping.sh`/`exp2*.sh` = 实验）
> 详细机制已迁进文档：`docs/docker/02-底层原理.md` **§六 capability** · `docs/docker/03-命令词典.md` §七/§十 · `docs/docker/04-Dockerfile词典.md` **§八 USER/adduser/UID**
> 产出：`webapp:v4` = 25.3MB / 8.3MB · 非 root（uid 10001）· `(healthy)` · `--cap-drop=ALL` 与 `--read-only --tmpfs` 下照常响应
> 原 330 行完整版备份在 `/tmp/day6-full-20260916.md`

---

## 一、今日速览（结论）

| # | 结论 |
|---|---|
| 1 | 容器的权限 = **uid（只是数字）+ 一叠能力位**；决定"能干什么"的是**位图**。铁证：**同一个 uid=0**，无 `NET_BIND_SERVICE` 绑 80 被拒、只留该位就通过 |
| 2 | **非 root 时 `CapPrm`/`CapEff` 被内核清空**，`--cap-add` 只写进 `CapBnd`（天花板）→ **容器层提权对非 root 无效**（K3：`CapBnd=0x400` = 位 10，而 `CapEff=0`） |
| 3 | **Docker 的默认值是"放宽"过的**：`ping_group_range=0 2147483647`、`ip_unprivileged_port_start=0`（内核默认分别是空区间 / 1024）→ **测能力位前必须先量 sysctl**（本日因没控住变量白跑一组实验） |
| 4 | `--read-only` 是**挂载标志**层的东西（`Read-only file system`），与能力位无关；配 `--tmpfs /tmp` 给可写点 |
| 5 | **加固四件套**：非 root（`USER`）+ 无源码/工具链（多阶段 + `.dockerignore`）+ `--cap-drop=ALL` + `--read-only --tmpfs` |
| 6 | **元数据指令不产层**：`EXPOSE`/`USER`/`HEALTHCHECK`/`CMD` 在 build 日志里没有独立步骤（`stage-1` 只有 3 步）→ **加固不会让镜像变大**（v4 = v2 = 25.3MB/8.3MB） |
| 7 | 非 root 的**代价**：`find /` 会报 `/root: Permission denied`（700）→ **排障时也会被自己挡住**；且**逃逸后不是普通用户，而是宿主 root** |

---

## 二、任务清单

| # | 任务 | 完成 |
|---|---|---|
| 1 | 抄数 5 条（先跑，只抄原始输出，后对账） | ✅ |
| 2 | 自己写加固版 `Dockerfile`（非 root + HEALTHCHECK + `.dockerignore`） | ✅ |
| 3 | 构建 `webapp:v4` + 跑通 + `(healthy)` | ✅ |
| 4 | `--cap-drop=ALL` / `--read-only` 对照实验 | ✅ |
| 5 | 镜像体检（工具链 / 源码 / 密钥 / `.git` / setuid） | ✅ |
| 6 | Linux 每日一题（僵尸进程） | 🔶 参考答案已补，**复述待写** |
| 7 | 容器每日一题（root 风险） | 🔶 参考答案已补，**复述待写** |
| 8 | 四段收尾 + 精简笔记（330 → 本文） | ✅ |

---

## 三、机制笔记

### 1. 「容器里的 root」到底是什么

| 问题 | 答案 |
|---|---|
| 容器里 `root` 的 uid？宿主 root 呢？ | **都是 0** —— 身份数字完全一样 |
| 那"危险度不同"差在哪？ | 不在身份，在**视野（namespace）+ 能力（capability）**被内核做了减法 |
| 三道闸门 | ① **namespace**：看不见宿主进程 / 文件树 / 网络栈 ② **capability**：root 全能被拆成 ~40 位，默认只留 14 个 ③ **seccomp/AppArmor**：过滤系统调用 |

### 2. 默认能力位（实测 `CapEff` 对照）

| 场景 | `CapEff` | 含义 |
|---|---|---|
| 默认 | `a80425fb` | **14 个**（位 0/1/3/4/5/6/7/8/10/13/18/27/29/31）；**缺** `NET_ADMIN`(12) `SYS_MODULE`(16) `SYS_PTRACE`(19) `SYS_ADMIN`(21) |
| `--cap-drop=ALL` | `0000000000000000` | **连 `CapBnd` 也归零** → 连 setuid 提权都堵死 |

→ 位图怎么读（逐字节解码）、`Cap*` 五字段语义：`docs/docker/02-底层原理.md` §6.2/§6.3

### 3. 逃逸路径 —— 一句话：**逃逸后不是普通用户，而是宿主 root**

| 场景 | 为什么等于宿主 root |
|---|---|
| `-v /var/run/docker.sock:...` | 能命令宿主 dockerd 起 `--privileged` 容器并挂宿主 `/`（**合法操作，不是漏洞**） |
| `--privileged` | 直接拆掉能力减法 + 放行设备 |
| `--pid=host` + `SYS_PTRACE` | 能 ptrace / 杀宿主进程 |
| 内核漏洞 | 唯一需要"真漏洞"的路径 |

> 所以规范做法是**根本不用 root 跑**（`runAsNonRoot`）：非 root 就算逃逸，最多还是普通用户。

### 4. 建用户与选 UID（细节已迁文档，这里只留结论）

| 问题 | 结论 |
|---|---|
| `adduser` 还是 `useradd`？ | **两个命令**：`useradd` 是 shadow 底层原语；`adduser` 是封装（Debian = Perl 脚本、Alpine = BusyBox applet，**参数不通用**） |
| Alpine 底座 | `RUN adduser -D -u 10001 app`（Alpine **没有** `useradd`） |
| Debian 底座 | `RUN useradd -m -u 10001 app`（非交互） |
| scratch 底座 | 不建用户，只写 `USER 10001:10001` |
| 为什么是 10001？ | **社区惯例，无内核含义**（≥1000、跨发行版安全、远离 0/65534） |
| 必守的 3 条 | ① 镜像内唯一 ② **UID:GID 配对写**（否则 gid = 0 = root 组）③ bind mount 时与宿主属主对齐 |

→ 全部细节（三种实现对比表、UID 区间、`/proc/self/uid_map`、`USER` 三个易错点）：`docs/docker/04-Dockerfile词典.md` §八

---

## 四、命令表（今天新增的）

| 场景 | 命令 | 说明 |
|---|---|---|
| 读能力位图 | 容器内 `grep ^Cap /proc/self/status` | `Eff` = 现在生效、`Bnd` = 天花板 |
| 全砍 / 加回一个能力 | `--cap-drop=ALL` / `--cap-add=NET_RAW` | ⚠️ 名字**不带 `CAP_` 前缀**；drop 写在前 |
| 非 root 跑 | `USER 10001:10001`（镜像里）/ `-u 10001:10001`（运行期） | 非 root 时 P/E 被内核清空 |
| 量 sysctl 底料 | `cat /proc/sys/net/ipv4/ip_unprivileged_port_start` | Docker 默认 `0`（内核默认 1024） |
| 只读根 + 可写 /tmp | `--read-only --tmpfs /tmp` | 挂载标志层 |
| 禁提权 | `--security-opt no-new-privileges` | setuid / file caps 全失效 |
| 看镜像身份 / 环境 | `docker inspect -f '{{.Config.User}}'`、`{{.Config.Env}}` | 空 = root；Env 里若写过密钥就是明文的 |
| 镜像体检（不依赖镜像内工具） | `docker run --rm --entrypoint find <img> / -name '*.go'`、`docker export $(docker create <img>) \| tar -tvf -` | 非 root 会报 `/root: Permission denied`（正常） |
| 建用户 | 见 `docs/docker/04` §八 | Alpine `adduser -D` / Debian `useradd -m` |

---

## 五、易错点

| 坑 | 现象 | 正确做法 |
|---|---|---|
| `go mod tidy` 放在"只拷了 go.mod"的那层 | tidy 要扫源码才能判断依赖，而源码还没进来 | 用 `go mod download` |
| `CMD /app/webapp`（shell form） | PID 1 变成 `/bin/sh -c` → `docker stop` 信号被 sh 吃掉、等超时被打 **137** | exec form `CMD ["/app/webapp"]` |
| 以为 `USER` 必须写在 `COPY` 之前 | **COPY 属主只由 `--chown` 决定**，与 `USER` 无关 | `USER` 排在"需要 root 的指令（如 `RUN adduser`）"之后即可 |
| 以为非 root 能靠 `--cap-add` 提权 | 非 root 的 P/E = 0，`--cap-add` 只进 `Bnd` | 绑 **>1024** 端口；对外暴露用宿主侧 `-p 80:8080` |
| 没量 sysctl 就测能力位 | 四组全成功，**结论是假的** | 先 `cat /proc/sys/...`，必要时 `--sysctl` 调回内核默认值 |
| 用文案判定实验成败 | `punt!` 只在**成功**路径出现，`(are you root?)` 也不是真因 | **只看退出码**（143/124 = 绑上了；1 = 被拒） |
| `adduser` / `useradd` 混用、UID 不配对 | 构建失败或 gid 仍是 0 | 见 `docs/docker/04` §8.1/§8.3 |

---

## 六、我的疑问（待下周验证）

1. `--cap-add` 对非 root 只进 `CapBnd`、完全不生效 —— 那 K8s 里 `securityContext.capabilities.add` 给**非 root** 容器加能力，是不是也一样无效？
2. Docker 的 `HEALTHCHECK` 在 K8s 里会被忽略 —— 那探针到底写在哪一层？（下周 liveness/readiness）
3. `USER` 不设 `HOME`，Go 程序里 `os.UserHomeDir()` 会拿到什么？（`$HOME` 未设 → 可能落到 `/root`）

---

## 七、实测记录

### 实验 1 · 能力位抄数

| # | 实验 | 原始输出 |
|---|---|---|
| 1 | 默认 `CapEff` | `a80425fb`（Eff/Prm/Bnd 三者相同） |
| 1b | `--cap-drop=ALL` 的 `CapEff` | `0000000000000000`（**Bnd 也归零**） |
| 2 | `ping` 报错原文 | `ping: permission denied (are you root?)`（B 组，退出码 1） |
| 3 | 绑 80 报错原文 | `nc: bind: Permission denied`（阈值 1024，退出码 1） |
| 4 | `--read-only` 报错原文 | `touch: /f: Read-only file system`（退出码 1）；加 `--tmpfs /tmp` 后可写（0） |
| 5 | `Config.User` / `Config.Env` | v2：`User=`（**空**）/ `Env=[PATH=...]`；v4：`User=10001:10001` |

**位图解码**：`0xfb`→位 0/1/3/4/5/6/7；`0x25`→位 8 `SETPCAP`、10 `NET_BIND_SERVICE`、13 `NET_RAW`；`0x04`→位 18 `SYS_CHROOT`；`0xa8`→位 27 `MKNOD`、29 `AUDIT_WRITE`、31 `SETFCAP` = **共 14 个**，与默认清单完全一致。

**对账三问**

| # | 答案 |
|---|---|
| 1 | `ping` 失败**不是**"缺位"那么简单：两条路同时被关 —— `CAP_NET_RAW` 被 drop，datagram 路的许可证 `ping_group_range` 被 `--sysctl` 掏空 |
| 2 | 绑 80 判定式：**端口 < `ip_unprivileged_port_start`** 且 **`CapEff` 无该位** → 才拒。实测：root 无位 ❌ / root 只留该位 ✅ / 非 root ❌ / 阈值=0 时全 ✅ |
| 3 | `Read-only file system` 加在**挂载标志**层（不是 cgroup、不是 capability） |

### 实验 1b · ping 之谜（A/B/C，已钉死）

| 组 | 变量 | 实测 | 结论 |
|---|---|---|---|
| A | 只读 `ping_group_range` | `0 2147483647` | **Docker 默认注入**（内核默认 `1 0` 空区间） |
| B | 区间掏空 `'1 0'` + 无 `NET_RAW` | ❌ `permission denied (are you root?)` | 两条路同时关 |
| C | B + `--cap-add=NET_RAW` | ✅ 正常回包 | raw 路只认 `CAP_NET_RAW` |

| 路 | 系统调用 | 检查什么 | 开关 |
|---|---|---|---|
| raw | `socket(AF_INET, SOCK_RAW, IPPROTO_ICMP)` | `ns_capable(net->user_ns, CAP_NET_RAW)` | `--cap-add=NET_RAW` |
| datagram | `socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)` | gid 落在 `net.ipv4.ping_group_range` 内 | `--sysctl net.ipv4.ping_group_range=...` |

**排除法**：`--cap-drop=ALL` 成功时 raw 路不可能 → 走的**一定是 datagram 路**。

### 实验 1c · 非 root 的位图（决定性测量）

| 组 | 身份 | `CapPrm`/`CapEff` | `CapBnd` | 绑 80（阈值 1024） |
|---|---|---|---|---|
| K1 | root + 默认 | `a80425fb` | `a80425fb` | — |
| K2 | 非 root + 默认 | **`0`** | `a80425fb` | ❌ 被拒 |
| K3 | 非 root + drop ALL + add `NET_BIND_SERVICE` | **`0`** | **`0x400`**（位 10） | ❌ 被拒 |
| K4 | root + drop ALL + add 该位 | — | — | ✅ 绑上（143） |
| K5 | 非 root + add 该位 + 阈值 0 | — | — | ✅ 绑上（143） |

**结论**：非 root 时 **P/E 被内核清空**，`--cap-add` 只改 `CapBnd`（天花板）→ 不生效；**权限来自能力位（uid 无用）**，但非 root 拿不到位。

### 实验 2 · 构建与运行（`webapp:v4`）

| 项 | 数值 / 输出 |
|---|---|
| SIZE / CONTENT | **25.3MB / 8.3MB**（= v2，同底座；v3 scratch = 12.6MB/4.51MB） |
| build 日志 | 两阶段：`[builder 6/6]` + `[stage-1 3/3]`；`stage-1` 只有 `FROM`/`RUN adduser`/`COPY` 三步 |
| `docker inspect -f '{{.Config.User}}'` | `10001:10001`（对比 v2 = 空） |
| 真实身份 | `Uid: 10001 10001 10001 10001` |
| `docker ps` | `Up About a minute (healthy)` |
| `curl` | `<h1>Hello DevOps</h1>` |

### 实验 3 / 4 · 加固对照与镜像体检

| 场景 | 命令 | 结果 |
|---|---|---|
| 全砍能力 | `docker run -d --name web4c -p 8084:8080 --cap-drop=ALL webapp:v4` | ✅ curl 照常（本来就不需要那些能力） |
| 只读根 | `docker run -d --name web4r -p 8085:8080 --read-only --tmpfs /tmp webapp:v4` | ✅ curl 照常 |
| Go 工具链 | `docker images webapp` | ✅ 未进最终镜像（v1 449MB → v4 25.3MB） |
| 源码 `.go` | `docker run --rm --entrypoint find webapp:v4 / -name '*.go'` | ✅ 无命中（只有非 root 自带的 Permission denied） |
| `.git` | 上下文仅 446B + Dockerfile 无 `COPY . .` | ✅ 进不去 |
| setuid | `docker run --rm --entrypoint find webapp:v4 / -perm -4000 -type f` | ✅ 无命中（无提权入口） |
| Env / 密钥 | `docker inspect -f '{{.Config.Env}}'` | ✅ 只有 PATH |

---

## 八、每日一题（Day 6）

### 容器题（概念题）

> 为什么"容器里是 root"比"宿主上是 root"风险低？低在哪一层？如果挂载了 `docker.sock` 或用了 `--privileged`，这个结论还成立吗？

**参考答案 · 低在哪一层（三层）**

| 层 | 内容 |
|---|---|
| ① namespace | 容器 root **看不见**宿主进程 / 文件树 / 网络栈 → 想动的东西"路径上就不存在" |
| ② capability | root 全能被拆成 ~40 位，Docker 默认只留 **14 个**，砍掉 `SYS_ADMIN`/`SYS_MODULE`/`SYS_PTRACE`/`NET_ADMIN` → 挂文件系统、加载内核模块、ptrace 宿主全被拒 |
| ③ seccomp / AppArmor | 默认 profile 再过滤一批系统调用 |

**题眼 · 放大器效应**：三道闸门都是内核里的"减法"，进程身份**本来就是 uid=0**。所以一旦有路径绕过去，**后果不是"普通用户"而是"宿主 root"** —— 这才是 `runAsNonRoot` 的真正理由。

**挂 `docker.sock` / `--privileged` 之后？→ 结论不成立**

| 场景 | 为什么 |
|---|---|
| `-v /var/run/docker.sock:...` | 能命令宿主 dockerd **起一个 `--privileged` 容器并挂载宿主 `/`** → 合法地拿到宿主 root（不是漏洞，是配置） |
| `--privileged` | 直接拆掉 ②③ 两道闸门，设备也放行 |

**我的复述（原文）**：容器里需要 uid + 权限位图，即便是 uid 为 0（root），但权限位不开、能力也不够，所以风险会比较低；挂上那两个之后结论就不成 立了，应该是会导致容器 root 逃逸到宿主机。

**批注（🔶 5.5/8）**

| 采分点 | 判定 |
|---|---|
| uid 都是 0 | ✅ |
| **视野差异（namespace）** | ❌ **漏了第一道闸门** —— 这是"低在哪一层"的一半 |
| 能力差异 | ✅（但措辞应改为"**uid=0 ≠ 有能力**"） |
| seccomp / AppArmor | ⚠️ 可选，答全三层更稳 |
| 挂两物后结论不成立 | ✅ |
| 机制（含糊 + "应该是"） | 🔶 `--privileged` **不是"导致逃逸"，是当场拆掉闸门**；`docker.sock` 也**不需要漏洞**（指挥宿主 dockerd 起特权容器挂宿主 `/` = 合法提权） |
| 放大器效应 / `runAsNonRoot` | ⚠️ 只说"风险低"，没点出"**低 ≠ 安全，逃逸后不是普通用户而是宿主 root**" |

**背诵版（把这句背下来）**：容器里的 root 和宿主 root 是**同一个 uid 0**；风险低是因为内核做了**三道减法** —— namespace 让它看不见宿主、capability 只留 ~40 个能力位里的 **14 个**、seccomp 再过滤一批系统调用。但这三道都是减法，一旦绕过去（`--privileged` / `docker.sock` / 内核漏洞），进程**本来就是 uid 0**，后果不是普通用户而是**宿主 root** —— 所以才要 `runAsNonRoot`。

### Linux 题（进程题 · 僵尸）

> ① 一条命令列出所有僵尸进程（含 PID 与父 PID）；② 为什么 `kill -9` 杀不掉它？③ 真正应该怎么处理？

**参考答案**

| 问 | 答案 |
|---|---|
| ① | `ps -eo pid,ppid,stat,cmd \| awk '$3 ~ /^Z/'`（`STAT` 里的 `Z` = defunct）；等价写法 `ps -ef \| grep defunct`，或直接读 `/proc/<pid>/stat` 第 3 字段 |
| ② | 僵尸**已经死了**：不再运行、不占 CPU/内存，只剩内核里一条 `task_struct`（保存退出码等父进程来读）。信号只对"活着的进程"有意义 → `kill` 会返回成功，但状态永不改变 |
| ③ | **不能杀它，只能让父进程回收（`wait()`）**：① 父进程自己写好回收逻辑（`waitpid` / 处理 `SIGCHLD`）② 父进程不管 → **重启/杀掉父进程**，僵尸被 `init`(PID 1) 接管回收 ③ 重启宿主机是掩盖问题，不算处理 |

**和容器的联系（加分点）**：容器里 **PID 1 必须负责回收**，否则容器内会堆僵尸 —— Day 5 学的 `--init`（tini）就是干这个的；K8s 里 Pod 的 init 容器同理。

**我的复述（原文）**：`ps -aux` 看 STAT 列，为 `Z` 就是僵尸；再记住 PID 用 `ps -ef` 查父 PID。僵尸本身是个死进程，`kill -9` 强制杀也没用；真正的处理要么改代码让父进程 `wait` 子进程，要么让 init 收养它。

**批注（🔶 6/8）**

| 采分点 | 判定 |
|---|---|
| **一条命令**（含 PID 与 PPID） | ❌ 用了两步；且 PPID 本来就在输出里，不用再查（正确：`ps -eo pid,ppid,stat,cmd \| awk '$3 ~ /^Z/'`） |
| `STAT` 看 `Z` | ✅ |
| `kill -9` 无效的机制 | 🔶 差一句：**信号只对活着的进程有意义**；僵尸只剩内核一条 `task_struct`（存退出码等父进程读），不占 CPU/内存，只占一个 PID 槽位 |
| 父进程 `wait()` | ✅ |
| 让 init 收养 | 🔶 **缺前提**：内核只在**父进程退出之后**才交 PID 1 回收 → 实操就是**杀掉/重启那个父进程** |
| 加分：容器里 PID 1 必须 reap（`--init`） | ❌ 漏 |
| 顺带坑 | `ps aux`（BSD 风格）列不固定，**用户名长时 PID 列会错位** → 脚本里用 `ps -eo` / `ps -ef` |

**背诵版**：`ps -eo pid,ppid,stat,cmd \| awk '$3 ~ /^Z/'`。僵尸**已经死了**，只剩内核里一条 `task_struct` 等父进程读退出码，信号不可能作用在死进程上，所以 `kill -9` 无效。只能让**父进程 `wait()`**（改代码 / 处理 `SIGCHLD`）；父进程不干就**杀掉重启它**，让 PID 1 接管回收。容器里 PID 1 不 reap 就会堆僵尸 → 所以 `docker run` 要加 `--init`（tini）。
