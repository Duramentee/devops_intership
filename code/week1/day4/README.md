# Day 4 · 数据与网络

> 目标：搞清「**容器数据为什么丢**」和「**端口为什么通/不通**」。
> 配套：`plan/week1/任务明细.md` 的 Day 4 节 · `docs/docker/03-命令词典.md` §四（网络）/ §五（存储）· `docs/docker/05-排障索引.md`
> 笔记落点：`notes/week1/day4.md`
> **基线**：`webapp:v2`（25.3MB，alpine 版，**有 shell 能排障**）—— 今天全程用它，别用 `scratch`。
> **昨天的经验**：`-p 8082:8081` 写错一次（应用听 8080）→ 今天正好把「端口为什么通/不通」一次吃透。

---

## 一、今日流程（照着走，不要跳步）

| 顺序 | 时段 | 做什么 | 产出 |
|---|---|---|---|
| 0 | 15 min | **开场抽背**（考 Day 3 的坑）：① builder 的文件为什么进不了最终镜像 ② `-p` 两边分别是什么、`curl (56)` 说明什么 ③ `scratch` 的三个代价 | 口述 |
| 1 | 20 min | **可写层实验**：容器内写文件 → `rm -f` → 重建，确认数据没了 | 现象记录 |
| 2 | 30 min | **命名卷**：`-v webvol:/data` 重做 → 确认数据还在 | 现象记录 |
| 3 | 25 min | **bind mount** 对比：`-v /宿主/路径:/data`，在宿主改文件看容器里是否立刻变 | 现象记录 |
| 4 | 15 min | `tmpfs`：`--tmpfs /tmp`，容器一停就没了 | 现象记录 |
| 5 | 40 min | **自定义网络 DNS**：默认 bridge 用名字 ping 失败 → `mynet` 里成功 | 两条 curl/ping 结果 |
| 6 | 25 min | **端口与 DNAT**：`docker port` / `ss -ltnp` / 容器内 `netstat` 三视角对齐 | 三张输出 |
| 7 | 20 min | **Linux 每日一题**（`docs/linux/Linux-每日一题.md` Day 4：shell 分词） | 答案 |
| 8 | 30 min | **容器每日一题**（见本文件第四节） | 答案 |
| 9 | 20 min | 收尾：结论写进 `notes/week1/day4.md`（概念 / 命令 / 易错点 / 我的疑问） | 笔记 |

> **铁律：先做后看。** 每一步**先预判会发生什么再执行**，预判错了才是今天真正学到的东西（Day 3 靠这招收效很明显）。

---

## 二、产出物清单（本目录）

| 文件 | 来源 / 说明 | 谁产出 |
|---|---|---|
| `README.md` | 本文件 | 老师 |
| `note.md` | 当天命令与实测输出（可以贴原始输出） | 你写 |
| `nginx.conf`（可选） | 步骤 5 用 nginx 或 webapp 做被访问方都行 | 你写 |

| 资源 | 名字 | 说明 |
|---|---|---|
| 命名卷 | `webvol` | Docker 管理，落在 `/var/lib/docker/volumes/webvol/_data` |
| 宿主目录 | `./hostdir`（本目录下） | bind mount 用 |
| 自定义网络 | `mynet` | 内嵌 DNS，容器名可解析 |

---

## 三、分步任务与验证

### 步骤 1 · 可写层实验（数据为什么会丢）

| 场景 | 命令 | 要观察什么 |
|---|---|---|
| 起容器并写文件 | `docker run -d --name d4a webapp:v2 sh -c 'echo hello > /data.txt; sleep 600'` | ⚠️ 覆盖了默认 CMD，容器只是个「能写的盒子」 |
| 确认文件在 | `docker exec d4a cat /data.txt` | — |
| 掏出容器删除 | `docker rm -f d4a` | — |
| 重建同名容器 | `docker run -d --name d4a webapp:v2 sh -c 'sleep 600'` | — |
| 再找文件 | `docker exec d4a cat /data.txt` | **报错**：`No such file or directory` |

**你要能回答**：

