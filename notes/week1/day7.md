# Day 7 学习笔记 · 复盘 + 自测 + 上仓库

> 日期：2026-09-17 · 代码：`code/week1/day7/`
> 本周产出：`webapp:v1` 449MB → `v2` 25.3MB → `v3` 12.6MB（scratch）→ `v4` 25.3MB（加固、非 root）
> 题库：10 题混合自测（见第五节，先自己答，再给我批改）

---

## 一、今日速览（结论）

| # | 结论 |
|---|---|
| 1 | 本周产出可交付：`webapp:v4` **25.3MB / 非 root（uid 10001）/ (healthy)**；发布包在 `code/week1/day7/go-webapp/`（Dockerfile + .dockerignore + README），README 里的命令已实测可复现 |
| 2 | 10 题自测 **64/100**：机制基本没问题，失分在"说不全"与"命令语义记错" → **B 类错因升为复习优先级第一** |
| 3 | 知识资产成形：`docs/docker/` **4 篇词典** + `docs/00-知识点索引.md`（100 锚点全通）+ `notes/错题本.md`（48 条）|
| 4 | 第 1 周 **8/8 任务闭环**：最后一题（Linux 综合找 bug）**5/10**，三处 bug 只找到 2 处 —— 漏的是「**结果对但写法错**」那一类（UUOC），这类错自查时最难发现 |

---

## 二、任务清单

| # | 任务 | 完成 |
|---|---|---|
| 1 | 推之前自查 3 条命令 | ✅ 提交数 19（>7）；⚠️ 发现 5 个 PDF 被跟踪 → 已处理（`git rm --cached` + `.gitignore`） |
| 2 | 发布版 `Dockerfile` / `.dockerignore` / `README.md` | ✅ 在 `code/week1/day7/go-webapp/`（无教学注释的干净版） |
| 3 | 验收三件套（大小 / curl / 身份） | ✅ v4 25.3MB / `<h1>Hello DevOps</h1>` / `User=10001:10001` / `(healthy)` |
| 4 | 推到 GitHub | ✅ 今日 4 个提交（docs / notes / chore / feat）已推；`main` 与 `origin/main` 同步 |
| 5 | Linux 每日一题（Day 7 综合找 bug） | ✅ **5/10**（3 处 bug 找到 2 处，漏「无用 `cat`」）→ 第 1 周 **8/8 任务闭环** |
| 6 | 10 题混合自测 | ✅ 64/100，逐题批改见第五节 |
| 7 | 更新 `plan/求职学习计划.md` 勾选表 | ✅ 第 1 周 → ✅ 完成；§0 现状表同步 |
| 8 | 四段收尾 | 🔶 §一~§四 已由 AI 起稿，**需用自己的话过一遍** |

---

## 三、概念

（今天不学新概念，重点是把 Day 1~6 的机制**用自己的话串成一条线**：镜像怎么来 → 怎么跑起来 → 怎么不丢数据 → 怎么连上网络 → 出问题怎么看 → 怎么跑得更安全）

| 主题 | 一句话机制（我自己的话） |
|---|---|
| 容器是什么 | namespace（限制能看到什么）+ cgroup（限制能用多少）的普通进程，与宿主**共用内核**；PID 1 退出即容器退出 |
| 镜像分层与缓存 | 镜像 = 一组只读层；每条指令一层；缓存按 **cache key 链**（父层 key + 指令字符串 + 输入内容哈希）逐层比对，失效层之后全部重建 |
| 多阶段构建 | 多个 `FROM`，阶段之间只能 `COPY --from` 单向取文件；**只有最后一个阶段成为最终镜像** → 编译期内容隔离在外 |
| 数据持久化 | 可写层跟随**容器对象**；命名卷是独立对象；bind 就是宿主目录；tmpfs 在内存（`restart` 也丢） |
| 容器网络 | veth → 网桥 → IP/路由 → SNAT（出去改源）+ DNAT（进来改目的，即 `-p`）→ DNS；**容器之间同子网直连，不需要 `-p`** |
| 排障顺序 | 在不在 → 怎么退出（退出码/`State.Error`）→ 日志 → 环境 → 资源；再加一步**“谁杀的”用 `docker events`** |
| 权限与加固 | 权限 = uid + capability 位图；非 root 时 `Prm`/`Eff` = 0，`--cap-add` 只进 `Bnd`；加固四件套 = 非 root + 无工具链/源码 + 最小能力 + 只读根 |

