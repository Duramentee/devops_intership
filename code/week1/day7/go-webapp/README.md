# webapp · Go HTTP 服务（容器化示例）

最小可演示的 Go HTTP 服务，用于练习 Docker 镜像的**构建、瘦身与加固**：
多阶段构建 · 非 root 运行 · 最小 capability · 只读根文件系统。

---

## 1. 服务

- 监听 `:8080`，`GET /` 返回 `<h1>Hello DevOps</h1>`
- 日志写 stdout（由 `docker logs` 收集，不写文件）

## 2. 构建

```bash
docker build -t webapp:v4 .
```

## 3. 运行

```bash
# 基础运行
docker run -d --name webapp -p 8080:8080 webapp:v4

# 加固运行（非 root 已写进镜像，这里是运行期再加的两层）
docker run -d --name webapp --cap-drop=ALL --read-only --tmpfs /tmp -p 8080:8080 webapp:v4
```

## 4. 验证

| 验证项 | 命令 | 期望输出 |
|---|---|---|
| 启动状态 | `docker ps --format 'table {{.Names}}\t{{.Status}}'` | `Up ... (healthy)` |
| 接口 | `curl localhost:8080` | `<h1>Hello DevOps</h1>` |
| 运行身份 | `docker inspect -f '{{.Config.User}}' webapp:v4` | `10001:10001` |
| capability 位图 | `docker run --rm --entrypoint grep webapp:v4 ^Cap /proc/self/status` | `CapEff: 00000000a80425fb`（Docker 默认 14 个能力） |
| 镜像体积 | `docker images webapp` | `v4`：DISK USAGE `25.3MB` / CONTENT SIZE `8.3MB` |
| 镜像内无源码 | `docker run --rm --entrypoint find webapp:v4 / -name '*.go'` | 无命中 |
| 镜像内无 setuid 文件 | `docker run --rm --entrypoint find webapp:v4 / -perm -4000 -type f` | 无命中 |

> 非 root 身份运行时，`find /` 会报 `/root: Permission denied` —— 这是权限生效的正常现象。

## 5. 瘦身与加固的实测记录

| 版本 | 做法 | DISK USAGE | CONTENT SIZE |
|---|---|---|---|
| v1 | 单阶段 `golang:1.25.1-alpine` | 449MB | 88.9MB |
| v2 | 多阶段，runtime = `alpine:3.22` | 25.3MB | 8.3MB |
| v3 | 多阶段，runtime = `scratch` | 12.6MB | 4.51MB |
| **v4** | v2 + 非 root + `HEALTHCHECK` + `.dockerignore` | 25.3MB | 8.3MB |

**v4 与 v2 体积相同**：`EXPOSE` / `USER` / `HEALTHCHECK` / `CMD` 是元数据指令，**不产生镜像层**，所以加固不增加体积。

## 6. 设计取舍

| 选择 | 原因 |
|---|---|
| 运行底座用 `alpine` 而非 `scratch` | 保留 shell 与 CA 证书：可 `docker exec` 排障、HTTPS 出站可用。`scratch` 版（12.6MB）见 `code/week1/day3/` |
| 端口用 8080 而非 80 | 非 root 进程无法绑 < 1024 的端口（除非有 `NET_BIND_SERVICE`）；对外暴露用宿主侧映射 `-p 80:8080` |
| `COPY go.mod` 单独一层并放在最前 | 改源码不触发依赖层重建，构建缓存命中率最大化 |
| `go mod download` 而非 `go mod tidy` | 该层执行时源码尚未进入镜像，`tidy` 需要扫描源码才能判断依赖 |
| `CMD` 用 exec form | PID 1 就是应用本身，`docker stop` 的 SIGTERM 才能被应用收到（shell form 会被 `/bin/sh` 拦截） |

## 7. 已知限制

| 限制 | 说明 |
|---|---|
| 无 `tzdata` | 容器内默认为 UTC；需本地时区用 `-e TZ=Asia/Shanghai`（alpine 底座还需安装 tzdata 才生效） |
| `HEALTHCHECK` 只在 `docker run` 下有效 | K8s 会忽略它，容器健康由 liveness / readiness 探针承担 |
| 无 TLS 终止 | 本示例只提供 HTTP；生产应在反向代理或 Ingress 层终止 TLS |
