# Dockerfile 指令词典

> 用法：写 Dockerfile 时逐条查语义；写完用「缓存与顺序」一节自查。
> 规则：**构建时的事用 `RUN`，运行时的事用 `CMD`/`ENTRYPOINT`。**
> 🧭 查具体知识点：`docs/00-知识点索引.md` §1-D（Dockerfile）· §1-E（权限/安全）

---

## 一、构建流程

| 步 | 发生什么 |
|---|---|
| 1 | `docker build -t 名:tag .` ← 结尾 `.` 是**构建上下文**，整个目录会送给 daemon |
| 2 | 找到目录里的 `Dockerfile`（可用 `-f` 指定别的文件名） |
| 3 | 以 `FROM` 的基础镜像分层为底，**逐条指令执行，每条生成一层** |
| 4 | 构建期每条指令在**临时容器**里跑，结果固化成层 |
| 5 | 最后一层打上 `<名>:<tag>` 标签 |

📖 "构建镜像时，Dockerfile 中每一条单独的指令都会创建一个新层。"（2.1.4 节，`k8s-in-action.txt` 行 3104-3114）
📖 与"手动进容器改完再 commit"相比，Dockerfile 的价值是**自动化 + 可重复**（2.1.4 节，行 3141-3143）。

---

## 二、指令全表

| 指令 | 语义 | 时机 | 备注 |
|---|---|---|---|
| `FROM 镜像[:tag] [AS 阶段名]` | 起始基础镜像 | 构建 | 必须是第一条；多阶段可多个 |
| `RUN 命令` | 在临时容器里执行，结果成层 | **构建** | 装包/编译 |
| `COPY [--from=阶段] [--chown=u:g] 源 目标` | 从**上下文**（或多阶段产物）拷进镜像 | 构建 | 推荐写法，语义单一 |
| `ADD 源 目标` | 同 COPY，但会自动解压 tar、支持 URL | 构建 | ⚠️ 语义不明确，日常用 COPY |
| `WORKDIR /路径` | 设工作目录，后续指令都相对它 | 构建 | 不存在自动建；比 `RUN cd` 正确 |
| `ENV K=V` | 环境变量（构建期+运行期都有） | 两者 | 会被写进镜像，**别放密钥** |
| `ARG K[=默认]` | **构建期**变量（`--build-arg` 传） | 构建 | 构建后可查出来，也不是秘密 |
| `EXPOSE 80/tcp` | 声明端口（文档/元数据） | 元数据 | ⚠️ **不会真的发布端口**，靠 `docker run -p` |
| `CMD [...]` / `CMD 命令` | 容器**默认启动命令** | **运行** | 可被 `docker run <镜像> <cmd>` 覆盖 |
| `ENTRYPOINT [...]` | 容器**固定入口** | **运行** | `run` 后参数当它的参数；用 `--entrypoint` 覆盖 |
| `USER 用户[:组]` | 之后指令与容器运行身份 | 构建+运行 | 安全加固关键（Day 6） |
| `VOLUME /data` | 声明匿名卷挂载点 | 运行 | 数据不入可写层 |
| `LABEL k=v` | 镜像元数据 | 元数据 | 版本、维护者、OCI 标准注解 |
| `HEALTHCHECK [选项] CMD 命令` | 健康检查 | 运行 | 退出码 0 健康、1 不健康 |
| `.dockerignore`（文件） | 排除不进上下文的内容 | 构建 | 省时间、防泄密（见 §五） |

---

## 三、三个最易混：RUN vs CMD vs ENTRYPOINT

| | `RUN` | `CMD` | `ENTRYPOINT` |
|---|---|---|---|
| 执行时机 | **构建镜像时** | 容器**启动时**（默认命令） | 容器**启动时**（固定入口） |
| 生成层 | 是（结果固化） | 只存元数据 | 只存元数据 |
| 会被覆盖吗 | 不适用 | `docker run 镜像 别的命令` → **被替换** | `docker run --entrypoint` → 才替换；否则 `run` 后的参数作为**参数追加** |
| 写几个 | 可多个 | **只最后一个生效** | **只最后一个生效** |

**最佳实践组合**：`ENTRYPOINT` 定"程序"，`CMD` 定"默认参数"

```dockerfile
ENTRYPOINT ["nginx"]
CMD ["-g", "daemon off;"]
# docker run img            → nginx -g daemon off;
# docker run img -T         → nginx -T
```

📖 这两条指令分别定义"命令"与"参数"：第 7 章 7.2 向容器传递命令行参数（正文行 10504 附近）。

### exec form vs shell form

| 写法 | 形式 | 说明 |
|---|---|---|
| `CMD ["nginx","-g","daemon off;"]` | **exec**（JSON 数组） | 直接 exec，**不经过 shell**；镜像没 shell 也能跑 ✅ 推荐 |
| `CMD nginx -g "daemon off;"` | **shell** | 实际变成 `/bin/sh -c "..."`；PID 1 是 sh，**信号可能收不到** ⚠️ |

---

## 四、缓存与顺序

