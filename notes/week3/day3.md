# Day 3 学习笔记 · CI 作业边界、缓存与集成测试（10-14）

> 本日主线：检查最小 CI 是否真实覆盖了计划内测试，并区分 job 顺序、文件传递与依赖服务。
> 配套清单：[code/week3/day3/README.md](../../code/week3/day3/README.md)。本文件是待实测笔记骨架，空白项不可当成结论。

## 一、今日交付物

| 产出物 | 位置 | 状态 |
|---|---|---|
| CI 作业边界与缓存决策 | [code/week3/day3/README.md](../../code/week3/day3/README.md) | 已完成：新增 `integration` 作业（方案 A），两个服务容器作业独占 |
| 工作流改动（若有证据支持） | `k8s_proj/.github/workflows/ci.yml` | 已完成：提交 `92123a8`，随 PR #2 触发运行 |
| 运行证据 | [code/week3/day3/outputs/run-pr2-integration.md](../../code/week3/day3/outputs/run-pr2-integration.md) | 已完成：关键日志行已摘录落盘 |
| Docker 主域复习记录 | [notes/week3/复习-1014.md](./复习-1014.md) | 待复习 |

## 二、概念与边界

| 概念 | 一句话定义 | 本日要确认的边界 |
|---|---|---|
| Workflow run | 一次由事件或手动操作触发的工作流运行 | 它包含若干 job，运行结果以本次触发的提交为依据 |
| Job | 工作流中一组步骤的执行单元 | 不同 job 使用独立执行环境；不能直接读另一个 job 的工作区文件 |
| Runner | 执行 job 的环境 | job 结束后不能假设其本地状态会供另一个 job 继续使用 |
| `needs` | 声明 job 之间的依赖顺序与成功条件 | 建立顺序，不负责传递文件 |
| Artifact | 显式保存并供其他 job 下载的文件 | 只有后续 job 确实需要前序产物时才使用 |
| Service container | 为某个 job 提供数据库、缓存等依赖服务的临时容器 | 服务只用于对应的测试运行；不得连接真实或共享环境 |
| Cache | 依据依赖输入复用可重建的下载/安装数据 | 缓存是性能优化，不应成为测试正确性的前置条件 |

## 三、全流程工作链路：提交到集成测试结果

| 阶段 | 执行者 | 输入 | 动作 | 产生的对象或状态变化 | 观察方式 |
|---|---|---|---|---|---|
| 1 | 本机开发者 | 工作流与测试改动 | 先预测 job 边界、测试依赖和缓存输入，再提交改动 | 分支上产生待验证提交 | `git diff`、`git status`、提交记录 |
| 2 | GitHub 事件接收与调度 | push / pull request 事件、工作流定义 | 匹配触发条件并创建 workflow run | 一次运行关联到触发提交 | Actions 运行列表及 Event / commit |
| 3 | GitHub 调度器 | `jobs` 定义与 `needs` | 按依赖图安排 job | 各 job 进入等待、运行或跳过状态 | 运行详情中的 job 列表与依赖状态 |
| 4 | Runner | job 的步骤与源码 | checkout、安装工具链、恢复缓存并执行命令 | 每个步骤有日志和退出码 | 逐 job 展开步骤日志 |
| 5 | Service container（如启用） | job 中的 service 定义与健康检查 | 启动 PostgreSQL / Redis，供该 job 的测试连接 | 服务就绪或健康检查失败 | service 日志、健康状态、测试连接错误 |
| 6 | Go 测试 | 测试包、环境变量与服务地址 | 执行无外部依赖测试和集成测试 | 测试通过、失败或明确跳过 | `go test -v` 输出；检查 `SKIP` 与失败原因 |
| 7 | Runner / GitHub Checks | 各步骤与 job 退出码 | 汇总 job 和 workflow run 结论 | 提交上出现检查结果 | Actions 总览、提交或 PR 的 Checks |
| 8 | 开发者 | run 结果与日志 | 按失败所属 job、步骤、依赖服务定位并修复 | 新提交产生新的运行；旧结果不被当作新提交结果 | 新旧 commit SHA 与新 run 的对应关系 |

> 属于本项目的工作流机制总结，需以本日运行日志复核；这不是书本原文引用。

## 四、预期与实测

### 4.1 预先预测（执行前填写）

| 问题 | 预测 | 依据 |
|---|---|---|
| 不同 job 是否共享工作区文件 | | |
| `needs` 是否传递文件 | | |
| 缺少 `TEST_DATABASE_URL` / `TEST_REDIS_ADDR` 时测试是否可能显示绿色 | | |
| 第二次不改依赖文件时，Go / npm 缓存预期如何变化 | | |

### 4.2 实测记录（完成后填写）

