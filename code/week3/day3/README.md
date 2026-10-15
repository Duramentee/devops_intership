# 10 月 14 日工作清单：CI 作业边界、缓存与集成测试

> 本日主线：在已经可运行的最小 CI 上，判断哪些检查应该留在快速作业、哪些测试确实需要 PostgreSQL / Redis，并用证据验证缓存是否命中。
> 本日复习主域：Docker D1（架构与原理）。本清单是执行脚手架，不代表当天实验已经完成；所有结果留待实测后填写。

## 一、本日产出物

| 编号 | 产出物 | 路径 | 状态 |
|---|---|---|---|
| 1 | CI 作业边界与服务依赖决策 | 本文件 §二、§三 | 待验证 |
| 2 | 经过验证的工作流改动（仅在证据支持时修改） | `k8s_proj/.github/workflows/ci.yml` | 待决定 |
| 3 | 运行记录与缓存对照 | `code/week3/day3/outputs/` | 待采集 |
| 4 | 当日笔记 | `notes/week3/day3.md` | 待实验后回填 |
| 5 | Docker / Linux / Shell / Kubernetes 复习记录 | `notes/week3/复习-1014.md` | 待复习后回填 |

## 二、动手前先做预测

| 问题 | 先写预测与依据 |
|---|---|
| `backend` 和 `frontend` 是否能直接读取对方作业生成的文件？ | |
| 给两个作业添加 `needs` 后，它们是否共享工作目录？ | |
| 如果后端作业没有 `TEST_DATABASE_URL` / `TEST_REDIS_ADDR`，集成测试会通过还是被跳过？ | |
| PostgreSQL 与 Redis 服务容器应当属于哪个作业？该作业失败时，快速单元测试是否还应独立报告结果？ | |
| Go 与 npm 的缓存分别由什么依赖清单决定？改动哪一个文件预期会使对应缓存失效？ | |

## 三、检查当前状态并做决策

项目当前工作流位于 `k8s_proj/.github/workflows/ci.yml`，已有独立的 `backend`、`frontend` 作业。Go 缓存依赖 `code/shortener/api/go.sum`；npm 缓存依赖 `code/shortener/web/package-lock.json`。先看现有配置与测试，再决定是否需要改动，不要为“增加缓存配置”而重复添加已有能力。

| 检查点 | 证据 / 判断 |
|---|---|
| `internal/store` 是否需要 PostgreSQL | 测试从 `TEST_DATABASE_URL` 读取 DSN；变量缺失时调用 `t.Skip`；新建测试连接时会调用 `EnsureSchema`。确认该初始化能否在 CI 空数据库中完成： |
| `internal/cache` 是否需要 Redis | 测试从 `TEST_REDIS_ADDR` 读取地址；变量缺失时调用 `t.Skip`。测试会清理测试键，并有会重置统计键的用例： |
| Redis 测试是否适合连共享服务 | 只应使用本次 job 的临时 Redis；不得连真实或共享环境。测试并发/统计键影响的限制： |
| PostgreSQL 与 Redis 集成测试放哪里 | 评估「继续留在快速后端作业」与「单独建立集成作业」的反馈速度、失败隔离和维护成本： |
| 是否要增加 `needs` | `needs` 只建立作业依赖顺序，不传递文件；是否真的需要串行： |
| 缓存是否已启用且有命中证据 | 检查 action 配置、缓存依赖文件与运行日志；命中日志： |

**实现选择的判断标准**

| 选择 | 适用条件 | 必须验收 |
|---|---|---|
| 快速单元测试与集成测试拆成独立 job | 希望无外部服务的检查快速反馈，数据库/缓存失败单独可见 | 集成 job 自己 checkout 源码、安装 Go、启动临时服务，并明确设置测试环境变量 |
| 在同一个后端 job 中运行 | 测试规模小，且引入服务不会显著拖慢所有反馈 | 每次运行都启动临时服务；测试明确执行而不是被跳过 |
| 使用 `needs` | 一个 job 的结果确实决定另一个 job 是否应开始 | 说明依赖关系；不要把 `needs` 当作共享工作区的办法 |
| 上传 / 下载 artifact | 后续 job 确实需要前一 job 生成的文件 | 用 artifact 显式传文件，并验证下载步骤；不要为传递源码而重复上传 checkout 已有内容 |

## 四、候选执行步骤

每一步先写预期，再执行并记录结果。工作流要修改时先本地检查 diff；如果现有配置已经满足目标，就保留它并记录证据。

