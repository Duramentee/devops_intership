# Day 4 学习笔记 · 数据与网络

> 日期：2026-09-14
> 对应模块：`docs/k8s_in_action/01-容器与K8s入门.md` · `docs/docker/03-命令词典.md` §四（网络）/ §五（存储）
> 参考：`docs/docker/05-排障索引.md` · `docs/linux/Linux-故障索引.md`
> 代码目录：`code/week1/day4/`
> 模板：概念 / 命令 / 易错点 / 我的疑问

---

## 今日任务清单

| # | 任务 | 完成 |
|---|---|---|
| 1 | 可写层：写文件 → `rm -f` → 重建，数据没了 | ✅ |
| 2 | 命名卷：`-v webvol:/data`，数据还在 | ✅ |
| 3 | bind mount：宿主目录双向对比 | ✅ |
| 4 | tmpfs：容器停即失 | ✅ |
| 5 | 默认 bridge 解析**失败** → `mynet` **成功** | ⬜ |
| 6 | `mynet` 内不写 `-p`，用容器名访问服务 | ⬜ |
| 7 | 端口三视角：`docker port` / `ss -ltnp` / 容器内 `netstat` | ⬜ |
| 8 | 结论写进本笔记四段 | ⬜ |

> 存储（1~4）已闭环；网络（5~7）进行中。

---

## 实测记录

### 数据持久化对照

| 启动方式 | `docker rm -f` 后数据 | `docker restart` 后数据 | 谁管理生命周期 | 落点 |
|---|---|---|---|---|
| 不挂载（可写层） | **没了**（`No such file or directory`） | **还在**（实测 `hello`；`stop`+`start` 后同样在） | **容器对象** | 磁盘上的目录：老后端 `/var/lib/docker/overlay2/<id>/diff`；本机是 containerd snapshotter（见易错点） |
| `-v webvol:/data` | **还在**（`cat /data/x` → `v1`，容器 ID 已换新） | 在 | **卷对象（独立）**，`docker volume rm` 才删 | daemon 所在机器的 `/var/lib/docker/volumes/webvol/_data`（本机在 VM 里，⚠️ 见下方陷阱） |
| `-v $PWD/hostdir:/data` | **还在**（它就是宿主上的普通目录，跟容器无关） | 在 | **你 / 操作系统**（Docker 不管） | 宿主 `$PWD/hostdir` 本身 |
| `--tmpfs /tmp` | 没了（容器没了，挂载也没了） | **没了**（实测 `cat: can't open '/tmp/t'`） | 容器**本次启动**（内存） | kernel 的 **tmpfs**：`df` 显示 `tmpfs 5.8G`，`mount` 显示 `type tmpfs (rw,nosuid,nodev,noexec,relatime)` |

**A/B 铁证**：`restart` 同一容器 → `f14de7de…`（ID 不变）数据**在**；`rm` + `run` → `cb8920ae…` → `cb9ce3b1…`（**ID 换了**）数据**丢**。两次 ID 不同 = 新容器、新可写层。
⚠️ `docker diff` 要**在写完文件之后、删容器之前**跑才看得到 `A /data.txt`。

**⚠️ 环境陷阱：宿主上找不到 `/var/lib/docker`** —— 本机是 **Docker Desktop**，`dockerd` 跑在 **VM 里**，`Mountpoint` 是 **VM 内部**路径 → 宿主 `sudo ls` 必然报 `No such file or directory`。
→ 「卷 = 宿主上的目录」里的**「宿主」= 跑 dockerd 的那台机器**，不是你的本地 shell。
想看卷里文件：`docker run --rm -v webvol:/data alpine:3.22 ls -l /data`（通吃所有环境）。

### 网络对照

| 场景 | 现象 | 命令 |
|---|---|---|
| 默认 bridge，用容器名解析 | | |
| `mynet`，用容器名解析 | | |
| `mynet` 内访问 `http://w1:8080`（无 `-p`） | | |

### 端口三视角

| 视角 | 命令 | 输出 |
|---|---|---|
| 宿主侧监听进程 | `ss -ltnp \| grep 8081` | |
| 映射表 | `docker port web2` | |
| 容器内谁在听 | `docker exec web2 netstat -tlnp` | |

**踩坑记录：**

| 现象 | 我怎么判断的 | 解法 |
|---|---|---|
| | | |

---

## 步骤 1~3 总结 · 存储（可写层 / 命名卷 / bind mount）

### 一句话分清 / 怎么选

