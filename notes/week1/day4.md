# Day 4 · 数据持久化与容器网络

> 日期：2026-09-14 · 代码：`code/week1/day4/`（`emptydir/`、`hostdir/`）· 原笔记备份：`/tmp/day4-notes-backup.md`
> 关联文档：`docs/docker/02-命令词典.md` §四（网络）/ §五（存储）· `docs/docker/04-排障索引.md` · `docs/linux/Linux-故障索引.md`
> 环境：Docker Desktop（dockerd 运行在 **VM** 内）· Docker v28 + containerd 镜像存储

---

## 1. 结论速览

| # | 结论 |
|---|---|
| 1 | **可写层跟随"容器对象"，不跟随进程**：`docker restart` 数据仍在；`rm` + `run` 数据丢失（两次容器 ID 不同，即新容器、新可写层） |
| 2 | **命名卷是 Docker 的独立对象**，`rm -f` 容器不影响它；**bind mount 就是宿主机上的普通目录**，Docker 不管理其生命周期 |
| 3 | **空卷会预填充镜像内容；bind mount 只是遮盖、不拷贝** —— 这两条最容易混 |
| 4 | **默认 bridge 没有名字服务**（`NXDOMAIN`）；自定义网络由 dockerd 内嵌 DNS（`127.0.0.11`）提供。⚠️ 但默认 bridge **按 IP 仍可互访** |
| 5 | **`-p 8081:8080` 本质是一条 DNAT 规则**：`宿主机:8081 → 容器IP:8080`（已实测到规则），另有 `docker-proxy` 处理 localhost 路径 |
| 6 | **本机是 Docker Desktop**：dockerd 在 VM 内 → 宿主看不到 `/var/lib/docker`、没有 `iptables`、`ss -ltnp` 看不到端口属主 |

---

## 2. 机制

### 2.1 可写层的本质与生命周期

可写层**不是内存**，而是磁盘上的一个真实目录：它是 overlay **联合挂载**的 `upperdir`（`lowerdir` = 镜像只读层，`upperdir` = 可写层，`merged` = 容器看到的 rootfs）。

| 问题 | 答案 |
|---|---|
| 为什么随容器删除而消失 | 它的生命周期绑定**容器对象**（不绑定进程）：`docker rm` 删除容器对象时，dockerd 把该目录一并删除 |
| 怎么看到它的真实路径 | 容器自己就能报告：`docker run --rm webapp:v2 sh -c 'grep -o "upperdir=[^,]*" /proc/mounts'` |
| 为什么不能用 `GraphDriver` 字段查 | 本机是 containerd 镜像存储，该字段不存在（报 `map has no entry for key "GraphDriver"`），不是命令写错；用 `docker diff` / `docker info -f '{{.Driver}}'` 替代 |
| 它和卷的形式是否相像 | 都是宿主/VM 文件系统上的普通目录。区别在归属：可写层按**容器 ID**索引、只属于该容器且是 rootfs 的一层；卷按**卷名**索引、可被多个容器同时挂载 |

### 2.2 四种挂载方式对照

| 存储 | 谁管理生命周期 | 空目录时的行为 | 适用场景 |
|---|---|---|---|
| **可写层** | 容器对象 | — | 数据与容器同生共死即可 |
| **命名卷** | Docker（`docker volume rm`） | **预填充镜像内容** | 数据要比容器活得久，且希望由 Docker 统一管理 |
| **bind mount** | 用户 / 操作系统（`rm -rf`） | **无条件遮盖** | 数据本来就在宿主机（源码 / 配置），需要边改边生效 |
| **匿名卷** | Docker（`rm -v` / `prune` 可清理） | 同命名卷 | 一般不主动使用，容易被连带删除 |
| **tmpfs** | 容器**本次启动**（内存） | — | 密钥、临时缓存，不允许落盘 |

**四层生命周期对照（`stop` / `restart` / `rm` 的分界）**

| 对象 | 生命周期跟谁走 | `stop` / `start` | `restart` | `rm` | 删镜像 |
|---|---|---|---|---|---|
| 镜像**只读层** | 镜像 | 在 | 在 | 在 | **消失** |
| 容器**可写层** | **容器对象** | 在 | 在 | **消失** | 无关（容器已删） |
| **命名卷** | 独立（除非 `docker rm -v`） | 在 | 在 | 在 | 在 |
| **bind mount** | 宿主目录 | 在 | 在 | 在 | 在 |
| **tmpfs** | 容器本次启动（内存） | **消失** | **消失**（重新挂载空 tmpfs） | 消失 | — |
| 容器内**进程** | 进程 | 结束 | 结束 + 重启（新 PID 1） | 结束 | — |

