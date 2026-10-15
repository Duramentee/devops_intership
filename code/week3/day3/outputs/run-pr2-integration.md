# 10-14 运行证据 · PR #2 · integration 作业

> 运行触发：`pull_request` 事件，目标分支 `main`。
> 运行使用的提交：合并引用 `refs/remotes/pull/2/merge`，提交 `a2e09ea`（由 `92123a83` 合入 `6426b755` 产生）。
> 完整日志的位置：GitHub 仓库 `Duramentee/shortener_proj_k8s` 的 Actions 页面，PR #2 对应的运行，作业 `Integration (PostgreSQL + Redis)`。
> 本文件只摘录用于判定结论的关键行，不复制完整日志。

## 1. 权限与运行环境

| 日志行 | 含义 |
|---|---|
| `GITHUB_TOKEN Permissions` 之下出现 `Contents: read`、`Metadata: read` | 本次运行的令牌只有读权限，未出现 `packages: write` |
| `Runner Image` 为 `ubuntu-24.04` | 作业直接运行在执行器这台机器上，因此服务容器的可达地址是 `localhost:<发布的端口>` |

## 2. 服务容器启停

| 日志行 | 含义 |
|---|---|
| `docker network create --label 1a3705 github_network_e153a9eb6a9b480c8dc3709141634860` | 本次作业先建立独立的容器网络 |
| `docker create … --network-alias postgres -p 5432:5432 --health-cmd "pg_isready -U shortener -d shortener" --health-interval 10s --health-timeout 3s --health-retries 3 -e "POSTGRES_USER=shortener" -e "POSTGRES_PASSWORD=…" -e "POSTGRES_DB=shortener" -e "POSTGRES_INITDB_ARGS=--encoding=UTF8 --locale=C" -e "PGDATA=/var/lib/postgresql/data/pgdata" postgres:16-alpine` | 服务标识成为网络别名；镜像标签与 `k8s/20-postgres.yaml` 逐字一致 |
| `docker create … --network-alias redis -p 6379:6379 --health-cmd "redis-cli ping" --health-interval 5s --health-timeout 3s --health-retries 3 redis:7-alpine` | 同上，镜像标签与 `k8s/30-redis.yaml` 一致 |
| `postgres service is starting, waiting 2 seconds` → `waiting 3 seconds` → `waiting 6 seconds` → `postgres service is healthy.` | 健康检查生效；从容器启动到就绪约 15 秒 |
| `redis service is healthy.` | 两个服务都就绪之后，GitHub 才开始执行步骤 |
| `Stop and remove container: …`、`Remove container network: github_network_e153a9eb…` | 作业结束后服务容器与网络被清理 |

## 3. Go 缓存

| 日志行 | 含义 |
|---|---|
| `Cache hit for: setup-go-Linux-x64-ubuntu24-go-1.25.0-2eac40586caad20608b479235f70eddd58b1fb39938ade7dabac6cac4da1d62b` | 缓存命中 |
| `Cache restored successfully` 与 `Cache restored from key: …` | 从缓存恢复成功 |
| `Cache hit occurred on the primary key …, not saving cache` | 命中主键，因此本次不重复保存缓存 |

判读：缓存键由 `code/shortener/api/go.sum` 的内容决定，与 10-13 的 `backend` 作业相同，因此命中。

## 4. 测试步骤

| 日志行 | 含义 |
|---|---|
| `Run go test ./internal/store/... ./internal/cache/... -v` | 两个包都进入了测试命令 |
| `TEST_REDIS_ADDR: localhost:6379`，`TEST_DATABASE_URL: ***localhost:5432/shortener?sslmode=disable` | 两个环境变量已传入；令牌掩码使取值以 `***` 显示 |
| `--- PASS: TestCreateLinkAndGetLink` 至 `--- PASS: TestDeleteLink`（共 9 个）与 `ok shortener/internal/store 0.156s` | 存储层集成测试全部执行并通过 |
| `--- PASS: TestSetURLAndGetURL` 至 `--- PASS: TestCacheStatsOnMissingKeys`（共 7 个）与 `ok shortener/internal/cache 0.016s` | 缓存层集成测试全部执行并通过 |
| 全文中未出现 `SKIP` | 两个包没有被跳过，该次绿色结果可以作为存储层与缓存层行为通过的证据 |

## 5. 空数据库建表的验证

| 日志行 | 含义 |
|---|---|
| postgres 服务日志出现 `CREATE DATABASE`、`PostgreSQL init process complete; ready for start up.` | 服务容器是一个全新的空数据库 |
| `database system is ready to accept connections` | 数据库可以被连接 |
| 测试输出中未出现「确认数据表存在时失败」 | `EnsureSchema` 的两条 `CREATE ... IF NOT EXISTS` 语句在空数据库上执行成功 |

## 6. 无害现象（不作为失败依据）

| 日志行 | 判定 |
|---|---|
| `sh: locale: not found`、`no usable system locales were found`、`The database cluster will be initialized with locale "C"` | `-alpine` 镜像不带 locale 数据；清单要求的 `--locale=C` 已经生效 |
| `ERROR: duplicate key value violates unique constraint "links_pkey"`，键为 `zzstoreDup` | `TestCreateLinkDuplicate` 故意触发的重复主键，属于预期行为 |
| `postgres_test.go:67: 清理测试记录 zzstoreDel 时失败：短码不存在` | 该用例先自行删除记录，`t.Cleanup` 再删一次因找不到而记日志；`t.Logf` 不影响用例通过 |
| `WARNING Memory overcommit must be enabled! … see https://github.com/jemalloc/jemalloc/issues/1328` | Redis 在 `vm.overcommit_memory` 不等于 1 时的启动警告，与本次测试无关 |