| 观察项 | 实测结果 |
|---|---|
| 运行编号与提交 SHA | PR #2 的 `pull_request` 事件；检出的合并引用提交为 `a2e09ea`（`92123a83` 合入 `6426b755`）；工作流文件取自 PR 分支，因此新增的 `integration` 作业出现在本次运行里 |
| job 名称 / 并行或依赖关系 | `backend`、`frontend`、`integration` 三个作业并行，没有任何 `needs` |
| service 健康检查结果 | GitHub 先建网络再建容器；`postgres service is starting, waiting 2 seconds` → `waiting 3 seconds` → `waiting 6 seconds` → `postgres service is healthy.`；随后 `redis service is healthy.`。postgres 从启动到就绪约 15 秒 |
| PostgreSQL 集成测试：通过 / 失败 / 跳过 | 通过：`internal/store` 9 个用例全部 `--- PASS`，`ok shortener/internal/store 0.156s`，没有出现 `SKIP` |
| Redis 集成测试：通过 / 失败 / 跳过 | 通过：`internal/cache` 7 个用例全部 `--- PASS`，`ok shortener/internal/cache 0.016s`，没有出现 `SKIP` |
| Go 缓存恢复证据 | `Cache hit for: setup-go-Linux-x64-ubuntu24-go-1.25.0-2eac4058…`、`Cache restored successfully`、`Cache restored from key: …`，结束时 `Cache hit occurred on the primary key …, not saving cache` |
| npm 缓存恢复证据 | 本次日志只覆盖 `integration` 作业，需要在 `frontend` 作业中单独查看 |
| 预测被推翻的地方 | 本次运行未出现推翻预测的结果；一处需要修正的初始想法是「主版本一致即可」，实测显示镜像标签与清单逐字一致（`-alpine`）更利于与集群对照 |
| 当前 CI 未覆盖的测试及原因 | api 与 web 之间的端到端链路未覆盖，因为本次只新增了存储层与缓存层的集成测试；前端生产构建只验证能否构建，不验证运行时行为 |

## 五、当天新增的硬结论

只记录实测支持的条件句，不填入尚未发生的预期：

| 条件句 | 证据 |
|---|---|
| 当文件只在某个 job 的工作区产生时，其他 job 不能直接读取该文件；需要显式 artifact 等传递机制 | `integration` 作业独立执行 `actions/checkout@v7`，三个作业之间没有任何 artifact 或 job outputs 步骤 |
| 当 job 只通过 `needs` 建立先后关系时，文件仍不会自动传递 | 本次三个作业并行、没有 `needs`，`integration` 仍取到完整源码，说明它依赖自己的 Checkout 而不是其他作业的工作区 |
| 当缺少集成测试环境变量时，相关测试可能 `Skip`；该运行不能作为集成行为已通过的证据 | 判据在源码：`newTestStore` 与 `newTestRedis` 在对应变量为空时调用 `t.Skip`；本次两变量均已传入，16 个用例全部 `--- PASS` 且无 `SKIP` |
| 当依赖输入未变化且缓存恢复成功时，安装步骤应从缓存复用相应数据；最终以日志为准 | `setup-go` 输出 `Cache hit for: setup-go-Linux-x64-ubuntu24-go-1.25.0-2eac4058…` 与 `Cache restored from key: …`；该键由 `go.sum` 的内容决定，与 10-13 的运行相同 |

## 六、命令与定位顺序

| 场景 | 命令 / 观察方式 | 说明 |
|---|---|---|
| 确认工作区改动 | `git status --short` | 只提交本次相关文件 |
| 检查工作流差异 | `git diff -- k8s_proj/.github/workflows/ci.yml` | 确认权限、job、service 与环境变量没有意外扩大 |
| 本地查看测试是否跳过 | 在 API 目录运行对应 `go test -v` 命令 | 对照 `SKIP`、连接失败和成功断言 |
| 观察缓存 | 查看 Actions 中 setup-go / setup-node 的恢复与保存日志 | 总耗时不能单独证明缓存命中 |
| 定位 CI 失败 | 先看失败 job，再看失败 step 和原始退出码 | 不从 workflow 总结状态反推具体根因 |

## 七、十分钟速记卡

| 项目 | 内容 |
|---|---|
| 一句话定义 | job 是独立执行单元；runner 执行 job；artifact 显式传文件；service container 提供测试依赖；cache 只优化可重建数据 |
| 必须记住的字段 / 键 | `jobs.<id>.runs-on`、`jobs.<id>.needs`、`jobs.<id>.services`、`jobs.<id>.env`、artifact 的 upload / download 步骤、缓存依赖文件路径 |
| 全流程链路摘要 | 提交 → 事件匹配 → workflow run → 调度 job → runner checkout / 缓存 / service → 测试步骤 → job 结论 → Checks |
| 当天实测硬结论 | ① 当 `integration` 作业使用 `services` 启动 postgres 与 redis 时，GitHub 会先建立独立网络、再以服务标识作为网络别名启动容器，并且等待两个健康检查都变成 `healthy` 之后才执行步骤；② 当测试步骤显式传入 `TEST_DATABASE_URL` 与 `TEST_REDIS_ADDR` 时，`internal/store` 与 `internal/cache` 共 16 个用例全部执行并 `--- PASS`，日志中不出现 `SKIP`；③ 当 `go.sum` 未变化时，`setup-go` 步骤命中缓存并输出 `Cache restored from key: …`；④ 当 postgres 服务容器是一个空数据库时，`EnsureSchema` 的两条 `CREATE ... IF NOT EXISTS` 语句执行成功，测试未报「确认数据表存在时失败」 |
| 面试问答卡 | **问：`needs` 能让一个 job 读取另一个 job 的文件吗？答：不能；它声明依赖顺序和成功条件，不共享 runner 工作区。需要文件时用 artifact 显式上传、下载；少量元数据可用 job outputs。** |
| 异常排查顺序 | 先定位失败 job → 失败 step → 退出码 / 日志 → 环境变量是否设置 → 测试是否跳过 → service 健康状态 → 缓存输入与恢复日志 |
| 最容易答错 | 把 `needs` 当成文件共享；把带 `SKIP` 的测试当通过；把缓存命中当正确性保证；把一个 job 的失败等同于所有 job 都未执行 |
| 合上笔记自测 | ① job 和 step 的关系是什么？② 怎样传递 job 文件？③ 如何证明数据库测试真的运行？④ 缓存没有命中会不会改变测试正确性？ |