---

## 四、命令 / 易错点（一周汇总）

### 命令表（把这一周最该记住的 10 条塞进来）

| 场景 | 命令 | 说明 |
|---|---|---|
| 看每层多大 / 找体积大户 | `docker history webapp:v1` | 每条指令一行；`<missing>` 不是错误 |
| 看退因（排障主力） | `docker inspect 名 -f '{{.State.ExitCode}} oom={{.State.OOMKilled}} {{.State.StartedAt}} → {{.State.FinishedAt}}'` | 一次拿齐四个字段 |
| 查"谁杀的" | `docker events --since <Start> --until <现在>` | ⚠️ `--until` **不能用** `FinishedAt` |
| 查已退出的容器 | `docker run --rm -it --entrypoint sh 镜像:tag`；`docker cp 名:/路径 /tmp/` | 已退出时 `exec`/`top` 不可用，`stats` 返回 `0B/0B` 假数据 |
| 实时资源 | `docker stats --no-stream` | 读 cgroup 统计；只对运行中容器有效 |
| 看能力位图 | `docker run --rm --entrypoint grep 镜像 ^Cap /proc/self/status` | `Eff` = 当前生效，`Bnd` = 能力上限 |
| 加固运行 | `docker run -d --cap-drop=ALL --read-only --tmpfs /tmp -p 8080:8080 webapp:v4` | 最小能力 + 只读根 |
| 查镜像内有无源码/密钥 | `docker run --rm --entrypoint find 镜像 / -name '*.go'`；`docker inspect -f '{{json .Config.Env}}' 镜像` | 不依赖容器运行状态与镜像内工具 |
| 端口三视角 | `docker port 名`；`docker exec 名 netstat -tlnp`；`sudo ss -ltnp \| grep <端口>` | `docker port` 是**左容器 / 右宿主**，与 `-p` 顺序相反 |
| 清理 | `docker container prune` + `docker image prune`（或 `docker system prune`） | `prune` **不涉及卷**；被容器引用的镜像不会删 |

### 易错点 Top 5（这一周踩过的）

| # | 坑 | 现象 | 正确做法 |
|---|---|---|---|
| 1 | 把"构建期 / 运行期"混为一谈 | 用 overlay2 解释缓存失效；在 `RUN` 里建运行期文件 | 缓存 = cache key 链（构建期）；overlay2 = 层挂载（运行期）。**先问一句：这是哪个阶段的事** |
| 2 | 命令语义记错（本轮最多） | `docker top` 当容器内 PID；`--until` 用 `FinishedAt`；以为 `prune` 会删卷/删在用镜像 | 命令表逐条核对；破坏性命令先 `docker system df` 预检 |
| 3 | 把"不装 handler 的信号被忽略"当通用规律 | 推出"没 handler 就该 143" | 该保护**只对 PID 1 成立**：非 PID 1 → 143；Go 做 PID 1 → 2；`sh`/`sleep` 做 PID 1 → 超时 137 |
| 4 | 用默认值做实验 | 绑 80 四组全成功，结论无效；默认容器里 443 也能绑 | 实验前后读 sysctl 基线值（`ip_unprivileged_port_start`、`ping_group_range`） |
| 5 | 只答一层机制 | "容器 root 风险低"只答 capability；`scratch` 代价只答"没 shell" | 三层限制（namespace / capability / seccomp）；四项代价（shell / CA / tzdata / passwd） |
| 2 | | | |
| 3 | | | |
| 4 | | | |
| 5 | | | |

---

