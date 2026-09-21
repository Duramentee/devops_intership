# 本文件与 code/week2/day3/go-webapp/Dockerfile 完全相同，一个字都没有改动。
# 今天要观察的对象是「容器自身的健康状态对 kubelet 动作的影响」，
# 因此镜像的构建方式、运行用户、入口命令都必须保持不变，
# 否则探针引起的现象会与构建方式引起的现象混在一起，无法区分。
#
# ---------- 编译阶段：只负责产出二进制 ----------
FROM golang:1.25.1-alpine AS builder

WORKDIR /src
# 依赖清单单独一层：改源码不会触发依赖层重建（构建缓存按层命中）
COPY go.mod ./
# 此处必须是 download，不能是 tidy —— 该层执行时源码尚未进入镜像
RUN go mod download
COPY main.go ./
# CGO_ENABLED=0：产出纯静态 ELF，不依赖 libc/动态链接器
RUN CGO_ENABLED=0 go build -o /out/webapp ./main.go

# ---------- 运行阶段：只放产物 ----------
FROM alpine:3.22

# 非 root 用户（adduser 需要 root 权限，必须排在 USER 之前）
RUN adduser -D -u 10001 app

# COPY 的文件属主只由 --chown 决定，与 USER 无关
COPY --chown=10001:10001 --from=builder /out/webapp /app/webapp

# 之后所有指令与容器主进程都以 uid 10001 运行
USER 10001:10001

EXPOSE 8080

# 退出码 0 = healthy，非 0 = unhealthy（仅 docker run 有效，K8s 会忽略）
HEALTHCHECK --interval=5s --timeout=2s --retries=2 \
  CMD ["wget","-q","--spider","http://localhost:8080/"]

# exec form：PID 1 就是应用本身，docker stop 的 SIGTERM 能被应用收到
CMD ["/app/webapp"]