| 规则 | 内容 |
|---|---|
| 单位 | **层**。逐条指令比对，命中则复用 |
| 失效 | 该指令的**输入变了**（`COPY` 的文件内容/`RUN` 的命令字符串/`FROM` 的镜像变了） |
| 影响范围 | **从失效层开始，后面所有层全部重建** |
| 原则 | **变动频率低的放前面**：基础镜像 → 依赖清单 → 依赖安装 → 源码 → 编译 → 启动命令 |

反例/正例（**通用示范，不是作业答案**）：

```dockerfile
# ❌ 改一行代码 → 依赖层也失效
COPY . .
RUN npm ci

# ✅ 依赖清单单独一层，改代码不触发重装
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
```

⚠️ 作业（Go 服务）自己按同样逻辑排 —— 想清楚"哪些文件几乎不变、哪些天天改"。

---

## 五、`.dockerignore`（常被忘）

语法类似 `.gitignore`，放在上下文根目录，用来**把文件排除出构建上下文**。

```
.git
node_modules
*.log
Dockerfile
README.md
webapp      # 本地编译产物，不该进镜像
```

好处：① 上下文小 → 构建快 ② 敏感文件不进镜像 ③ 避免"本地产物覆盖镜像内编译结果"。
⚠️ 不写它的话，`COPY . .` 会把 `.git`、`node_modules` 全拷进去。

---

## 六、多阶段构建

```dockerfile
# 阶段1：builder，只负责编译（版本与本周项目一致）
FROM golang:1.25.1-alpine AS builder
WORKDIR /src
COPY go.mod ./
RUN go mod download          # ⚠️ 不能写 tidy：此刻源码还没进来
COPY main.go ./
RUN CGO_ENABLED=0 go build -ldflags "-s -w" -o /out/webapp ./main.go

# 阶段2：runtime，只放产物（+ 非 root）
FROM alpine:3.22
RUN adduser -D -u 10001 app
COPY --chown=10001:10001 --from=builder /out/webapp /app/webapp
USER 10001:10001
EXPOSE 8080
HEALTHCHECK --interval=5s --timeout=2s --retries=2 \
  CMD ["wget","-q","--spider","http://localhost:8080/"]
CMD ["/app/webapp"]
```

| 要点 | 说明 |
|---|---|
| `--from=builder` | 只把**产物**捞过来，builder 整个阶段不进最终镜像 |
| `CGO_ENABLED=0` | 不依赖 libc，可跑在 scratch/alpine |
| `-ldflags "-s -w"` | 去符号表/调试信息，体积更小 |
| 极致 | 阶段2 换 `scratch`（空镜像）或 `distroless`；但**没有 shell，无法 `exec` 排障** |

---

## 七、反模式清单与自查

| 反模式 | 问题 | 正确做法 |
|---|---|---|
| `FROM x:latest` | 不可复现 | 固定具体版本 |
| `apt-get update` 和 `install` 分成两条 `RUN` | 缓存错配导致装到旧索引 | 合并成一条，并清理 `/var/lib/apt/lists/*` |
| `COPY . .` 放很前面 | 缓存全废、可能覆盖编译产物 | 先拷依赖清单 |
| `ENV SECRET=xxx` | 镜像里可明文查出 | 用运行时 `-e` / Secret |
| 默认 root 跑 | 逃逸≈宿主 root | `USER app` + `--cap-drop` |
| 一行一个 `RUN` 装几十个包 | 层数多、体积大 | 合理合并（但别为省层牺牲缓存） |
| 用 `ADD` 拷普通文件 | 语义不清晰 | 用 `COPY` |
| 镜像里留源码/工具链 | 体积大、攻击面大 | 多阶段构建 |
| 不写 `.dockerignore` | 上下文臃肿、误带密钥 | 写 |
| `CMD` 用 shell form 起服务 | PID 1 是 sh，收不到信号，停不干净 | exec form |

---

## 八、`USER` 与用户/组：`adduser` vs `useradd`、UID 怎么选

### 8.1 `useradd` 与 `adduser` 是两个命令

**结论**：`useradd` 是底层原语（shadow 工具集）；`adduser` 是上层封装 —— **Debian 系是 Perl 脚本（内部调 `useradd`）、Alpine 系是 BusyBox applet（自己实现，选项不通用）**。

| 名字 | 实际身份 | 来自哪个包 | 是否调 `useradd` |
|---|---|---|---|
| `useradd` | shadow 工具集（C，底层） | Debian/Ubuntu: `passwd`；RHEL: `shadow-utils`；**Alpine: 需 `apk add shadow`** | — |
| `adduser`（Debian/Ubuntu） | **Perl 脚本**封装 | `adduser` | ✅ 拼参数调 `useradd` |
| `adduser`（Alpine/BusyBox） | **BusyBox applet** | busybox（基础镜像自带） | ❌ 独立实现 |