| # | 问题 |
|---|---|
| 1 | 文件写到哪一层去了？为什么容器删了就没了？ |
| 2 | `docker rm -f` 到底删了什么（进程？层？） |
| 3 | 如果不删容器，只 `docker restart d4a`，文件还在吗？为什么？ |

### 步骤 2 · 命名卷（Docker 管理的持久化）

| 场景 | 命令 | 要观察什么 |
|---|---|---|
| 建卷 | `docker volume create webvol` | — |
| 看落点 | `docker volume inspect webvol` | `Mountpoint` 在**宿主**哪个路径 |
| 挂载并写 | `docker run -d --name d4b -v webvol:/data webapp:v2 sh -c 'echo v1 > /data/x; sleep 600'` | — |
| 删容器 | `docker rm -f d4b` | — |
| **重建 + 同卷** | `docker run -d --name d4c -v webvol:/data webapp:v2 sh -c 'sleep 600'` | — |
| 读回 | `docker exec d4c cat /data/x` | **`v1` 还在** |
| 宿主侧验证 | `sudo ls -l /var/lib/docker/volumes/webvol/_data` | 卷本质就是**宿主上的一个目录** |

### 步骤 3 · bind mount（宿主目录直接映射）

| 场景 | 命令 | 要观察什么 |
|---|---|---|
| 建宿主目录 | `mkdir -p hostdir && echo fromHost > hostdir/f.txt` | — |
| 双向验证 | `docker run --rm -v $PWD/hostdir:/data webapp:v2 cat /data/f.txt` | 容器**立刻**看得到宿主刚写的文件 |
| 反向写 | `docker run --rm -v $PWD/hostdir:/data webapp:v2 sh -c 'echo fromContainer >> /data/f.txt'` | 宿主 `cat hostdir/f.txt` 也能看到 |

**你要能回答**：

| # | 问题 |
|---|---|
| 1 | `-v webvol:/data` 和 `-v $PWD/hostdir:/data` 在**谁管理生命周期**上差在哪？ |
| 2 | 宿主路径写成 `hostdir:/data`（相对路径）会挂到哪？ |
| 3 | 把卷挂到一个**已经有内容的**目录（如 `/etc`）会发生什么？ |

### 步骤 4 · tmpfs（只存内存）

```bash
docker run --rm --tmpfs /tmp webapp:v2 sh -c 'echo x > /tmp/t; ls -l /tmp/t'
```

| # | 问题 |
|---|---|
| 1 | 容器一停，`/tmp/t` 去哪了？ |
| 2 | 什么场景该用 tmpfs（提示：密钥、临时缓存）？ |

### 步骤 5 · 网络：默认 bridge vs 自定义网络（**今天的重点**）

**5.1 先证明默认 bridge 不行**

```bash
docker run -d --name n1 webapp:v2 sh -c 'sleep 600'
docker run --rm --link n1 webapp:v2 sh -c 'ping -c1 n1 || echo FAILED'   # --link 是旧写法，看它为什么被淘汰
docker run --rm webapp:v2 sh -c 'getent hosts n1 || echo NO_DNS'
```

> ⚠️ alpine 里 `ping` 可能要 `apk add iputils`；**用 `getent hosts <名>` 或 `nc -z <名> 8080` 更省事**（不依赖额外包）。

**5.2 再证明自定义网络可以**

```bash
docker network create mynet
docker run -d --name n1 --network mynet webapp:v2 sh -c 'sleep 600'
docker run --rm --network mynet webapp:v2 sh -c 'getent hosts n1'
```

| 场景 | 命令 | 要观察什么 |
|---|---|---|
| 用容器名访问服务 | `docker run -d --name w1 --network mynet webapp:v2` 然后 `docker run --rm --network mynet alpine:3.22 wget -qO- http://w1:8080` | **成功**，而且**根本没写 `-p`** |

**你要能回答**（今天的核心）**：**