## 五、10 题混合自测（先自己答，答完发我批改）

### 概念题

**Q1（容器本质）** 容器和虚拟机最本质的区别是什么？由此能推出哪两个**可观测现象**（提示：宿主机 `ps` 里看不到？容器里的 PID 1 在宿主上是几号、怎么查）？

> 我的答案：容器没有guest内核和宿主机通用一个操作系统内核, 而虚拟机则是有自己的内核, 在宿主机ps看不到容器中的进程, 容器PID1在宿主机上是几号不可确定, 用docker  top查容器内进程信息

**Q2（多阶段构建）** 多阶段构建里 builder 阶段的内容为什么**不会**进入最终镜像？`scratch` 底座里没有 shell，这会影响哪些 Dockerfile 指令（举 2 个），怎么补救？

> 我的答案：docker构建采用分层形式, 使用from时中间构建产物除了指定copy都不会进入最终构建产物, 没有shell docker run就不能用shell form, 同时依赖shell的指令都不能执行导致可运维性不佳, 可以采用容器设计模式比如加入一个新容器进入同namespace中, 用新容器调试, 或者是给镜像里加入一个busybox, 牺牲一点体积换取一个shell

**Q3（权限模型）** 给一个具体对比：**同样是 uid=0**，A 容器能绑 80、B 容器被拒。用能力位解释差异。再答：**非 root 时 `--cap-add=NET_BIND_SERVICE` 为什么不生效**（哪个字段变了、哪个字段没变）？

> 我的答案：capability不同导致产生了差异, docker默认最小保留端口是0, A容器没有做覆盖, B容器可能执行了–drop-all, 导致所有能力位被丢弃, 并且没有改变sysctl, 不生效原因:即使加了能力位, 位图也没变, CapBnd变了, 其他的字段没变(忘了叫什么了)

**Q4（加固四件套）** 写出你的 Dockerfile 加固清单（≥4 条），并**每一条配一条证明命令**（证明它真的生效了，不是"我写了"）。

> 我的答案：1. 指定USER 10001:10001 设置用户和组为非root, 写.dockerignore, 缩小镜像体积(比如过滤掉.log .env /src /secure dockerfile等文件和目录), 2. 并且不让本地产物污染生产环境 3. 设置最小权限, 限制容器内用户能力范围防止权限过大逃逸 4. –cap-drop-all 把所有能力弃置, 然后再–cap-add按需添加需要的能力

### 现象题

**Q5（构建缓存）** `docker build` 时前面几层显示 `CACHED`、到 `RUN go build` 突然重新执行。这说明什么？如果要求"改代码只重建 1 层"，Dockerfile 里的指令顺序应该是什么样？

> 我的答案：这个我也不清楚, 到这一层突然重新执行, 从三个角度来讲好像都不太对, 父cache key没变, 本层指令字符串没变, 本层也没有文件内容那按理说也不会变, 这三个角度来看不变才对. 指令顺序应当尽可能让变化频繁的后延, 相对稳定的放在前面, 比如 main.go 最好就放在 go.mod 以及 go mod download之后, 

**Q6（退出码）** 容器 `Exited (137)` 与 `Exited (143)` 分别意味着什么？为什么 137 对"优雅关闭"是**坏消息**？再给出一条命令看"是不是被 OOM 杀的"。

> 我的答案：137意味着被sigkill杀死, 143意味着由于sigterm退出, , 137是被内核发来的sigkill强行杀死的, 他在这时候可能还在处理一些请求, 或者是还有日志没写完, 有工作没做, 强行被杀死会导致数据丢失, 甚至错误, 肯定不优雅, 先用docker inspect 查OOMKilled词条, 看是否是oom杀的, 之后可以看看–docker events --since <Start> --until <Finish>算一下时间, 如果和超时时间差不多那大概是被137杀了(但不一定能确定是oom导致的kill), 最后上内核看看journalctl查一查内核有没有oom日志

**Q7（起不来）** 容器一启动就 `Exited (1)`。写出你的排查顺序（≥3 步），并解释：**为什么不能第一步就 `docker exec` 进去看**？

