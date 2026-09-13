# Dockerfile 指令词典

> 用法：写 Dockerfile 时逐条查语义；写完用「缓存与顺序」一节自查。
> 铁律：**构建时的事用 `RUN`，运行时的事用 `CMD`/`ENTRYPOINT`。**

---

## 一、构建流程（先懂这个再写）

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
| `SHELL ["/bin/bash","-c"]` | 改 shell form 用的解释器 | 构建 | 默认 Linux 是 `/bin/sh -c` |
| `STOPSIGNAL SIGTERM` | `docker stop` 时发的信号 | 运行 | 默认已是 SIGTERM |
| `ONBUILD 指令` | 留给"别人的下游镜像"执行 | 构建 | 少见，慎用 |
| `.dockerignore`（文件） | 排除不进上下文的内容 | 构建 | 省时间、防泄密 |

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

## 四、缓存与顺序（今天/明天的主线）

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

## 六、多阶段构建（Day 3 预览）

```dockerfile
# 阶段1：builder，只负责编译
FROM golang:1.22-alpine AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -ldflags "-s -w" -o /out/app .

# 阶段2：runtime，只放产物
FROM alpine:3.20
COPY --from=builder /out/app /app
CMD ["/app"]
```

| 要点 | 说明 |
|---|---|
| `--from=builder` | 只把**产物**捞过来，builder 整个阶段不进最终镜像 |
| `CGO_ENABLED=0` | 不依赖 libc，可跑在 scratch/alpine |
| `-ldflags "-s -w"` | 去符号表/调试信息，体积更小 |
| 极致 | 阶段2 换 `scratch`（空镜像）或 `distroless`；但**没有 shell，无法 `exec` 排障** |

---

## 七、反模式清单（写完全部自查一遍）

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

## 八、自查清单（写完作业用）

- [ ] 每条指令的时机（构建 / 运行）我给对了吗？
- [ ] 改动最频繁的东西放最后了吗？
- [ ] `COPY` 的源文件在**上下文**里真的存在吗？（构建上下文 ≠ 宿主绝对路径）
- [ ] 启动命令是 exec form 吗？PID 1 是服务本身吗？
- [ ] 有没有把密钥、`.git`、本地二进制带进镜像？
- [ ] 基础镜像 tag 是固定的吗？

## 自测

1. `EXPOSE 8080` 之后 `curl localhost:8080` 不通，为什么？
2. `CMD` 和 `ENTRYPOINT` 同时写，`docker run img a b` 实际执行什么？
3. 为什么 `COPY go.mod ./` + `RUN 下载依赖` + `COPY . .` 的顺序能保住缓存？
4. 多阶段构建里，builder 阶段为什么不会出现在最终镜像里？
