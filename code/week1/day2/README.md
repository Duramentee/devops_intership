# Day 2 · 镜像分层与 Dockerfile

放这里的东西：

| 文件 | 来源 / 说明 |
|---|---|
| `main.go` | Go HTTP 服务，源码照抄 `labs/实践任务.md` 第五部分 |
| `go.mod` | `go mod init docker-demo` 生成 |
| `Dockerfile` | **今天的主角 —— 自己写** |
| `.dockerignore` | Day 6 补 |

跑法（写完 Dockerfile 后）：

```bash
go build -o webapp main.go                  # 先确认本地能编译
docker build -t webapp:v1 .
docker run -d --name web -p 8080:8080 webapp:v1
curl localhost:8080                          # 期望 <h1>Hello DevOps</h1>
```