| 存储 | 谁管（谁记得这份数据） | **空目录时** | 什么时候用 |
|---|---|---|---|
| **可写层** | **容器对象** | — | 数据跟容器一起死就行 |
| **命名卷** | **Docker**（`docker volume rm`） | **预填充镜像内容** | 数据要比容器活得久、且让 Docker 统一管 |
| **bind mount** | **你 / 操作系统**（`rm -rf`） | **无条件遮盖** | 数据本来就在宿主（源码/配置），要边改边生效 |
| **匿名卷** | Docker（`rm -v` / `prune` 的清理对象） | 同命名卷 | 一般不用，易被连带删 |
| **tmpfs** | 容器**本次启动**（内存） | — | 密钥 / 临时缓存，绝不能落盘 |

### 关键证据（一句话各一条）

| 实验 | 结论 + 铁证 |
|---|---|
| 可写层 | 跟**容器对象**走，不跟进程 —— `restart` ID 不变数据在；`rm`+`run` ID 换了数据丢 |
| 命名卷 | **独立于容器** —— `rm -f` 后 `webvol` 还在；重建容器 `cat /data/x` → `v1` |
| bind | **同一份数据、不拷贝** —— 双向即时生效；空宿主目录挂 `/app` → `total 0` |
| 空卷 | **预填充镜像内容** —— `-v webvol2:/app` → `webapp` **8037381** 字节（= Day 3 那个二进制） |

### 实测：`dangling` 的判据

`7fe3c1c0…` 属于 **`kind-control-plane`**（已停止，`Exited (128)`）→ 它**不出现**在 `-f dangling=true` 里。
→ **`dangling = 没有任何容器（含已停止的）引用`**。
⚠️ **别删 `7fe3c1c0…`**：那是 kind 集群的数据卷，第 2 周要用。

---

## 抽背回执（Day 3 的坑）

| # | 判定 | 要点 |
|---|---|---|
| 1 | ✅ | 「隔离」而非「删除」：最终镜像 rootfs 从**最后一个 `FROM`** 算起，builder 层只在 build cache 里，`COPY --from` 是唯一通道 |
| 2 | 🔶 | `-p` 左=宿主、右=容器 ✅；`curl (56)` 未答 → 见下表 |
| 3 | 🔶 | `scratch` 代价只答出「没有 shell」；完整 = **shell / CA 证书 / tzdata**（+`/etc/passwd`）。补救已在 `notes/week1/day3.md`，本笔记不重复 |

---

## 排障速查：`curl` 退出码

→ 完整表见 `docs/docker/05-排障索引.md` §二「curl 退出码」（7/56/28/52/6 + 口诀 + 为什么 localhost 走 docker-proxy 会看到 56）。

**一句话版**：**7 = 找不到门；56 = 门开了但屋里没人；28 = 敲门没人应也没人拒；52 = 有人应了但一句话不说。**

---
## 预判对账（开场 5 条）

| # | 预判 | 判定 |
|---|---|---|
| 1 | 不挂载 → `rm -f` 后 `/data.txt` **不在** | ✅ |
| 2 | 挂 `webvol` 重建容器 → 数据**在** | ✅ |
| 3 | 默认 `bridge` 里解析 `n1` | ✅（重答：**报错** —— 没有名字服务） |
| 4 | `mynet` 里**不写 `-p`** → `wget http://w1:8080` | ✅（重答：**通** —— 同子网直连） |
| 5 | 宿主 `ss -ltnp \| grep 8081` 显示谁 → docker-proxy | ✅ |

> 3、4 首次未答，根因是**网络基础为零**（不知道「网桥」是什么）；补完即对。

---

## 网络核心模型（6 层一张表）

**起点**：net namespace 隔离的是**整套网络栈**（网卡 + 路由表 + ARP + 端口表 + iptables）。两个互相看不见的网络栈怎么通信？**用「线」连起来。**

| 层 | 类比 | 实体 | 机制 |
|---|---|---|---|
| 1 | 一根网线 | **veth pair** | 成对虚拟网卡：一端在容器（`eth0`），一端在宿主并**插在网桥上** |
| 2 | 一台交换机 | **Linux bridge**（`docker0` / `br-xxx`） | 纯二层、只认 MAC；它的「端口」就是插上来的 veth |
| 3 | 门牌 + 邮局 | **IP / 子网 / 网关 / 路由** | 网桥**自己也有 IP**（如 `172.17.0.1/16`）= 网关；容器从子网分到 `172.17.0.2` |
| 4 | 出小区的快递 | **SNAT（MASQUERADE）** | 出口链改**源**地址为宿主 IP → 容器才能上公网 |
| 5 | 小区门卫代收 | **DNAT（`-p`）** | 把「宿主:8081」的**目的**地址改写成「容器IP:8080」 |
| 6 | 通讯录 | **DNS** | 把「容器名」翻成 IP |