> 我的答案：排障要按照 看容器还在跑吗-怎么退出的-日志-环境-资源 这五个顺序来查, 第一步直接docker exec肯定是不可行, Exited (1) 那大概是容器内应用错误退出了, 所以此时容器肯定是停摆状态, 执行exec是跑不起来的, 得先确定容器是否还在运行

### 命令题

**Q8** 各写一条命令：① 看镜像每层多大 ② 看运行中容器的实时 CPU/内存 ③ 看镜像里有没有混进源码（`.go`）或密钥。

> 我的答案：1. docker history 2. docker stats 3. docker exec container-name ls -l /src

**Q9** 各写一条命令：① 列出所有容器（含已退出的）② 看某次退出的退出码与结束时间 ③ 清理所有停止的容器 + 悬空镜像（并说明 `prune` 的分寸）。

> 我的答案：1. docker ps -a  2. docker inspect {{.State.ExitCode}} {{.State,FinishedAt}} 3. docker image prune, 不带a的情况不会删除有容器占用的卷, 即使这个容器没有在跑也不会删除, -a会删除所有即使在跑也是

**Q10（存储与网络）** ① `-v webvol:/data` 与 `-v /host/dir:/data` 的区别是什么，`--rm` 对两者的影响各是什么？② 为什么自定义网络 `mynet` 里能用**容器名**互相访问，默认 bridge 不行？

> 我的答案：1.前者是创建一个命名卷, 后者是bind mount, 没什么影响, 即使加入–rm删除容器对象, 这两者中的数据都不会丢失, 2.自定义网络会由docker自动加入一个dns服务, 可以使用名字在子网内互访也可以用ip互访, 默认bridge则是只能用ip互访不能用名字互访

### 批改结果（**64 / 100**，通过线 70）

| 题 | 判定 | 得分 | 关键修正 |
|---|---|---|---|
| Q1 容器本质 | ❌ | 4/10 | 两个可观测现象**答反**：宿主 `ps` 是**能**看到容器进程的（它就是宿主上的普通进程）；容器 PID 1 在宿主上的 PID **可以**查到：`docker inspect -f '{{.State.Pid}}' 名`。另：`docker top` 显示的是**宿主视角** PID（容器视角用 `docker exec 名 ps aux`） |
| Q2 多阶段 + scratch | 🔶 | 7/10 | 机制（隔离而非删除）与两种补救（同 namespace 调试容器、塞 busybox）都对；受影响指令要写具体：`RUN`、`CMD`/`ENTRYPOINT` 的 shell form、`HEALTHCHECK` 的 shell form（都要 `/bin/sh -c`） |
| Q3 权限模型 | ✅ | 8/10 | 抓到了两条依据：阈值 = 0 + `--drop-all` 使位图清零；字段名要记住 **`CapPrm` / `CapEff`**（变的那一个是 `CapBnd`） |
| Q4 加固四件套 | 🔶 | 5/10 | 清单基本齐（缺 `--read-only --tmpfs`），但**"每条配证明命令"全部没写** —— 这正是本周强调的"怎么验证" |
| Q5 构建缓存 | 🔶 | 6/10 | 指令顺序部分对；现象要说成"**它上游某一层的输入变了**"（`CACHED` 只显示到断点为止，不是被指示的那层出问题） |
| Q6 退出码 | 🔶 | 7/10 | 137/143 与"为何不优雅"都对；两处修正：`--until` **不能用** `FinishedAt`；本机 dockerd 在 VM 内，查内核 OOM 要 `docker run --rm --privileged --pid=host alpine dmesg \| grep -i oom` |
| Q7 起不来 | 🔶 | 7/10 | 五步顺序与"为何不能先 `exec`"都对；缺具体命令：`docker ps -a` → `docker logs --tail 200` → `--entrypoint sh` 复跑 |
| Q8 命令 | 🔶 | 6/10 | ①②对；③ 建议用不依赖容器运行状态与镜像内工具的方式：`docker run --rm --entrypoint find 镜像 / -name '*.go'` |
| Q9 命令 | 🔶 | 5/10 | ② 语法错（缺 `-f` 与引号；`.State,FinishedAt` → `.State.FinishedAt`）；③ `prune` 分寸说错（**不删卷**；`-a` **不会**删运行中容器引用的镜像） |
| Q10 存储与网络 | ✅ | 9/10 | 全对；补充：内嵌 DNS 是 dockerd 在 `127.0.0.11` 应答（不是独立 DNS 进程） |