⚠️ 关键区分：`docker run` = **新建容器**（新可写层）；`docker restart` = **重启同一个容器**（可写层不变）。把两者混为一件事，就会得出"重启数据也会丢"的错误结论。

### 2.3 `docker rm` / `docker rm -f` 删除的内容

| 命令 | 行为 |
|---|---|
| `docker rm`（容器运行中） | 被 daemon 拒绝：`container is running: stop the container before removing or force remove` |
| `docker rm -f` | 先对 PID 1 发 **SIGKILL**，再删除容器对象及其可写层（含日志、netns）；**不涉及镜像** |

### 2.4 容器网络模型

起点：net namespace 隔离的是**整套网络栈**（网卡 + 路由表 + ARP + 端口表 + iptables）。两个互相不可见的网络栈如何通信？**用虚拟链路连接起来。**

| 层 | 实体 | 机制 |
|---|---|---|
| 1 | **veth pair** | 成对虚拟网卡：一端在容器内（`eth0`），另一端在宿主机并**插在网桥上** |
| 2 | **Linux bridge**（`docker0` / `br-xxx`） | 二层转发，只识别 MAC；它的"端口"就是插上来的 veth |
| 3 | **IP / 子网 / 网关 / 路由** | 网桥本身也有 IP（如 `172.17.0.1/16`），即容器看到的网关；容器从该子网分配到 `172.17.0.2` |
| 4 | **SNAT（MASQUERADE）** | 出口链改写**源**地址为宿主 IP → 容器才能访问公网 |
| 5 | **DNAT（`-p`）** | 把"宿主机:8081"的**目的**地址改写为"容器IP:8080" |
| 6 | **DNS** | 把容器名解析成 IP |

**三个必须记住的结论**

| # | 结论 |
|---|---|
| 1 | 宿主机不是容器网络的"另一个端口"，它是**通过网桥的 IP（即网关）**参与这张网 |
| 2 | **名字解析**：默认 `bridge` 没有名字服务；`--link` 是往 `/etc/hosts` **静态写入一行**（单向、已淘汰）；自定义网络依赖容器 `resolv.conf` 中的 `nameserver 127.0.0.11` —— dockerd 的**内嵌 DNS**（不是独立 DNS 进程，而是 Docker 用 iptables 劫持该地址转给 dockerd），名字与容器**实时同步** |
| 3 | **`-p` 只服务于「宿主机/外部 → 容器」**；容器之间同子网**直连**，不需要 `-p` |

**两个方向、两张表**