**三个必须记住的结论**

| # | 结论 |
|---|---|
| 1 | **宿主不是容器网络的「另一个端口」**，它是**通过网桥的 IP（= 网关）**参与这张网 |
| 2 | **名字解析**：默认 `bridge` **没有名字服务**；`--link` 是往 `/etc/hosts` **硬写一行**（静态、单向 → 被淘汰）；自定义网络靠容器内 `resolv.conf` 的 `nameserver 127.0.0.11` —— dockerd 的**内嵌 DNS**（不是真有个 DNS 进程，是 Docker 用 iptables **劫持**这个地址转给 dockerd），名字与容器**实时同步** |
| 3 | **`-p` 只服务于「外面/宿主 → 容器」**；容器之间同子网**直连**，不用 `-p` |

**两个方向、两张表**

| 方向 | 表 / 链 | 动作 | 改的是 |
|---|---|---|---|
| 容器 → 外网 | nat/**POSTROUTING** | SNAT | **源**地址 |
| 外网 / 宿主 → 容器 | nat/**PREROUTING + DOCKER** | DNAT | **目的**地址 |

**观测命令**

| 看什么 | 命令 |
|---|---|
| 网络细节（子网 / 网关 / 成员） | `docker network inspect bridge` / `mynet` |
| 网桥本身 | `ip -br addr show docker0` |
| 容器视角：路由 / DNS | `docker exec n1 ip route`；`docker exec n1 cat /etc/resolv.conf` |
| DNAT 规则（需 root） | `sudo iptables -t nat -L DOCKER -n` |
| 容器挂在哪些网络 | `docker inspect -f '{{json .NetworkSettings.Networks}}' n1` |

**失败模式**

| 现象 | 机制 | 先查 |
|---|---|---|
| 名字解析不出 | 该网络没有名字服务（默认 bridge） | `docker inspect -f '{{json .NetworkSettings.Networks}}' n1` |
| 能解析但连不上 | **名字通了 ≠ 服务在听** | `docker exec w1 netstat -tlnp` |
| 宿主 `curl localhost:8081` 不通 | DNAT / proxy 没写，或应用端口不对 | `docker port`；`ss -ltnp \| grep 8081` |
| 容器出不了网 | SNAT / 转发开关 | `iptables -t nat -L POSTROUTING -n`；`sysctl net.ipv4.ip_forward` |

---
## 每日一题（先自己写答案 → 再找人批改）

### 容器题 · 排障题

现象：「**重启容器后应用配置全丢**」。写出至少 3 个可能原因，每个配**验证命令**。

**我的答案：**

### Linux 题 · Day 4 shell（分词）

目录里有 `a b.txt`、`*star*`、`-dash`、`normal.log`，写 `for` 循环**逐个安全打印**：不漏文件、含空格的不被拆开、`-dash` 不被当成选项。

**我的答案：**

---

## 概念

> 学完填：可写层为什么丢数据、volume 与 bind mount 的本质区别、容器名解析是谁在干、`-p` 到底做了什么。

| 要点 | 用自己的话写一遍 |
|---|---|
| 可写层为什么随容器删除而消失 | ⚠️ 别再答「因为没持久化」—— 那是循环论证。真相：**可写层是磁盘上的真实目录**，生命周期跟**容器对象**绑定（**不跟进程**）；`docker rm` 删容器对象 → dockerd 把该目录一起删。正确因果 = **可写层和容器同生共死**。<br>**在哪 / 怎么证明**：它**不是** bind mount，而是 overlay **联合挂载**的 `upperdir`（lowerdir=镜像只读层，upperdir=可写层，merged=容器看到的 rootfs）。不用 `GraphDriver` 字段也能看到：<br>`docker run --rm webapp:v2 sh -c 'grep -o "upperdir=[^,]*" /proc/mounts'` ← **容器自己就把可写层的真实路径报出来了**<br>**和卷的形式像不像**：**都是宿主/VM 文件系统上的普通目录**，区别只在「归谁」—— 可写层按**容器 ID** 索引、只属于这一个容器（是 rootfs 的一层）；卷按**卷名**索引、可被多个容器同时挂（本质是把一块宿主目录 bind mount 进容器） |
| 命名卷的本质是什么（宿主上是什么） | 「宿主」= **跑 dockerd 的那台机器**上的一个目录（`/var/lib/docker/volumes/<名>/_data`），**不等于你的本地 shell**。本机是 Docker Desktop → 该目录在 **VM 内部**，宿主 `sudo ls` 报 `No such file or directory`。卷 = **Docker 管的独立对象**，只是「恰好」落在一个目录上；`Scope: local` = 只属于**单台 daemon**（这就是卷不能跨主机的原因） |
| volume vs bind mount 的区别 | ① **谁建**：卷是 Docker 建（`docker volume create` / 自动建），bind 是你 `mkdir` 的普通目录。② **谁管**：卷是 Docker 对象（`docker volume rm`），bind 归操作系统（`rm -rf`）。③ **空目录行为**：空卷会**预填充**镜像内容（实测 8037381 字节 = Day 3 那个二进制）；bind **无条件遮盖**（空目录就是空）。④ **可移植性**：卷能 `docker volume ls` 看到、由 Docker 管理；bind 路径写错会静默新建空目录、或**静默变成卷名**。⑤ **适用**：卷=生产数据；bind=开发时挂代码/配置 |
| `--rm` 对 volume / bind mount 分别有什么影响 | `--rm` 只删**容器**（以及它创建的**匿名卷**）。**命名卷**和 **bind 宿主目录**都不受影响，数据都还在 |
| 默认 bridge 为什么不能按容器名解析 | |
| 自定义网络的「内嵌 DNS」是谁在跑 | |
| `-p 8081:8080` 背后发生了什么（DNAT） | |
| 容器间通信需要 `-p` 吗？`-p` 服务于谁 | |
| 为什么说「容器内 8080」和「宿主 8081」是两个世界 | |

### 附：四层生命周期对照（`stop` / `restart` / `rm` 的分水岭）

> ⚠️ 关键区分：`docker run` = **新建一个容器**（新可写层）；`docker restart` = **重启同一个容器**（可写层原封不动）。把这两件事混成一件，就会得出「重启数据也没了」的错误结论。

| 对象 | 生命周期跟谁走 | `stop` / `start` | `restart` | `rm` | 删镜像 |
|---|---|---|---|---|---|
| 镜像**只读层** | 镜像 | 在 | 在 | 在 | **没了** |
| 容器**可写层** | **容器对象** | **在** | **在** | **没了** | 无关（容器已删） |
| **命名卷** | **独立**（除非 `docker rm -v`） | 在 | 在 | **在** | 在 |
| **bind mount** | **宿主目录**（跟谁都不绑） | 在 | 在 | **在** | 在 |
| **tmpfs** | **容器本次启动**（内存） | **没了** | **没了**（重挂空 tmpfs） | 没了 | — |
| 容器内**进程** | 进程 | 死 | 死 + 重启（新 PID 1） | 死 | — |

**类比纠正**：可写层**不是内存**。`docker stop` 像「人离开桌子」，**草稿纸（可写层）还在桌上**；`docker rm` 才是「把桌子搬走扔掉」。真正随进程消失的是**内存** —— `--tmpfs` 才接近这个比喻。

**`docker rm` vs `docker rm -f`**：容器在跑时 `docker rm` 会被 daemon 拒绝（`container is running: stop the container before removing or force remove`）；`-f` = 先对 PID 1 发 **SIGKILL**，再删容器对象。
→ 步骤 1 的 Q2 答案：`rm -f` 删**两样** —— ① 进程（SIGKILL）② 容器对象及其可写层（含日志、netns）；**镜像不碰**。

### 附：`--tmpfs` + 四种挂载的统一视角

**统一视角**：`-v` / `--tmpfs` / 不挂载，本质都是「给容器某个路径挂上一个东西」，差别只有两问 —— **那是什么？谁管它？** 除了 `--tmpfs` 在**内存**，其余全在**磁盘**上（都是宿主/VM 文件系统里的普通目录）。

**tmpfs 的两个坑 + 用途**

- `mount` 里的 **`noexec` 是默认的** → 把脚本/二进制放 `/tmp` 再跑会 `Permission denied`（即使有 `+x`）；要能执行得写 `--tmpfs /tmp:rw,exec`
- tmpfs 的写入**计入 cgroup 内存** → `docker run -m 512m --tmpfs /tmp` 写满会**触发 OOM Kill（137）**
- 用途：① 密钥/证书（不落盘）② 临时缓存 / 上传中转（不污染可写层）③ Unix socket 目录
- `Size 5.8G` = **可用内存的一半**（反推容器看到的内存 ≈ 11.6GB）

## 命令

| 场景 | 命令 | 说明 |
|---|---|---|
| 建卷 / 看卷 | `docker volume create webvol`；`docker volume ls` | `create` 返回**卷名** |
| 看卷落点 | `docker volume inspect -f '{{.Mountpoint}}' webvol` | 路径属于 **daemon 所在的机器**（Docker Desktop = VM 内，宿主看不到） |
| 卷里有什么（绕开宿主路径） | `docker run --rm -v webvol:/data alpine:3.22 ls -l /data` | **通吃所有环境**，推荐 |
| 往卷里写（避免 CMD 干扰实验） | `docker exec <容器> sh -c 'echo v1 > /data/x'` | 用 exec 写；CMD 只留 `sleep 600` |
| 看悬空卷 | `docker volume ls -f dangling=true` | 没被任何容器（含已停止）引用的卷 |
| 谁占着这个卷 | `docker ps -a --filter volume=<卷名或ID>` | 排查匿名卷归属 |
| 清悬空卷 | `docker volume prune` | 默认**只删匿名卷**（命名卷要 `-a`） |
| bind 双向验证 | `docker run --rm -v $PWD/hostdir:/data webapp:v2 cat /data/f.txt` | 宿主写 → 容器**立刻**可见 |
| 对照：bind **不拷贝** | `docker run --rm -v $PWD/emptydir:/app webapp:v2 ls -l /app` → `total 0` | vs 空卷 `-v webvol2:/app` → 有 `webapp` |
| 更安全的挂载写法 | `--mount type=bind,src=$PWD/hostdir,dst=/data` | 显式声明类型，无「被当卷名」歧义 |
| 临时内存盘 | `docker run --tmpfs /tmp webapp:v2 sh -c 'df -h /tmp; mount \| grep /tmp'` | 容器停/重启即失；默认带 **`noexec`** |
| 指定大小/权限 | `--tmpfs /tmp:rw,size=64m,mode=1777`（要能执行加 `exec`） | 默认 size = 内存一半 |

### 报错前缀 = 谁在说话

→ 完整表见 `docs/docker/05-排障索引.md` §三「报错前缀」。**本日实测三个**：`OCI runtime exec failed`（runc —— `cat` 打成 `car`）· `Error response from daemon`（dockerd —— 删运行中容器被拒）· `template parsing error`（本地 CLI —— `GraphDriver` 字段不存在）。

## 易错点

| 错法 | 现象 | 正确做法 |
|---|---|---|
| 以为 `docker restart` 也会丢数据 | 得出「可写层像内存，一停就没」的错误结论 | `restart` = **重启同一个容器**，可写层**原封不动**；`run` 才是**新建容器**。两者一混就得出错误因果 |
| 用 `docker inspect -f '{{.GraphDriver.Data.UpperDir}}'` 找可写层 | `template parsing error: ... map has no entry for key "GraphDriver"` | 这是**字段在你这套后端里不存在**（本机 Docker v28+ 用 **containerd 镜像存储**），不是命令写错。替代：`docker diff <容器>` / `docker info -f '{{.Driver}}'` / `sudo find /var/lib/docker/containerd -name '<文件>'` |
| 用 CMD 里带 `echo > /data.txt` 的容器测 restart | 看起来「数据还在」，其实是 PID 1 重启后**重新写了一遍**，实验无效 | 测持久化时，**文件要用 `docker exec` 从外面写**，CMD 只留 `sleep 600` |
| 以为 `docker volume prune` 会清掉命名卷 | 实测 `Total reclaimed space: 0B`，已悬空的**命名**卷 `webvol2` 还在（`docker volume ls -f dangling=true` 里仍在） | 默认**只删匿名卷**；要连命名卷一起删用 `docker volume prune -a` |
| 以为卷一定能宿主 `sudo ls /var/lib/docker/volumes/...` 看到 | `ls: cannot access ...: No such file or directory` | 本机 daemon 是 **Docker Desktop**（数据在 VM 里）；「宿主」= **跑 dockerd 的那台机器** |
| 用**相对路径**写 `-v hostdir:/data` | **静默创建了一个叫 `hostdir` 的命名卷**（`docker volume ls` 多一行），容器里 `/data` 是空的（`total 0`）—— 数据既不在宿主目录、也不在预期位置 | `-v` 的源**必须写绝对路径**（`$PWD/hostdir`）；**不以 `/` 开头 = 卷名**。更稳：`--mount type=bind,src=$PWD/hostdir,dst=/data` |
| 把要执行的脚本/二进制放进 `--tmpfs` 目录再运行 | `Permission denied`，即使文件有 `+x` | Docker 给 tmpfs 默认挂了 **`noexec`**（`mount` 输出里能看到）。要执行得显式覆盖：`--tmpfs /tmp:rw,exec` |

## 我的疑问

| # | 题目 | 考点 |
|---|---|---|
| | | |
