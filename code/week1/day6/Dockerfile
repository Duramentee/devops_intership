# ============================================================
# Day 6 · 加固版 Dockerfile —— 骨架（只填空，不抄答案）
#
# 用法：cp Dockerfile.skeleton Dockerfile
#       然后把每个 【空N】 换成你的答案；每行后面的"菜单"是选项，选一个
#
# 推进法（重要，降低心智负担）：
#   第 1 遍：只写到阶段 A，目标 = build 成功 + run 起来 + curl 有响应
#   第 2 遍起：一次只加一个加固动作，每加一条就 build + run 一次
#            —— 增量验证，出了错只可能在新加的那行
# ============================================================

# ---------- 阶段 A：编译（你选的，已落成指令）----------
# 为什么这么排：改 main.go 只让「COPY main.go」之后的层失效，依赖层保持 CACHED
# ⚠️ 这一行必须是 download，不能是 tidy —— 此刻 main.go 还没拷进来，
#    tidy 要扫源码才能判断依赖（你选择题里选的就是 download，是对的）
FROM golang:1.25.1-alpine AS builder
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY main.go ./
RUN CGO_ENABLED=0 go build -o /out/webapp ./main.go

# ✅ 阶段 A 检查点（先只跑到这里 build 一次，确认二进制真的生成了）
#   docker build -t webapp:v4a .
#   docker run --rm --entrypoint ls webapp:v4a -l /out/webapp

# ---------- 阶段 B：运行底座（你选的 alpine:3.22）----------
# 还差两个口头回答（不写进文件）：
#   ① alpine 里有 shell 吗？有 wget 吗？有 curl 吗？
#   ② 为什么不用 scratch？为什么不用 golang 镜像？
FROM alpine:3.22

# ---------- 阶段 C：加固 2 · 非 root ----------
# adduser 需要 root 权限 → 必须排在 USER 之前
RUN adduser -D -u 10001 app

# 空7 ✔ 拷产物并指定属主：不写 --chown 就是 root:root
#   （COPY 的属主由 --chown 决定，跟 USER 无关 —— 这就是必须有 --chown 的原因）
COPY --chown=10001:10001 --from=builder /out/webapp /app/webapp

# 空8 USER：写在这里 = 之后所有指令 + 容器主进程都以 uid 10001 运行
#   写名字 app 也行（alpine 阶段有 /etc/passwd），但写数字更通用
#   （scratch 阶段没 /etc/passwd，只能写数字）
USER 10001:10001

# ---------- 阶段 D：端口、自检、启动 ----------
EXPOSE 8080

# 空10 HEALTHCHECK：dockerd 定期在容器内执行这条命令
#   退出码 0 = healthy，非 0 = unhealthy
#   选项加中文说明：默认是 --interval=30s --timeout=30s --retries=3，
#   这里调小只是为了让本地验证时早点看到 (healthy)
#   ⚠️ 若显示 (unhealthy)：进容器手敲一次这条命令看报错
#      （busybox wget 对 --spider 的支持要实测；备选写法：
#       HEALTHCHECK CMD ["wget","-q","-O","/dev/null","http://localhost:8080/"]）
HEALTHCHECK --interval=5s --timeout=2s --retries=2 \
  CMD ["wget","-q","--spider","http://localhost:8080/"]

# 空11 CMD：exec form → PID 1 就是 /app/webapp 本身
#   shell form（CMD /app/webapp）会让 PID 1 变成 /bin/sh -c，信号先被 sh 吃掉
CMD ["/app/webapp"]

# ============================================================
# 附加：.dockerignore（自己新建 `.dockerignore` 文件，至少考虑这几类）
#   [ ] .git             —— 体积 + 历史泄露
#   [ ] 本地编译产物 webapp —— 会覆盖镜像内编译的产物（Day 2 的坑）
#   [ ] *.log
#   [ ] README.md / 笔记
#   [ ] 任何密钥、证书、.env
# ============================================================