| 顺序 | 动作 | 观察依据 |
|---|---|---|
| 1 | 查看当前分支、工作区与工作流 diff | `git status --short`、`git diff -- k8s_proj/.github/workflows/ci.yml` |
| 2 | 检查两个集成测试的环境变量、跳过条件、初始化和清理逻辑 | `internal/store/postgres_test.go`、`internal/cache/redis_test.go` |
| 3 | 选择作业边界，并写出每个 job 需要的输入、服务、命令、输出 | §三决策表 |
| 4 | 对比 Go/npm 缓存依赖文件与 action 设置 | `go.sum`、`package-lock.json`、工作流日志中的 restore/save 信息 |
| 5 | 若需修改，最小化编辑工作流；集成测试用独立的临时服务和专用测试环境变量 | 检查 YAML diff；确认没有真实凭据、生产地址或 `packages: write` |
| 6 | 在本地先跑无外部服务测试与工作流语法/差异自检 | 记录命令及退出码；如缺少服务，不要把跳过算成通过 |
| 7 | 推送到练习分支并观察作业状态、服务健康状态、测试是否跳过及缓存日志 | Actions 运行详情中分别查看 job、service container、step 和 test 输出 |
| 8 | 第二次运行相同输入，对照缓存恢复结果 | 记录两次运行的 cache hit/miss 证据，不以总耗时单独判断 |

> 集成服务使用临时测试数据和非真实密码。不要把生产 DSN、真实密码或其他凭据写入工作流、输出文件或笔记。

## 五、验收标准

| 编号 | 验收项 | 完成 |
|---|---|---|
| 1 | 能解释两个 job 为什么有独立 runner / 工作区，以及 `needs` 的作用边界 | [ ] |
| 2 | 对需要 PostgreSQL、Redis 的测试，明确选择运行或不运行；若运行，日志证明测试实际执行而非 `SKIP` | [ ] |
| 3 | 服务容器只供对应 CI job 的测试使用，测试环境变量明确且不包含真实凭据 | [ ] |
| 4 | Go 与 npm 缓存分别能对应到依赖锁定文件，并有恢复缓存的日志证据 | [ ] |
| 5 | 如果添加作业依赖或 artifact，能说明它解决的具体问题；未把 `needs` 误认为文件传递机制 | [ ] |
| 6 | 快速检查与依赖服务的集成测试失败能分别定位；未将“测试被跳过”标成通过 | [ ] |
| 7 | 工作流仍保持最小权限，不含镜像发布步骤或 `packages: write` | [ ] |

## 六、观察记录（2026-10-14 实测）

| 观察项 | 记录 |
|---|---|
| 运行编号 / 提交标识 | PR #2 的 `pull_request` 事件；运行检出的是合并引用 `refs/remotes/pull/2/merge`，其提交为 `a2e09ea`（由 `92123a83` 合并进 `6426b755` 产生） |
| 变更前的 job 列表 | `backend`、`frontend` |
| 变更后的 job 列表 | `backend`、`frontend`、`integration` |
| 每个 job 的职责与依赖 | `backend` 负责 Go 的编译、静态检查与无外部依赖测试；`frontend` 负责安装依赖与生产构建；`integration` 负责 `internal/store` 与 `internal/cache` 两组集成测试，并自带两个服务容器。三者并行，没有任何 `needs` 依赖 |
| PostgreSQL / Redis 服务健康证据 | GitHub 先执行 `docker network create`，再以 `--network-alias postgres` 与 `--network-alias redis` 启动两个容器；日志先出现 `postgres service is starting, waiting 2 seconds`、`waiting 3 seconds`、`waiting 6 seconds`，随后出现 `postgres service is healthy.` 与 `redis service is healthy.`。postgres 从启动到就绪约 15 秒 |
| store 测试实际执行 / 跳过情况 | 9 个用例全部执行，`TestCreateLinkAndGetLink` 至 `TestDeleteLink` 均为 `--- PASS`；结尾 `ok shortener/internal/store 0.156s`；**没有出现 `SKIP`** |
| cache 测试实际执行 / 跳过情况 | 7 个用例全部执行，`TestSetURLAndGetURL` 至 `TestCacheStatsOnMissingKeys` 均为 `--- PASS`；结尾 `ok shortener/internal/cache 0.016s`；**没有出现 `SKIP`** |
| Go 缓存恢复证据 | `Cache hit for: setup-go-Linux-x64-ubuntu24-go-1.25.0-2eac40586caad20608b479235f70eddd58b1fb39938ade7dabac6cac4da1d62b`；`Cache restored successfully`；`Cache restored from key: …`；结束时 `Cache hit occurred on the primary key …, not saving cache` |
| npm 缓存恢复证据 | 本次贴出的日志只覆盖 `integration` 作业，`frontend` 作业的 npm 缓存恢复日志需要单独打开该作业查看 |
| 故意失败或故障注入（如有）及恢复提交 | 本次未做故障注入 |
| 最终验收结果与未覆盖范围 | 通过。未覆盖范围：api 与 web 之间的端到端链路；集成测试只验证存储层与缓存层自身行为 |