| # | 问题 |
|---|---|
| 1 | 为什么 `mynet` 里能用**容器名**当主机名？是谁在解析？ |
| 2 | 为什么默认 `bridge` 不行？`--link` 当年是怎么硬凑出来的？ |
| 3 | 同事说「我容器起好了，宿主 `curl localhost:8080` 不通」→ 可能哪些原因？（≥3 个，每个配验证命令） |
| 4 | 容器 A 想访问容器 B 的 8080，需要 `-p` 吗？`-p` 到底服务于**谁**？ |

### 步骤 6 · 端口与 DNAT：三个视角对齐

| 视角 | 命令 | 看到什么 |
|---|---|---|
| 宿主侧谁在听 | `ss -ltnp \| grep 8081` | 是 **docker-proxy**？还是别的？ |
| 宿主侧映射表 | `docker port web2` | `8081 -> 8080/tcp` |
| 容器内侧谁在听 | `docker exec web2 netstat -tlnp` | `:::8080  LISTEN  1/webapp` |
| 规则链（需要 root） | `sudo iptables -t nat -L DOCKER -n` | DNAT 把宿主 8081 转到容器 IP:8080 |

**你要能回答**：

| # | 问题 |
|---|---|
| 1 | `-p 8081:8080` 之后，宿主上到底是谁在监听 8081？为什么「不是你的进程」也能通？ |
| 2 | 容器删了，这条 DNAT 规则还在吗？用哪条命令验证？ |
| 3 | `EXPOSE 8080` 和 `-p 8081:8080` 分别做了什么？（Day 2 自测题第 1 题的现场版） |

### 步骤 7 · 验收（全部打勾才算完成）

- [ ] 能**说出**可写层为什么随容器删除而消失，并用实验复现
- [ ] 命名卷重建容器后数据仍在（贴输出）
- [ ] bind mount 宿主↔容器双向生效（贴输出）
- [ ] `mynet` 里用**容器名**访问服务成功，且**没写 `-p`**
- [ ] 能画/说出 `-p` 的 DNAT 链路：宿主端口 → 容器 IP:端口
- [ ] 能说出 ≥3 个「宿主 curl 不通」的原因与验证命令
- [ ] `notes/week1/day4.md` 四段写满

---

## 四、每日一题（先自己写答案 → 再找人批改）

题目与作答区在 `notes/week1/day4.md` 的「每日一题」一节：

- **容器题（排障题）**：现象「**重启容器后应用配置全丢**」。写出至少 3 个可能原因，每个配**验证命令**。
  （提示：可写层 / volume 挂错路径 / 配置在构建时就烤进镜像了 / 配置在容器里被程序重写）
- **Linux 题（shell 分词）**：目录里有 `a b.txt`、`*star*`、`-dash`、`normal.log`，写 `for` 循环逐个**安全打印**：不漏文件、含空格的不被拆开、`-dash` 不被当选项。

> 答不出来比答对更有价值：今天暴露的坑，面试时就不会踩。

---

## 五、先预判再实测（今天沿用这招）

跑之前先填，跑完对账：

| # | 预判什么 | 我猜 | 实际 | 差在哪 |
|---|---|---|---|---|
| 1 | `docker rm -f` 后 `/data.txt` 还在吗 | | | |
| 2 | 卷重建容器后数据还在吗 | | | |
| 3 | 默认 bridge 里 `getent hosts n1` 能解析吗 | | | |
| 4 | `mynet` 里不写 `-p`，`wget http://w1:8080` 通吗 | | | |
| 5 | 宿主 `ss -ltnp \| grep 8081` 显示哪个进程 | | | |

---

## 六、卡住了怎么办

| 情况 | 做法 |
|---|---|
| 完全没思路 | 说「给我一个提示」，只要**方向**不要答案 |
| 有思路但不确定 | 先写下来发批改，按「哪里对 / 哪里错 / 为什么」改 |
| 机制没懂 | 说「讲一下 XX 的机制」，按「现象 → 机制 → 命令 → 失败模式」讲 |
| 网络不通 | 先分清是**哪一段**不通：容器内 → 容器间 → 宿主→容器 → 外网 |
| 找不到卷/网络 | `docker volume ls` / `docker network ls`；残留用 `docker network rm mynet`、`docker volume rm webvol` |