> **失分结构**：机制类只有 Q1（现象答反）与 Q5（现象解释）；其余全部是"说不全"与"命令记错"。→ 理解到位，缺的是**输出精度**。
> 错答已全部追加进 `notes/错题本.md`：**D32~D39**（并将 B 类提到复习优先级第一）。

### Linux 每日一题 · Day 7 综合找 bug（**5 / 10**）

**原题**

```bash
for f in $(ls /data); do cp $f /backup/; done
cat /var/log/nginx/access.log | awk '{print $1}' | uniq -c | sort -rn | head
```

| 项 | 满分 | 得分 | 说明 |
|---|---|---|---|
| ① 定位分词 bug | 3 | 2 | 位置对（`$(ls)`），但把原因归给"文件名里有空格"这个**事实**，而不是"shell 在切分"这个**动作** |
| ① 机制说清 | 2 | 0.5 | 没答：谁切（shell）、按什么切（`IFS`）、"`$f` 未加引号"是**第二处**独立切分点 |
| ② 效率 bug（`cat \| awk`） | 2 | 0 | **完全没发现**，改完的命令里还留着 `cat` |
| ③ 缺 `sort` | 2 | 2 | 定位 + 改法都对 |
| ③ 机制说清（只比相邻行） | 1 | 0.5 | 只说了"必须 sort"，没说 `uniq` 的限定条件 |
| **合计** | 10 | **5** | 三处 bug 找到 2 处 |

**标准答案**

| 原文 | bug | 改法 |
|---|---|---|
| `for f in $(ls /data)` | 命令替换结果被 **`IFS` 分词**；`ls` 还**漏掉 `.` 开头的隐藏文件** | `for f in /data/*`（glob 展开发生在分词**之后**，结果不再被切） |
| `cp $f /backup/` | ① `$f` 未加引号 → **第二次**分词 ② `$f` 是**相对名**，隐含要求 cwd 恰为 `/data` ③ 名字以 `-` 开头会被 `cp` 当成选项 | `cp -- "$f" /backup/`；改成 glob 后 `$f` 已是 `/data/xxx` **全路径**，②③ 一并解决 |
| （缺守卫） | 无匹配时 glob 保留字面量 `/data/*`，会对不存在的文件执行 `cp` | `[ -e "$f" ] \|\| continue` |
| `cat 文件 \| awk ...` | 冗余 `cat`（**UUOC**） | `awk '{print $1}' /var/log/nginx/access.log \| ...` |
| `... \| uniq -c \| sort -rn` | `uniq` **只合并相邻行** → 同一个 IP 出现多行 | `... \| sort \| uniq -c \| sort -rn \| head`，或 `awk '{c[$1]++} END{for(i in c) print c[i], i}'`（只排一次） |

**健壮版（加分题 B）**：不依赖 glob、能处理上万文件、`-` 开头也对

```bash
find /data -mindepth 1 -maxdepth 1 -print0 |
  while IFS= read -r -d '' f; do cp -- "$f" /backup/; done
```