### 6.1 本次运行中观察到的无害现象

| 现象 | 出处 | 判定 |
|---|---|---|
| `sh: locale: not found` 与 `no usable system locales were found` | postgres 服务日志 | `-alpine` 镜像不带 locale 数据，只产生警告；随后 `The database cluster will be initialized with locale "C"` 说明清单要求的 `--locale=C` 已经生效 |
| `ERROR: duplicate key value violates unique constraint "links_pkey"`，键为 `zzstoreDup` | postgres 服务日志 | 这是 `TestCreateLinkDuplicate` 故意触发的重复主键，用于验证错误映射，属于预期行为 |
| `postgres_test.go:67: 清理测试记录 zzstoreDel 时失败：短码不存在` | store 测试输出 | 该用例先自行删除了记录，`t.Cleanup` 再删一次因找不到而记一条日志；它是 `t.Logf` 而不是失败，用例仍为 `--- PASS` |
| `WARNING Memory overcommit must be enabled! … see https://github.com/jemalloc/jemalloc/issues/1328` | redis 服务日志 | Redis 在 `vm.overcommit_memory` 不等于 1 时的启动警告，与本次测试无关 |

## 七、完成后的条件句

只保留由运行日志或测试结果支持的结论：

| 条件句 | 证据 |
|---|---|
| 当两个检查位于不同 job 时，它们不会直接共享工作区文件；只有通过 artifact 等显式机制才传递文件 | `integration` 作业独立执行 `actions/checkout@v7` 取到源码，与 `backend`、`frontend` 之间没有任何 artifact 或 job outputs 步骤 |
| 当 `needs` 只用于排序时，它不会传递前一个 job 的文件 | 本次三个作业并行、没有任何 `needs`，`integration` 仍然取到了完整源码，说明它依赖的是自己的 Checkout 步骤而不是其他作业的工作区 |
| 当集成测试所需环境变量未设置时，测试会被跳过，因此该次绿色结果不能证明 PostgreSQL / Redis 行为通过 | 判据来自源码：`newTestStore` 在 `TEST_DATABASE_URL` 为空时调用 `t.Skip`，`newTestRedis` 在 `TEST_REDIS_ADDR` 为空时调用 `t.Skip`；本次两个变量都已显式传入，因此日志中 16 个用例全部为 `--- PASS`，没有出现 `SKIP` |
| 当依赖输入未变化且缓存可用时，第二次运行会依据日志显示缓存恢复；若输入哈希改变则应重新安装/下载相关依赖 | 本次运行的 `setup-go` 步骤输出 `Cache hit for: setup-go-Linux-x64-ubuntu24-go-1.25.0-2eac4058…` 与 `Cache restored from key: …`；该缓存键由 `go.sum` 的内容决定，与 10-13 的 `backend` 作业相同，因此命中 |

## 八、integration 作业的书写顺序清单（只给键与判定条件，取值留空）

> 用途：本清单给出 `integration` 作业要写的每一项键、这一项的判定条件，以及写错时的后果；取值由你自己决定后再写入 `k8s_proj/.github/workflows/ci.yml`。
> 前置约束：改动必须先在特性分支上提交，不能直接提交到 `main`（依据：10-12 的教训，带注释的工作流直接进 `main` 会导致后续分支与 `main` 指向同一次提交、拉取请求不可创建）。

