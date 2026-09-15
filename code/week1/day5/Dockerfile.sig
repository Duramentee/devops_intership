# 实验 4：SIGTERM / SIGKILL 与"优雅关闭"
# 用法：docker build -f Dockerfile.sig -t day5-sig .
#       docker run -d -e MODE=graceful --name s1 day5-sig && docker stop s1
FROM golang:1.25-alpine AS builder
WORKDIR /src
COPY sig/go.mod ./
COPY sig/main.go ./
ENV CGO_ENABLED=0
RUN go build -o /sig .

FROM alpine:3.22
COPY --from=builder /sig /sig
ENV MODE=default
# exec 形式：/sig 是 PID 1 —— 和 shell 形式对比时这一点是题眼
ENTRYPOINT ["/sig"]