| 维度 | `useradd` | Debian `adduser` | Alpine `adduser` |
|---|---|---|---|
| 交互性 | 全参数、零交互 | **默认交互**（问密码/姓名） | 交互；`-D` 变静默 |
| 建家目录 | **默认不建**，要 `-m` | 默认建 | 默认建 |
| 设密码 | 不设（另跑 `passwd`） | 交互设 | `-D` = 不设密码 |
| 适合写进 Dockerfile / CI | ✅ | ❌（会卡在提示符） | ✅（配 `-D`） |
| 组参数语义 | `-g` 主组 / `-G` 附加组 | 同 shadow | ⚠️ **`-g` 是注释、`-G` 是组 —— 与 shadow 相反** |

**按底座选（Dockerfile 里到底写哪行）**

| 底座 | 写什么 | 理由 |
|---|---|---|
| `alpine` | `RUN adduser -D -u 10001 app` | Alpine **没有 `useradd`**（除非 `apk add shadow`，白增体积） |
| `debian`/`ubuntu` | `RUN useradd -m -u 10001 app` | shadow 版一定在，且非交互 |
| `scratch` | **不建用户**，只写 `USER 10001:10001` | 无 `/etc/passwd` 也无 shell；内核只看数字 |

✍️ `USER 10001` **不需要 `/etc/passwd` 里有这条记录**：内核判权限只看 uid 数字；`/etc/passwd` 只影响 `id`/`whoami` 显示、`~` 展开、`getpwnam()` 类调用。

### 8.2 数字的含义：UID / GID 与镜像里的号

**(a) 内核层只有两个特殊值**

| 数字 | 含义 |
|---|---|
| `0` | root；绕过一切 DAC 权限检查（不看 rwx 位） |
| `4294967295`（2³²−1） | `(uid_t)-1`，内核保留为"无效 / 未映射" |
| `65534` | `nobody` / `nogroup`（内核 `overflowuid`），别拿来做服务账号 |

`uid_t` 是 **32 位无符号**（Linux 2.6+），有效范围 `0 ~ 4294967294`。

**(b) 1000 / 100 这些线是发行版约定，不是内核规则**（写在 `/etc/login.defs`）

| 区间 | 含义 |
|---|---|
| `0` | root |
| `100–999` | 系统服务账号（装包时自动分配；`SYS_UID_MIN..MAX`） |
| `1000–60000` | 普通用户（`UID_MIN..UID_MAX`，人手 `adduser` 的分段） |

固定号会随基础镜像变（`33` 在 Debian 里是 `www-data`）→ 用 `getent passwd 33` 查，**别背**。

**(c) `10001` 是社区惯例，没有内核含义**：≥1000（落在"普通用户"区间）· 远高于发行版预置号段（跨发行版安全）· 远离内核特殊值（0/65534）· 官方文档与 K8s `runAsUser: 10001` 示例高频出现。

**真正必须保证的 3 条约束**（比"选哪个数字"重要得多）

| # | 约束 | 踩了会怎样 |
|---|---|---|
| 1 | **镜像内唯一** | `useradd` 报 `UID 10001 is not unique` |
| 2 | **UID 和 GID 要配对写** | 只写 `USER 10001` → 进程 **gid 仍是 0（root 组）**；加固版写 `USER 10001:10001`，build 后 `docker exec <cid> id` 实测确认 |
| 3 | **bind mount 时 UID 要和宿主数据属主对齐** | 宿主目录属主 1000、容器跑 10001 → 写不进去（非 root 化最常见的翻车点）；临时办法 `-u $(id -u):$(id -g)` |

**(d) 容器特有：容器 uid 0 是否等于宿主 uid 0 取决于映射**

| 查什么 | 命令 | 说明 |
|---|---|---|
| uid 映射表 | 容器内 `cat /proc/self/uid_map` | 默认 `0 0 4294967295` = **未启用 userns-remap，容器 0 直接对宿主 0** → 这就是"容器 root 危险"的根 |

### 8.3 `USER` 的三个易错点

| 坑 | 现象 | 正确做法 |
|---|---|---|
| `USER app` 但镜像里没这个用户 | `docker run` 报 `unable to find user app: no matching entries in passwd file` | 用数字；或确保建用户那行在 `USER` **之前** |
| 以为 `USER` 会顺手设 `HOME` | `${HOME}` 仍指 `/root`（或为空） | `USER` 不设任何 env；需要就显式 `ENV HOME=/app` |
| 以为 `COPY` 会尊重 `USER` | 文件属主仍是 root | 用 `COPY --chown=u:g` —— **COPY 的属主只由 `--chown` 决定** |

> 写完再补三问（上面表里没覆盖的）：① 每条指令的**时机**（构建/运行）我给对了吗？② `COPY` 的源文件在**上下文**里真的存在吗（上下文 ≠ 宿主绝对路径）？③ 目标底座里有 `USER` 写的那个用户吗（`scratch` 只能写数字）？

## 自测

1. `EXPOSE 8080` 之后 `curl localhost:8080` 不通，为什么？
2. `CMD` 和 `ENTRYPOINT` 同时写，`docker run img a b` 实际执行什么？
3. 为什么 `COPY go.mod ./` + `RUN 下载依赖` + `COPY . .` 的顺序能保住缓存？
4. 多阶段构建里，builder 阶段为什么不会出现在最终镜像里？