| 顺序 | 要写的键 | 判定条件（在什么情况下这一项必须存在） | 写错时的后果 |
|---|---|---|---|
| 1 | `jobs:` 下新增的作业标识 | 该标识会与 `backend`、`frontend` 并列出现在 Actions 的作业列表里 | 标识重复会使工作流文件非法，`backend` 作业被覆盖 |
| 2 | 作业的 `name:` 字段（可选） | 只有当希望作业列表里显示可读名称时才写 | 省略时作业列表显示标识本身，不会报错 |
| 3 | `runs-on:` | 必须是一个 GitHub 托管的执行器标签 | 写成不存在的标签会使该作业一直处于等待状态 |
| 4 | `defaults.run.working-directory:` | 与 `backend` 作业保持一致，指向 `code/shortener/api` | 省略时后续的 `go` 命令在仓库根目录执行，找不到 `go.mod`，测试步骤立即失败 |
| 5 | `services:` 段 | 只有在作业需要外部依赖服务时才写 | 省略该段时 `internal/store` 与 `internal/cache` 两个包会调用 `t.Skip`，日志出现 `SKIP` |
| 5.1 | PostgreSQL 服务的 `image:` | 必须与本地 compose 使用同一个主版本 | 主版本不同时，建表语句与索引的兼容性无法与本地结果对照 |
| 5.2 | PostgreSQL 服务的 `env:` | 官方 `postgres` 镜像必须给出 `POSTGRES_USER`、`POSTGRES_PASSWORD`、`POSTGRES_DB` 三个变量 | 缺 `POSTGRES_USER` 或 `POSTGRES_PASSWORD` 时容器初始化失败；缺 `POSTGRES_DB` 时 DSN 里引用的数据库不存在，连接报错 |
| 5.3 | PostgreSQL 服务的 `ports:` | 让该作业的步骤通过 `localhost` 访问服务，格式为主机端口与容器端口的映射 | 不写端口映射时作业内的步骤无法通过 `localhost` 连接，只有同一容器网络内的服务才能互访 |
| 5.4 | PostgreSQL 服务的 `options:` | 必须给出 `--health-cmd`（使用 `pg_isready`）与间隔、超时、重试次数 | 不写健康检查时 GitHub 不会等待服务就绪，测试会在服务完成初始化之前开始并连接失败 |
| 5.5 | Redis 服务的 `image:`、`ports:`、`options:` | `options` 中的 `--health-cmd` 使用 `redis-cli ping` | 与 5.3、5.4 相同：缺端口映射则不可达，缺健康检查则过早开始测试 |
| 5.6 | Redis 服务的 `env` 与 DSN 里的数据库编号（可选） | 只有当希望进一步隔离键空间时才设置；本项目在作业内部没有第三方写入者，因此可以省略 | 设置编号时若与测试预期不一致，会读到另一个编号的数据 |
| 6.1 | `steps:` 中的 Checkout 步骤 | 任何需要源码的作业都必须先取源码 | 省略时工作区为空，后续全部步骤失败 |
| 6.2 | `steps:` 中的 setup-go 步骤 | 需要 Go 工具链与模块缓存时使用，`cache-dependency-path` 必须指向 `code/shortener/api/go.sum` | 缓存路径写错时缓存不命中，只影响耗时，不影响正确性 |
| 6.3 | 运行集成测试的步骤 | 必须把 `TEST_DATABASE_URL` 与 `TEST_REDIS_ADDR` 两个环境变量显式传给这一步 | 两个变量未传时对应的包调用 `t.Skip`，日志出现 `SKIP`，绿色结果不能作为集成行为通过的证据 |
| 6.4 | 测试步骤的包路径 | 必须显式写出 `./internal/store/...` 与 `./internal/cache/...` 两个包 | 不写这两个包时该作业不会检查任何集成行为，与当前 `backend` 作业的缺口相同 |
| 7 | 作业的 `needs:` 字段 | 只有在该作业必须在某个作业成功之后才允许开始时才写；本作业与 `backend`、`frontend` 之间没有文件传递需求 | 加上 `needs` 只会把并行改成串行并增加等待时间，不会带来文件共享 |

不要添加的字段：`packages: write` 权限。本作业只运行测试，不推送镜像，权限保持 `contents: read`。

## 九、`EnsureSchema` 在空数据库上的验证记录

| 验证项 | 做法 | 结果 |
|---|---|---|
| 空数据库建表 | 本次 `integration` 作业的 postgres 服务容器就是一个**全新的空数据库**（容器创建后由官方镜像执行 `initdb`，日志中出现 `CREATE DATABASE`），`TEST_DATABASE_URL` 指向它 | 通过：`internal/store` 的 9 个用例全部 `--- PASS`，其中 `TestCreateLinkAndGetLink` 在建立连接后调用了 `EnsureSchema` |
| `EnsureSchema` 是否报错 | 观察测试输出中是否出现「确认数据表存在时失败」 | 未出现，说明两条 `CREATE ... IF NOT EXISTS` 语句在空数据库上均执行成功 |
| 是否真的执行而非跳过 | 观察测试输出中是否出现 `SKIP`，并确认测试用例确实被运行 | 日志中 9 个用例均出现 `--- PASS`，没有出现 `SKIP` |

