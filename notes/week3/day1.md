# Day 1 学习笔记 · CI 前置盘点（10-12）

> 目标：先盘点短链项目的真实构建入口、测试边界和默认分支，再确认 GitHub Actions 的抽象层次，确保后续写 workflow 时不踩假设。

## 一、仓库事实盘点

| 维度 | 结论 | 证据 |
|---|---|---|
| 仓库 | `shortener_proj_k8s`，远程为 `https://github.com/Duramentee/shortener_proj_k8s.git` | `git remote -v` |
| 默认分支 | `main` | `git branch --show-current` |
| 现有 workflow | 当前仓库还没有 `.github/workflows/` 目录 | `find .github/workflows` 结果为空 |
| 后端测试边界 | 纯单元测试在 `api/internal/shortcode` 与 `api/internal/httpapi`，不依赖 PostgreSQL / Redis | `api/Makefile` 中 `test-unit` 与 `make verify` |
| 后端依赖测试 | `store` 与 `cache` 需真实 PostgreSQL / Redis；缺失时会跳过或需显式设置环境变量 | `api/Makefile` 中 `test-store`、`test-cache` |
| 前端构建入口 | `web/` 用 Vite；生产构建命令是 `npm run build` | `web/package.json` |
| Node 锁文件 | 先前缺失；已本地生成并验证 | `npm install` + `npm run build` |
| 镜像命名思路 | `compose.yaml` 中的服务名对应 `shortener-api`、`shortener-web`；GHCR 侧应按 `ghcr.io/<owner>/<repo>-api`、`ghcr.io/<owner>/<repo>-web` 这种形式发版 | `compose.yaml` 与 CI 发布目标 |
| 权限原则 | 先遵守最小权限；PR 只允许只读触发，不直接拿 `packages: write`；主分支才发布镜像 | Actions 安全与仓库权限设计 |

## 二、CI 需要验证的命令

| 目的 | 命令 | 说明 |
|---|---|---|
| Go 编译 | `cd k8s_proj/code/shortener/api && go build ./...` | 先确认整个后端能编译 |
| Go 静态检查 | `cd k8s_proj/code/shortener/api && go vet ./...` | 查找参数错误、潜在错误 |
| 格式检查 | `cd k8s_proj/code/shortener/api && gofmt -l .` | 仅用于发现未格式化文件 |
| 无依赖单元测试 | `cd k8s_proj/code/shortener/api && go test ./internal/shortcode/... ./internal/httpapi/... -v` | CI 中最稳定的首层验证 |
| PostgreSQL 集成测试 | `cd k8s_proj/code/shortener/api && TEST_DATABASE_URL='...' go test ./internal/store/... -v` | 需要真实数据库 |
| Redis 缓存测试 | `cd k8s_proj/code/shortener/api && TEST_REDIS_ADDR='localhost:6379' go test ./internal/cache/... -v` | 需要真实 Redis |
| 前端依赖安装 | `cd k8s_proj/code/shortener/web && npm install` | 生成 lockfile，并恢复依赖 |
| 前端生产构建 | `cd k8s_proj/code/shortener/web && npm run build` | 验证生产构建成功 |

## 三、已验证的真实输出

### 3.1 后端单元测试

已执行：

```bash
cd /home/drow/devops_intership/k8s_proj/code/shortener/api && go test ./internal/shortcode/... ./internal/httpapi/... -v
```

结果：通过，退出码 0，`shortener/internal/shortcode` 与 `shortener/internal/httpapi` 均为 `ok`。

### 3.2 前端依赖与构建

已执行：

```bash
cd /home/drow/devops_intership/k8s_proj/code/shortener/web && npm install && npm run build
```

结果：
- `npm install` 完成并生成 `package-lock.json`
- `vite build` 成功，产物输出到 `dist/`
- 退出码 0，构建时间约 875ms

## 四、GitHub Actions 的抽象层次

从本书的讲法看，行为上可以这样区分：

| 概念 | 含义 | 例子 |
|---|---|---|
| Event | 触发器 | `push`、`pull_request`、`workflow_dispatch` |
| Workflow | 一份自动化定义 | `.github/workflows/ci.yml` |
| Job | 一个执行单元，可并行、也可依赖 | `build`, `test`, `docker-publish` |
| Runner | 实际执行 job 的环境 | GitHub-hosted runner |
| Step | job 里按顺序执行的动作 | `checkout`, `setup-go`, `npm ci`, `run` |
| Action | 可复用单元 | `actions/checkout@v4` |

### 关键判断

- 事件是自动化的入口；workflow 是入口文件；runner 是运行环境；job 是逻辑分组；step 是执行顺序。
- 这条层次对应的工程决策非常重要：如果是 PR 验证，就不给 `packages: write`; 如果是主分支发布，就在受保护分支上触发并保留唯一镜像 tag。

## 五、当日结论

1. 今天不需要改业务代码，先做的是“把 CI 的真实边界搞清”。
2. 后端的可控 CI 层级是：`go build` → `go vet` → `gofmt` → `test-unit`；真正的 DB/Redis 测试必须单独拆出来。
3. 前端的真实构建入口是 `npm install` + `npm run build`，且锁文件必须提交，避免 CI 环境与本地依赖漂移。
4. 现在仓库没有现成 workflow，所以下一步可以按主分支与 PR 两种触发设计最小可运行 CI，而不是先写发布流程。

## 六、十分钟速记卡

- 一句话记住 CI：功能代码负责“业务”，workflow 负责“工程保障”，而不是把一切都塞进一个 job。
- 必须记住的命令：`go test ./internal/shortcode/... ./internal/httpapi/...`、`npm install`、`npm run build`。
- 关键判断：PR 触发时“只验证”，主分支触发时才考虑镜像发布和环境部署。
- 面试答法：GitHub Actions 的事件决定什么时候跑，workflow 定义怎么跑，job 划分为并行/依赖，runner 提供执行环境，step 负责具体动作。
- 容易混淆：workflow 不是代码文件本身，runner 也不是 job，step 和 action 不能混用。 

---

> 备注：本次未改业务代码，仅完成仓库盘点、命令验证和 CI 设计前提确认。下一步可以直接进入最小 CI workflow 的编写。