| 方向 | 表 / 链 | 动作 | 改动字段 |
|---|---|---|---|
| 容器 → 外网 | nat/**POSTROUTING** | SNAT | **源**地址 |
| 外部 / 宿主 → 容器 | nat/**PREROUTING + DOCKER** | DNAT | **目的**地址 |

### 2.5 名字解析：默认 bridge 与自定义网络的差别

| 网络 | 容器 `/etc/resolv.conf` 的 nameserver | 注释中的线索 |
|---|---|---|
| 默认 `bridge` | `192.168.65.7` | `(legacy)` —— 直接沿用宿主（Docker Desktop VM）的 DNS，**没有名字服务** |
| `mynet` | **`127.0.0.11`** | `(internal resolver)` + `ExtServers: [host(192.168.65.7)]` + `options ndots:0` —— dockerd 的内嵌解析器，非本网络的域名转发给上游 |

### 2.6 `-p 8081:8080` 的实质

实测规则（在 VM 的 netns 中查到）：`Chain DOCKER (2 references)` → `DNAT tcp dpt:8081 to:172.17.0.2:8080` —— 即"目的为宿主 `8081` 的包，把目的地址改写为容器 IP 的 `8080`"。`(2 references)` 说明该链被引用两次（`PREROUTING` 处理外部流量 + `OUTPUT` 处理本机/localhost 流量）。此外 dockerd 会让 **`docker-proxy`** 在宿主端口上真实 listen，负责 iptables 处理不好的路径（这也是 localhost 访问失败时报 `curl: (56)` 而非 `(7)` 的原因）。

**容器内的 8080 与宿主的 8081 属于两个 net namespace**：前者是应用 listen 的端口，后者是 DNAT 规则 + docker-proxy 的入口。

### 2.7 tmpfs 的两个特性

| 特性 | 说明 |
|---|---|
| 默认带 `noexec` | 把脚本/二进制放进 `/tmp` 再执行会 `Permission denied`（即使有 `+x`）；需要执行时写 `--tmpfs /tmp:rw,exec` |
| 写入计入 cgroup 内存 | `docker run -m 512m --tmpfs /tmp` 写满会触发 OOM Kill（137）；实测 `df` 显示 `Size 5.8G` = 可用内存的一半 |

---

## 3. 命令

| 场景 | 命令 | 说明 |
|---|---|---|
| 建卷 / 看卷 | `docker volume create webvol`；`docker volume ls` | `create` 返回**卷名** |
| 看卷落点 | `docker volume inspect -f '{{.Mountpoint}}' webvol` | 该路径属于 **daemon 所在的机器**（Docker Desktop 在 VM 内，宿主看不到） |
| 查看卷内容（绕开宿主路径） | `docker run --rm -v webvol:/data alpine:3.22 ls -l /data` | 通用于所有环境 |
| 往卷里写（避免 CMD 干扰实验） | `docker exec <容器> sh -c 'echo v1 > /data/x'` | 用 exec 写，CMD 只保留 `sleep 600` |
| 看悬空卷 | `docker volume ls -f dangling=true` | 没有被任何容器（含已停止）引用的卷 |
| 查某个卷被谁占用 | `docker ps -a --filter volume=<卷名或ID>` | 排查匿名卷归属 |
| 清悬空卷 | `docker volume prune` | 默认**只删匿名卷**（命名卷需 `-a`） |
| bind mount 双向验证 | `docker run --rm -v $PWD/hostdir:/data webapp:v2 cat /data/f.txt` | 宿主写入 → 容器立即可见 |
| 对照：bind 不拷贝 | `docker run --rm -v $PWD/emptydir:/app webapp:v2 ls -l /app` → `total 0` | 对比空卷 `-v webvol2:/app` → 有 `webapp`（8037381 字节） |
| 更安全的挂载写法 | `--mount type=bind,src=$PWD/hostdir,dst=/data` | 显式声明类型，无"被当作卷名"的歧义 |
| 临时内存盘 | `docker run --tmpfs /tmp webapp:v2 sh -c 'df -h /tmp; mount \| grep /tmp'` | 容器停止/重启即失效；默认带 `noexec` |
| 指定大小 / 权限 | `--tmpfs /tmp:rw,size=64m,mode=1777` | 默认 size 为内存的一半 |
| 发布端口 | `docker run -d -p 8081:8080 --name d4p webapp:v2` | **左 = 宿主机，右 = 容器** |
| 看映射表 | `docker port d4p` | `8080/tcp -> 0.0.0.0:8081`（左 = 容器、右 = 宿主，与 `-p` 顺序相反） |
| 查宿主侧监听 | `sudo ss -ltnp \| grep 8081` | 本机（Docker Desktop）加 `sudo` 也看不到属主，只有 `LISTEN *:8081` |
| 查容器内监听 | `docker exec d4p netstat -tlnp` | `:::8080 LISTEN 1/webapp`（`:::` = IPv6 通配 + 双栈，同时收 IPv4） |
| 自定义网络内按名字访问 | `docker run --rm --network mynet alpine:3.22 wget -qO- http://w1:8080` | 不需要 `-p` |
| 看网络细节 | `docker network inspect mynet`；`ip -br addr show docker0` | 子网 / 网关 / 成员 / 网桥地址 |
| 看容器挂在哪些网络 | `docker inspect -f '{{json .NetworkSettings.Networks}}' n1` | 排查"名字解析不出"的第一步 |

---

## 4. 实测数据（原始输出）

### 4.1 持久化对照

| 启动方式 | `docker rm -f` 后数据 | `docker restart` 后数据 | 谁管理生命周期 | 落点 |
|---|---|---|---|---|
| 不挂载（可写层） | **丢失**（`No such file or directory`） | **仍在**（`hello`；`stop`+`start` 同样在） | **容器对象** | 磁盘目录：老后端 `/var/lib/docker/overlay2/<id>/diff`；本机为 containerd snapshotter |
| `-v webvol:/data` | **仍在**（`cat /data/x` → `v1`，容器 ID 已更换） | 在 | **卷对象（独立）**，`docker volume rm` 才删 | daemon 所在机器的 `/var/lib/docker/volumes/webvol/_data` |
| `-v $PWD/hostdir:/data` | **仍在** | 在 | 用户 / 操作系统 | 宿主 `$PWD/hostdir` 本身 |
| `--tmpfs /tmp` | 丢失 | **丢失**（`cat: can't open '/tmp/t'`） | 容器本次启动（内存） | kernel tmpfs：`df` 显示 `tmpfs 5.8G`，`mount` 显示 `type tmpfs (rw,nosuid,nodev,noexec,relatime)` |

**直接证据**：`restart` 同一容器 → `f14de7de…`（ID 不变）数据**在**；`rm` + `run` → `cb8920ae…` → `cb9ce3b1…`（ID 更换）数据**丢**。ID 不同即新容器、新可写层。
⚠️ `docker diff` 必须在"写完文件之后、删除容器之前"执行，才能看到 `A /data.txt`。

**环境限制**：宿主上找不到 `/var/lib/docker` —— dockerd 运行在 Docker Desktop 的 **VM** 内，`Mountpoint` 是 VM 内部路径，宿主 `sudo ls` 必然报 `No such file or directory`。**"宿主机" = 运行 dockerd 的那台机器**，不是你的本地 shell。

### 4.2 网络解析对照

| 场景 | 现象 | 命令 |
|---|---|---|
| 默认 bridge，按容器名解析 | `** server can't find n1: NXDOMAIN`；`wget: bad address 'n1:8080'` | `docker run --rm alpine:3.22 nslookup n1` |
| `mynet`，按容器名解析 | `Server: 127.0.0.11` → `Name: n1 / Address: 172.19.0.2` | `docker run --rm --network mynet alpine:3.22 nslookup n1` |
| `mynet` 内访问 `http://w1:8080`（**无 `-p`**） | `<h1>Hello DevOps</h1>` | `docker run --rm --network mynet alpine:3.22 wget -qO- http://w1:8080` |

### 4.3 端口三视角（`-p 8081:8080`）

| 视角 | 命令 | 输出 |
|---|---|---|
| 宿主侧监听 | `sudo ss -ltnp \| grep 8081` | `LISTEN *:8081` —— 加 `sudo` 也看不到进程名（Docker Desktop 的端口转发组件） |
| 映射表 | `docker port d4p` | `8080/tcp -> 0.0.0.0:8081` + `[::]:8081` |
| 容器内监听 | `docker exec d4p netstat -tlnp` | `tcp :::8080 LISTEN 1/webapp` |
| **DNAT 规则** | `docker run --rm --privileged --net=host alpine:3.22 sh -c 'apk add -q iptables && iptables -t nat -L DOCKER -n'` | `Chain DOCKER (2 references)` + `DNAT tcp dpt:8081 to:172.17.0.2:8080` |
| 未写 `-p` 时从宿主访问 | `curl localhost:8080` | `curl: (7)`（宿主无人 listen） |
| 容器删除后 | `docker rm -f d4p` 后再查 | 宿主监听**变空**；`docker port d4p` → `No such container` |

### 4.4 `dangling` 的判定

`7fe3c1c0…` 属于 **`kind-control-plane`**（已停止，`Exited (128)`）→ **不出现**在 `-f dangling=true` 结果中。
→ **`dangling` = 没有被任何容器（含已停止）引用**。
⚠️ 不要删除 `7fe3c1c0…`：那是 kind 集群的数据卷，第 2 周需要。

---

## 5. 易错点

| 错法 | 现象 | 正确做法 |
|---|---|---|
| 认为 `docker restart` 也会丢数据 | 得出"可写层像内存、一停就没"的错误结论 | `restart` = 重启**同一个容器**，可写层不变；`run` 才是新建容器 |
| 用 `docker inspect -f '{{.GraphDriver.Data.UpperDir}}'` 查可写层 | `template parsing error: map has no entry for key "GraphDriver"` | 该字段在本机后端不存在（containerd 镜像存储）。替代：`docker diff <容器>` / `docker info -f '{{.Driver}}'` |
| 用"CMD 里带 `echo > /data.txt`"的容器测 restart | 看起来数据"还在"，实际是 PID 1 重启后重新写了一遍，实验无效 | 测持久化时文件必须用 `docker exec` 从外部写入，CMD 只保留 `sleep 600` |
| 认为 `docker volume prune` 会删命名卷 | 实测 `Total reclaimed space: 0B`，已悬空的命名卷 `webvol2` 仍在 | 默认**只删匿名卷**；要连命名卷一起删用 `docker volume prune -a` |
| 认为卷一定能在宿主 `sudo ls /var/lib/docker/volumes/...` 看到 | `ls: cannot access ...: No such file or directory` | 本机 dockerd 在 VM 内；"宿主机" = 运行 dockerd 的那台机器 |
| 用**相对路径**写 `-v hostdir:/data` | **静默创建了一个名为 `hostdir` 的命名卷**，容器内 `/data` 为空（`total 0`） | `-v` 的源必须写绝对路径（`$PWD/hostdir`）；**不以 `/` 开头即视为卷名**。更稳妥：`--mount type=bind,src=...` |
| 把要执行的脚本/二进制放进 `--tmpfs` 目录再运行 | `Permission denied`，即使文件有 `+x` | Docker 给 tmpfs 默认挂 `noexec`；需显式覆盖 `--tmpfs /tmp:rw,exec` |
| 说"默认 bridge 里容器不能互访" | 用名字访问确实失败，就以为完全不通 | 精确说法：**能按 IP 互访**（同在 `docker0` 子网），只是**没有名字服务**；`--link` 就是往 `/etc/hosts` 补这一行 |
| 看到 DNS 失败就认为"网络不通" | 不看解析器实际返回什么 | `NXDOMAIN` = 解析器工作正常，只是不认识该名字（名字问题）；超时 / `SERVFAIL` 才是 DNS 服务器本身有问题 |
| 在宿主执行 `sudo iptables -t nat -L DOCKER -n` | `sudo: iptables: command not found` | 两个原因叠加：① 宿主未安装 `iptables`（新发行版多用 nftables）② 更根本的是 daemon 在 VM 内，规则不在宿主。正确做法：`docker run --rm --privileged --net=host alpine:3.22 sh -c 'apk add -q iptables && iptables -t nat -L DOCKER -n'` |
| 用 `ss -ltnp` 查宿主端口却看不到属主 | Process 列为空，加 `sudo` 后仍为空（Docker Desktop） | 一般情况 `-p` 需 root 才显示属主；本机是端口转发组件在宿主上暴露监听，`ss` 取不到属主（✍️ 此为本机推断，未核对官方文档） |

---

## 6. 每日一题（面试自测）

### 6.1 容器题：重启容器后应用配置全丢

**我的原答**

1. 配置写到 **tmpfs** → 用 `docker inspect` 看是否用了 tmpfs
2. 配置写进**可写层**了、然后 `rm -f` + `run` → 也用 `docker inspect` 看启动参数
3. （未能给出第三条）

**批改：2/3**

| 原因 | 判定 | 收紧后的表述 | 验证命令 |
|---|---|---|---|
| ① 配置在 tmpfs | ✅ | 一致 | `docker inspect -f '{{json .Mounts}}' 名` → 找 `"Type":"tmpfs"` |
| ② 写在可写层 | 🔶 表述有漏洞 | ⚠️ 可写层在 `restart` 时**不丢**，必须是「写可写层**且容器被重建**」（`rm`+`run` / `compose up` 重建） | `docker ps -a --format '{{.ID}} {{.CreatedAt}}'` 看 ID 是否更换；Mounts 是否为空 |
| ③ **（遗漏）** 配置在**构建时写入镜像** | — | 运行期改的是可写层中的副本，容器重建后回到镜像中的旧值 | `docker run --rm 镜像:tag cat /app/config.yaml`（绕过容器看镜像中的那份）；`docker history 镜像` 找 COPY 配置的那层 |

**另外两条高频原因（面试常考）**

| 原因 | 机制 | 验证 |
|---|---|---|
| 配置从**环境变量**读取，重建时忘记带 `-e` / `--env-file` | 配置不在文件中而在容器环境里，重建即失 | `docker inspect -f '{{json .Config.Env}}' 名`，对比 `docker history` 的 `ENV` 层 |
| **bind mount 源路径写错**（相对路径 / 拼写错误） | 空目录**遮盖**镜像中的配置 → 应用读到空配置 | `docker inspect -f '{{json .Mounts}}' 名`；`docker volume ls` 看是否多出一行 |

> 关键点：题目字面是"**重启**"—— 若真是 `docker restart`，原因 ② 根本不是嫌疑人（可写层仍在）。这与 `restart` / `run` 的对象层区别是同一条因果链。

### 6.2 Linux 题：分词与 glob

**题目**：目录中有 `a b.txt`、`*star*`、`-dash`、`normal.log`。写一个 `for` 循环逐个安全打印：不漏文件、含空格的不会被拆开、`-dash` 不被当作选项。

**我的原答**

```bash
for f in *; do
    echo "$f"
done
```

**批改：骨架正确（glob 与引号两个主要问题都避开了），但漏 3 个条件**

| 漏点 | 现象 | 机制 | 正解 |
|---|---|---|---|
| **不漏文件** | `*` **不匹配** `.` 开头的文件 | glob 默认不匹配隐藏文件；`$(ls)` 同样漏（`ls` 默认不显示隐藏文件） | `shopt -s dotglob` 或追加 `.[!.]*` |
| **`-dash` 不被当选项** | 本题用 `echo` 未出错 | bash 的 `echo` 只识别 `-n/-e/-E`；换成 `cp`/`rm`/`mv` **必然**踩 | `printf '%s\n' "$f"`（printf 不解析选项）；真实操作加 `--`：`cp -- "$f" /backup/` |
| **空目录兜底** | 打印出一个字面量 `*` | glob 无匹配时 bash 默认把 `*` **原样**作为文件名传递 | `shopt -s nullglob` 或 `[ -e "$f" ] \|\| continue` |

**稳妥写法（两个版本）**

```bash
# A：通过 shopt 改变默认行为
shopt -s dotglob nullglob
for f in *; do
    printf '%s\n' "$f"
done

# B：不改全局设置（脚本中更安全，不影响后续代码）
for f in * .[!.]*; do
    [ -e "$f" ] || continue      # 兜底：无匹配时跳过字面量
    printf '%s\n' "$f"           # printf 不把 -dash 当选项
done
```

> 与「Shell 展开顺序」的关系（`docs/linux/Linux-故障索引.md` §2 机制 3）：别名 → 花括号 → 变量/命令替换 → **分词(IFS)** → 通配符 → 去引号。**分词在通配符之前**，因此 glob 展开的结果不会再被拆分；而 `$(ls)` 的输出正好经过"分词"这一步，必然被拆开。

---

## 7. 遗留疑问

| # | 问题 | 状态 |
|---|---|---|
| 1 | `-v hostdir:/data` 为什么会**静默**变成命名卷？Docker 依据什么判断"这是路径还是卷名" | ⬜ 待查：`--mount` 是否也会静默 |
| 2 | 默认 bridge 的容器"按 IP 互访"走的是二层直连还是经过网关 | ⬜ 待查 |
| 3 | 网络基础薄弱是本次预判第 3、4 题首答失败的原因（当时不知道"网桥"是什么）→ 补课清单见下 | 🔶 已补基础模型，可重答 |

---

## 附：网络基础补课清单（按需补，不占主线时间）

**目标不是学完 TCP/IP，而是补到"能看懂 Docker / K8s 网络"的量。**

| 优先级 | 概念 | 对应本日的哪个现象 |
|---|---|---|
| 1 | 二层 vs 三层（MAC / IP） | veth、网桥、`docker0` |
| 2 | IP + 子网掩码 + CIDR | `172.17.0.0/16`、`172.19.0.2` |
| 3 | 网关 / 路由表 | `default via 172.17.0.1` |
| 4 | **NAT：SNAT / DNAT** | `-p 8081:8080`、`iptables -t nat` |
| 5 | DNS 解析流程 | `resolv.conf`、`127.0.0.11`、`NXDOMAIN` |
| 6 | 端口 / socket（含 `:::` 双栈） | `LISTEN *:8081`、`netstat -tlnp` |
| 7 | 抓包 | 需要亲眼确认包路径时的最终手段 |

**只需先搞懂这 4 条（合计约 1.5 小时）**

| 概念 | 关键句子 |
|---|---|
| 二层 vs 三层 | 网桥/交换机只识别 **MAC**；路由只识别 **IP** |
| IP + CIDR | `172.17.0.0/16` 的前 16 位是网络号 |
| **NAT** | **出口改源地址（SNAT）、入口改目的地址（DNAT）** |
| DNS | "名字 → IP"这一跳由谁完成 |

> 第 2 周进入 K8s 后会更依赖这部分（CNI / Service / iptables），建议在进入第 2 周前补完第 1~4 项。
> 命令不需要看视频学 —— 用本文 §3 命令表与 `docs/docker/02-命令词典.md` §四 现查即可。