## 十、集群取值到 CI 集成作业的映射（2026-10-14 从集群读出）

> 数据来源：`kubectl get secret postgres-secret -n shortener -o jsonpath='{.data.<键>}' | base64 --decode`，以及 `kubectl describe cm api-config -n shortener`。
> 用途：确定 `integration` 作业中哪些变量属于 postgres 容器自身、哪些变量属于客户端，避免把客户端的连接串写进服务容器自己的初始化环境变量。

| 来源对象 | 键 | 集群中的取值 | 消费这个键的容器 | 在 CI 中的对应位置 |
|---|---|---|---|---|
| Secret `postgres-secret` | `POSTGRES_USER` | `shortener` | postgres 容器自身（初始化时创建用户） | `services.postgres.env` |
| Secret `postgres-secret` | `POSTGRES_PASSWORD` | `shortener_dev_password` | postgres 容器自身 | `services.postgres.env` |
| Secret `postgres-secret` | `POSTGRES_DB` | `shortener` | postgres 容器自身（初始化时创建数据库） | `services.postgres.env` |
| Secret `postgres-secret` | `DATABASE_URL` | `postgres://shortener:shortener_dev_password@postgres:5432/shortener?sslmode=disable` | **api 容器** | 不对应 `services.postgres` 的任何变量；它对应测试步骤的 `TEST_DATABASE_URL`，宿主名必须改写 |
| ConfigMap `api-config` | `POSTGRES_INITDB_ARGS` | `--encoding=UTF8 --locale=C` | postgres 容器自身 | `services.postgres.env` |
| ConfigMap `api-config` | `REDIS_ADDR` | `redis:6379` | **api 容器** | 对应测试步骤的 `TEST_REDIS_ADDR`，宿主名必须改写 |
| ConfigMap `api-config` | `CACHE_TTL` | `300s` | api 容器 | 与本次集成测试无关 |
| ConfigMap `api-config` | `CLICK_FLUSH_INTERVAL` | `5s` | api 容器 | 与本次集成测试无关 |
| ConfigMap `api-config` | `SHUTDOWN_TIMEOUT` | `10s` | api 容器 | 与本次集成测试无关 |
| ConfigMap `api-config` | `GIN_MODE` | `release` | api 容器 | 与本次集成测试无关 |

### 10.1 宿主名的改写规则

| 客户端变量 | 集群取值中的宿主名 | 集群中为什么是这个宿主名 | CI 中应当改写成什么 | 为什么 |
|---|---|---|---|---|
| `TEST_DATABASE_URL` | `postgres` | 集群内由 CoreDNS 把 Service 名称解析成该 Service 的地址 | `localhost` | Linux 执行器上作业的步骤直接运行在执行器这台机器上，服务容器的端口被发布到本机 |
| `TEST_REDIS_ADDR` | `redis` | 同上 | `localhost` | 同上 |

### 10.2 三条互相独立的链路（本次最容易混淆的一处）

| 链路 | 变量名 | 谁读它 | 取值中的宿主名 |
|---|---|---|---|
| postgres 容器自身初始化 | `POSTGRES_USER`、`POSTGRES_PASSWORD`、`POSTGRES_DB` | postgres 容器 | 不涉及宿主名 |
| api 应用连接数据库 | `DATABASE_URL` | api 容器 | `postgres`（Service 名称） |
| 测试连接数据库 | `TEST_DATABASE_URL` | `internal/store` 的测试代码 | CI 中是 `localhost` |

### 10.3 由集群取值得出的三条修正

| 编号 | 修正 | 依据 |
|---|---|---|
| 1 | 删除 `services.postgres.env` 中的 `POSTGRES_URL` | 集群里不存在这个键；与之对应的键名是 `DATABASE_URL`，而且它由 api 容器消费，postgres 容器不消费它 |
| 2 | `POSTGRES_USER`、`POSTGRES_PASSWORD`、`POSTGRES_DB` 的取值与集群一致 | 与 Secret 中同名键的取值相同 |
| 3 | `POSTGRES_INITDB_ARGS` 的取值与集群一致 | 与 ConfigMap 中同名键的取值相同 |