| 参数 | 作用 |
|---|---|
| `-mindepth 1 -maxdepth 1` | 只要 `/data` 的**直接子项**，不递归（对应 `ls /data`；但 `find` **包含**隐藏文件） |
| `-print0` | 用 **NUL** 分隔输出 —— NUL 是唯一不能出现在文件名里的字符 → 从根上消灭分词 |
| `read -r -d ''` | `-d ''` = 以 NUL 为分隔；`-r` = 不把 `\` 当转义 |
| `IFS=`（前缀） | `read` 默认会裁掉首尾空白，置空 `IFS` 才能原样读入 |

> **一句话记法**：`ls` 的输出是**给人眼看的文本**，不是**给程序用的列表**。要文件名列表 → glob 或 `find -print0`。

---

## 六、我的疑问（带进第 2 周）

1. Day 6 留下的：K8s 里 `securityContext.capabilities.add` 给非 root 容器加能力，是否同样无效？
2. Docker 的 `HEALTHCHECK` 在 K8s 里被忽略 → 探针写在哪一层（liveness/readiness）？
3. `USER` 不设 `HOME`，Go 程序 `os.UserHomeDir()` 会拿到什么？
4. |

---

## 七、一周复盘（面试话术草稿）

> 目标：把这一周讲成 **90 秒**的故事（面试官只想听"你解决了什么问题、怎么验证的"）。

| 段 | 内容 | 我的草稿 |
|---|---|---|
| 起点 | 一个能跑的 Go 服务 + 单阶段 Dockerfile 449MB | 起点是一个能跑的 Go HTTP 服务，单阶段镜像 449MB —— Go 工具链和构建缓存都留在了层里 |
| 问题 1 | 交付太慢 / 体积太大 → 分层顺序 + 多阶段 + scratch | 先调指令顺序把依赖层拆出来，再用多阶段构建把编译与运行分开（25.3MB）；又试了 `scratch`（12.6MB），但它没有 shell 和 CA 证书，排障与 HTTPS 出站不可用，最终选 alpine 折中 |
| 问题 2 | 排障没套路 → 退出码 + 5 步定位法 | 做了 11 组退出码实验，发现 `docker stop` 的结局由「PID 1 是谁 + 装没装 handler」决定 —— 143 反而最少见，不装 handler 是 137，Go 还会回退成 2；于是 `CMD` 改 exec form 并在代码里注册信号处理 |
| 问题 3 | 安全扫描会挂 → 非 root + 无工具链 + 最小能力 + 只读根 | 改成非 root（uid 10001）、`--cap-drop=ALL`、`--read-only --tmpfs`，并做了镜像内容检查（无源码、无 setuid）；**加固不增加体积** —— 元数据指令不产生层 |
| 结果 | 25.3MB / 非 root / `(healthy)` / README 可复现 | 最终镜像 25.3MB、非 root、`(healthy)`；发布包的 README 里的构建/运行/验证命令均已实测可复现 |
| 证据 | GitHub commit 历史 + `docker history` 截图 | GitHub 提交历史 + `docker history` + `docker images` 的四个版本体积对照 |

### 90 秒完整话术（练三遍再看表）

> 第一周的目标是把一个 Go 服务容器化并交付。起点是一个能跑的服务和一份单阶段 Dockerfile —— 镜像 449MB，因为 Go 工具链和构建缓存都留在了层里。
>
> 我先调指令顺序，把依赖列表单独一层；再用多阶段构建把编译和运行分开，降到 25.3MB。又试了 `scratch` 底座，能到 12.6MB，但它没有 shell 和 CA 证书，排障和 HTTPS 出站都不可用，所以最终选了 alpine。
>
> 第二块是排障。我做了 11 组退出码实验，发现 `docker stop` 的结局由「PID 1 是谁 + 装没装 handler」决定：143 反而最少见，不装 handler 是 137，Go 程序做 PID 1 还会回退成 2。据此把 `CMD` 改成 exec form，并在应用里注册了信号处理。
>
> 第三块是加固：非 root（uid 10001）、`--cap-drop=ALL`、只读根文件系统，并验证了镜像里没有源码、工具链和 setuid 文件。加固后体积没变 —— 因为 `USER`、`EXPOSE` 这些是元数据指令，不产生层。
>
> 所有证据都在 GitHub 的提交历史和 `docker history` 里，README 可以直接复现构建与验证步骤。
