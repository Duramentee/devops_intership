# Day 2 学习笔记 · 最小 CI 工作流（10-13）

> 目标：把「拉取请求与主分支推送时自动执行后端检查与前端构建」交付成可运行的工作流，并用一次可恢复的失败证明检查确实在执行，同时证明这个工作流不具备镜像发布能力。
> 本节涉及的产物位于**项目仓库** `k8s_proj/`，不在学习仓库的 `code/` 目录下，这是本周期开始采用的分工：应用代码、工作流与集群清单都放在项目仓库，学习目录只放当天的实验脚本、采集结果与复现入口。

## 一、今日交付物

| 编号 | 产出物 | 位置 | 状态 |
|---|---|---|---|
| 1 | 带注释的参考模板 | `k8s_proj/.github/workflows/ci.yml.template` | 已提交。扩展名为 `.template`，因此不会被 GitHub 当作工作流执行 |
| 2 | 由我手写的最小 CI 工作流 | `k8s_proj/.github/workflows/ci.yml` | 已提交并通过运行验证 |
| 3 | 前端依赖锁文件进入版本库 | `k8s_proj/code/shortener/web/package-lock.json` | 已提交，`npm ci` 因此可以执行 |
| 4 | 当日工作清单与验收自查表 | `code/week3/day2/README.md` | 已完成 |
| 5 | 失败运行的证据 | 拉取请求 #1 的运行 #4，作业 `Backend (Go)`，步骤 `Unit tests (no external dependencies)` | 已采集日志文本 |

## 二、全流程工作链路：一次提交到一条检查结果

这条链路回答的是「我在本机执行 git 命令之后，检查结果是怎么长出来的」。每一行都写明执行者、输入、动作、产生的对象或状态变化以及观察方式。

| 序号 | 执行者 | 输入 | 动作 | 产生的对象或状态变化 | 观察方式 |
|---|---|---|---|---|---|
| 1 | 我在本机 | 工作区改动 | 执行 `git add` 与 `git commit` | 当前分支上产生一个新的提交对象，分支指针前移 | `git log --oneline` |
| 2 | 我在本机 | 本地提交 | 执行 `git push` | 远端出现同名分支引用 | `git branch -vv` 显示的跟踪关系 |
| 3 | GitHub 的接收端 | 推送事件 | 匹配工作流文件中 `on.push` 的 `branches` 过滤条件 | 排入一次工作流运行 | 仓库 Actions 页面的运行列表，Event 列显示 `Commit <标识> pushed` |
| 4 | GitHub 的接收端 | 拉取请求事件 | 匹配 `on.pull_request` 的 `branches` 过滤条件 | 排入一次工作流运行，并且这一次运行会关联到该拉取请求 | 运行列表的 Event 列显示 `Pull request #<编号> opened` 或 `synchronize`；拉取请求页面出现 `Checks` 区域 |
| 5 | GitHub 的调度组件 | 工作流定义中的 `concurrency` | 检查同一个分组内是否已有正在运行的运行 | 分组内有旧运行时，旧运行被取消，只保留最新一次 | 运行列表中旧运行的状态变为 `Cancelled` |
| 6 | GitHub 的调度组件 | 作业定义中的 `runs-on` | 为每一个作业申请一台托管执行器 | 两个作业各分配到一台独立的 Ubuntu 虚拟机 | 运行详情页面左侧的 `All jobs` 列表，以及每个作业里的 `Set up job` 步骤 |
| 7 | 执行器上的 runner 服务 | 作业的 `steps` | 按顺序执行步骤 | 每一个步骤各产生一段日志与一个退出码 | 运行详情页面展开步骤后的日志 |
| 8 | `actions/checkout` | 触发本次运行的仓库与引用 | 把仓库内容取到工作区目录 | 执行器上出现源码与 `.git` 目录 | `Checkout` 步骤的日志中出现 `Syncing repository` |
| 9 | `actions/setup-go` | 路径为 `code/shortener/api/go.mod` 的文件中的 `go` 指令 | 安装对应版本的 Go 工具链，并按 `cache-dependency-path` 指向的 `go.sum` 的哈希恢复缓存 | 执行器上出现可用的 `go` 与 `gofmt`；缓存命中时日志显示恢复信息 | `Set up Go` 步骤的日志 |
| 10 | `actions/setup-node` | `with` 中声明的 `node-version` 与 `cache-dependency-path` | 安装 Node 22，并按 `package-lock.json` 的哈希恢复 npm 缓存 | 执行器上出现可用的 `node` 与 `npm` | `Set up Node` 步骤的日志 |
| 11 | 我写在 `run` 中的命令 | 上一步取下的源码与工具链 | 依次执行格式检查、编译、静态检查、单元测试、依赖安装与生产构建 | 每一条命令各产生一个退出码；退出码非零时该步骤失败 | 各步骤的日志与红绿标记 |
| 12 | runner 服务 | 各步骤的退出码 | 汇总为作业的结论 | 存在失败步骤时该作业失败，全部成功时该作业成功 | 运行详情页面左侧 `All jobs` 中的 `failed in <耗时>` 或绿色标记 |
| 13 | GitHub 的检查接口 | 各作业的结论 | 把结论写入这次提交的状态 | 该提交上出现检查项，拉取请求页面的 `Checks` 区域显示结果 | 拉取请求页面的 `Checks` 区域 |
| 14 | 我 | `Checks` 区域的结论 | 决定是否合并 | 合并之后 `main` 拿到新提交，并因为 `push` 条件再次触发一次运行 | Actions 运行列表出现新的运行，Event 列为 `Commit <标识> pushed` |

## 三、实测记录

### 3.1 六次运行的对照

| 编号 | 触发（Event 列） | 分支 | 结论 | 耗时 |
|---|---|---|---|---|
| #1 | Commit `d0dbf5d` pushed | `main` | 成功 | 1 分 10 秒 |
| #2 | Commit `6d6d762` pushed | `main` | 成功 | 20 秒 |
| #3 | Pull request #1 opened | `ci/minimal-workflow` | 成功 | 24 秒 |
| #4 | Pull request #1 synchronize | `ci/minimal-workflow` | 失败，失败作业为 `Backend (Go)` | 17 秒 |
| #5 | Pull request #1 synchronize | `ci/minimal-workflow` | 成功 | 15 秒 |
| #6 | Commit `6426b75` pushed | `main` | 成功，两个作业分别为 17 秒与 9 秒 | 19 秒 |

三次 `pull_request` 运行对应分支上的三个提交，分别是引入工作流的提交、故意改坏断言的提交 `d4905de`、以及恢复提交 `9a7e1ab`。Event 列由 `opened` 变为 `synchronize` 的原因是：同一条拉取请求在收到新的推送时会重新触发工作流，而不再属于「打开」这一动作。

运行 #6 产生于拉取请求 #1 被压缩合并之后：合并本身在 `main` 上创建了一个新的提交 `6426b75`，这个提交命中 `on.push` 的 `branches: [main]` 过滤条件，因此触发了一次新的运行。这条运行就是验收标准里「主分支推送也会触发检查」这一项的依据；值得注意的是它同样启动了 `Backend (Go)` 与 `Frontend (Vue + Vite)` 两个作业，而合并到拉取请求的检查结果并不被复用，因为这是两次彼此独立的工作流运行。

### 3.2 失败运行的关键日志

失败作业的汇总行为 `Backend (Go) failed in 14s`，失败步骤为 `Unit tests (no external dependencies)`，该步骤耗时为 1 秒，日志末尾为：

```text
Error: Process completed with exit code 1.
```

断言失败的具体信息为：

```text
router_test.go:112: GET /api/healthz 返回的状态码是 200，期望 418，响应体是 {"status":"ok"}
```

这三行合起来构成一条完整的证据链：故意改坏的期望值写在 `router_test.go` 第 112 行的 `t.Errorf` 上，失败的子测试是 `TestRouteMatching/存活检查`，该子测试失败使 `TestRouteMatching` 失败，进而使 `internal/httpapi` 这个包的测试失败，`go test` 以退出码 1 结束，最终使作业与工作流失败。

### 3.3 缓存命中的证据

同一次运行的 `Unit tests` 步骤日志中出现两行带标记的结果：

```text
ok  shortener/internal/shortcode  (cached)
ok  shortener/internal/flusher    (cached)
```

与之对照的是 `FAIL shortener/internal/httpapi`。`shortcode` 与 `flusher` 两个包这一次的输入（源码、依赖、执行环境）与上一次运行完全相同，因此 `go test` 直接复用了上一次的结果并回放其输出；`httpapi` 的源码发生了变化，因此必须重新执行。这一点会影响日志阅读的判断：看到某个包的用例输出，不等于这些用例在这一次运行中真的被执行过，判断依据是末尾是否有 `(cached)`。

### 3.4 前端可复现安装的证据

运行 #5 的 `Frontend (Vue + Vite)` 作业中，`Install dependencies (npm ci)` 这一步的日志为：

```text
Run npm ci --no-audit --no-fund
npm ci --no-audit --no-fund
shell: /usr/bin/bash -e {0}

added 35 packages in 689ms
```

这段日志提供两条信息。第一，实际执行的命令是 `npm ci`，安装数量为 35 个包，说明安装依据是提交进版本库的 `package-lock.json`。第二，`shell: /usr/bin/bash -e {0}` 这一行说明 Linux 上 `run` 步骤的默认 shell 是 `bash -e`，只带 `-e`，不带 `-o pipefail`；因此当命令里出现管道时，管道的中间命令失败不会让整个步骤失败，这与显式写 `shell: bash` 时的行为不同。

### 3.5 一次本地环境问题的排查记录：`git pull` 报 `bad object`

| 项目 | 内容 |
|---|---|
| 现象 | 执行 `git pull` 时输出 `fatal: bad object refs/agents/<标识>/checkpoints/turn/0:Zone.Identifier`，随后输出 `error: https://github.com/Duramentee/shortener_proj_k8s.git did not send all necessary objects` |
| 最容易误判的方向 | 错误信息里同时出现了远端地址与 `did not send all necessary objects`，很容易被判断为远端仓库损坏或者网络中断 |
| 实际原因 | 故障点在本地。`.git` 目录中存在大量文件名含冒号的文件，例如 `.git/refs/agents/<标识>/checkpoints/turn/0:Zone.Identifier` 与 `.git/remotes/origin/main:Zone.Identifier`。这些文件的文件名在 Git 的引用命名规则下不合法，内容也不是对象标识，因此 Git 在拉取结束阶段做连通性检查时读到它们就报 `bad object` |
| 定位过程 | 先用 `find .git -name '*:*'` 列出全部文件名含冒号的文件，再用 `find .git/refs -name '*:*'` 缩小到引用目录；同时用 `df -T .` 确认仓库所在文件系统为 `ext4`，因此这些文件不是 Windows 的隐藏数据流（如果是隐藏数据流，文件系统类型应当是 DrvFs 一类的挂载），而是被某个工具显式创建出来的普通文件 |
| 处理方式 | 执行 `find . -name '*:Zone.Identifier' -delete` 删除全部 544 个文件，随后执行 `git pull --ff-only` 成功，本地 `main` 以快进方式从 `03c7e4d` 更新到 `6426b75` |

这里得到一条可以复用的条件句：**当 `.git` 的 `refs/` 目录下存在文件名不合法的文件时，日常查询命令（例如 `git branch -vv`）只会输出 `warning: ignoring ref with broken name` 并跳过它，但拉取过程中的连通性检查会直接失败并报出 `bad object`；因此看到 `did not send all necessary objects` 时，应当先在本地的 `refs/` 目录中查找不合法的文件名，再考虑远端是否损坏。** 两者的区别在于，查询类命令容错并跳过，而连通性检查必须把所有引用解析出来才能判断收到对象是否完整。

---

## 四、三条硬结论（写成条件句）

1. 当两个作业之间没有声明 `needs` 依赖关系时，它们在各自独立的执行器上运行，一个作业失败不会改变另一个作业的结论；实测依据是运行 #4 中 `Backend (Go)` 显示 `failed in 14s` 的同时 `Frontend (Vue + Vite)` 仍然显示成功。
2. 当作业内的某条命令以非零退出码结束时，该步骤被判定为失败，该作业随即被判定为失败，整个工作流也随之失败；判断依据是失败步骤的日志末尾出现 `Error: Process completed with exit code 1.`，而不是依据日志里是否出现了关键字。
3. 当某个包的源码、依赖与执行环境均没有变化时，`go test` 会复用上一次的测试结果并在包名后标记 `(cached)`，因此这一次并未真正执行该包的用例；判断一次失败是否由本次改动引起，不能只看日志里有没有该包的输出，要看末尾有无 `(cached)` 以及该包的源码是否在本次提交中变化。

补充一条关于触发的边界条件：`pull_request` 触发的工作流只会在拉取请求的目标分支匹配 `branches` 过滤条件时运行，而且在同一条拉取请求上每推送一次都会重新运行一次；`push` 触发则只对 `branches` 中列出的分支生效，因此推送普通开发分支不会触发 `push` 这一类运行。

## 五、被修正的预测与表述

| 项目 | 原来的说法 | 修正后的说法 | 依据 |
|---|---|---|---|
| 失败子测试的名称 | 预测为 `TestRouterTable/存活检查` | 实际是 `TestRouteMatching/存活检查` | 失败运行的日志。出错原因是我按「表格用例用 `t.Run` 注册」这一条推测父测试的函数名，而没有先读源码里的函数名 |
| 断言所在行号 | 预测为 `router_test.go:112` | 与实测一致 | 失败运行的日志 |
| 分支与主分支指向同一提交时能否开拉取请求 | 认为可以照常创建 | 不能。比较页面显示无可比较内容，创建按钮不可用 | 实际操作时找不到创建入口，随后用 `git branch -vv` 发现四个引用指向同一个提交，再用 `git reset --hard` 加 `git push --force-with-lease` 把 `main` 退回到工作开始之前 |
| 远端 `main` 上已有工作流文件时，推送是否会触发运行 | 未预判 | 会触发，而且运行会出现在 Actions 列表中，Event 列为 `Commit <标识> pushed` | 运行 #1 与 #2 |

## 六、本日未纳入的范围与原因

| 未纳入的内容 | 原因 |
|---|---|
| 镜像构建与推送 GHCR | 推送镜像需要 `packages: write` 权限，与拉取请求阶段的最小权限原则冲突，安排在 10-15 用独立工作流承担 |
| `internal/store` 与 `internal/cache` 两个包的测试 | 前者需要真实 PostgreSQL，后者需要真实 Redis。托管执行器上默认没有这两个服务，直接纳入只会得到「跳过」而不是「通过」，把跳过当成通过会让检查结果失去意义。是否使用服务容器安排在 10-14 决定 |
| 分支保护与必需检查 | 属于仓库协作模型的配置，不属于工作流文件本身，安排在检查结果稳定之后配置 |
| 把本机 kind 集群接入执行器 | 托管的执行器无法访问本机集群；接入本机集群需要自托管执行器，而自托管执行器会带来跨作业状态残留与私网暴露两项风险 |

## 七、十分钟速记卡

| 项目 | 内容 |
|---|---|
| 一句话定义 | 工作流是一份版本化的自动化流程定义，它由事件触发、由执行器运行、由若干作业组成、由作业内的步骤按顺序执行 |
| 必须记住的键 | `on`（触发条件）、`permissions`（临时令牌的权限范围）、`concurrency`（同一分组的并发控制）、`jobs.<标识>.runs-on`（执行器）、`jobs.<标识>.defaults.run.working-directory`（只影响 `run` 步骤的工作目录）、`jobs.<标识>.steps[*].uses`（可复用动作）与 `run`（本机命令） |
| 全流程链路摘要 | 本机提交 → 推送 → GitHub 按 `on` 匹配事件 → 排入运行 → 按 `runs-on` 分配执行器 → 各步骤依次执行并产生退出码 → 汇总为作业结论 → 写入提交状态并在拉取请求的 `Checks` 区域显示 |
| 实测得到的硬结论 | 当两个作业之间没有 `needs` 时它们互相独立；当某条命令以非零退出码结束时该步骤、该作业与整个工作流依次失败；当某个包的输入完全未变化时 `go test` 复用结果并标记 `(cached)` |
| 面试问答卡的标准答法 | 事件决定「什么时候跑」，工作流定义「怎么跑」，作业是把验证拆成互相独立且可分别重试的单元，执行器提供运行环境，步骤是作业内按顺序执行的单元，动作是可复用的步骤集合 |
| 出现异常时的排查顺序 | 一看 YAML 结构与缩进；二看 Event 列确认工作流是否被触发、分支过滤是否把它排除；三看作业是否拿到执行器；四看步骤的运行环境与工作目录；五看权限与密钥；六看日志末尾的退出码与错误行 |
| 最容易答错的点 | 把 `defaults.run.working-directory` 当成对 `uses` 步骤也生效；把执行器上的路径写成绝对路径；把「两个作业并行」当成「两个作业不能传文件」的原因（真正原因是没有共享磁盘，加 `needs` 串行化之后依然读不到）；把日志里出现的用例输出当成这一次真的执行过 |
| 合上笔记自测 | ① 为什么 `actions/checkout` 必须显式声明？② `permissions` 段删掉会发生什么？③ 两个作业之间怎么传文件？④ `npm ci` 与 `npm install` 在持续集成中的差别是什么？⑤ 一次运行失败时，先看哪三个位置就能定位到是哪一层的失败？ |

## 八、面试问答卡

| 编号 | 问题 | 答题要点 |
|---|---|---|
| 1 | 事件、工作流、作业、执行器、步骤、动作之间是什么关系 | 事件是入口，工作流是文件，作业是运行单位且默认并行，执行器是运行作业的机器，步骤在作业内按顺序执行，动作是可复用的步骤集合。要点是要能说清「谁包含谁」而不是只罗列名词 |
| 2 | 为什么拉取请求阶段的检查与镜像发布要分开权限 | 拉取请求可能来自不可信来源，而且检查本身只需要读取源码；发布镜像需要写入软件包，如果把发布步骤放进拉取请求工作流，等于把写权限交给每一个能提交拉取请求的人。因此两个能力由不同工作流承担，权限互相隔离 |
| 3 | 两个作业之间怎么传文件与传数据 | 传文件用 artifact（上传与下载各一个动作）；传小数据用作业输出。要说明为什么不能直接读对方的文件：每个作业在独立的执行器上运行，文件系统不共享，而且 `needs` 只决定执行顺序，不带来共享 |
| 4 | 为什么持续集成里用 `npm ci` 而不是 `npm install` | `npm ci` 严格按锁文件安装，安装结果与锁文件完全一致，并且在 `package.json` 与锁文件不一致时直接失败；`npm install` 会在两者不一致时静默改写锁文件，导致持续集成环境与本机环境的依赖版本漂移 |

## 九、遗留问题与下一步

### 9.1 本日验收项的最终状态

| 编号 | 验收项 | 状态与依据 |
|---|---|---|
| 1 | 拉取请求上能看到检查结果 | 已完成，依据是运行 #3 至 #5 |
| 2 | 主分支推送也会触发检查 | 已完成，依据是运行 #6（Event 列为 `Commit 6426b75 pushed`，分支为 `main`） |
| 3 | 故意制造的测试失败会让工作流变红 | 已完成，依据是运行 #4 与 3.2 的日志 |
| 4 | 工作流不会走到镜像发布步骤 | 已完成，依据是工作流定义中没有发布作业，权限声明中也没有 `packages: write` |
| 5 | 前端使用可复现安装 | 已完成，依据是 3.4 的日志（`npm ci`，`added 35 packages`） |
| 6 | 后端检查范围与 `Makefile` 的 `test-unit` 一致 | 已完成，三个包路径与 `Makefile` 中定义完全相同 |
| 7 | 恢复之后检查重新变绿 | 已完成，依据是运行 #5 |

### 9.2 已经处理完毕的环境问题

| 事项 | 处理结果 |
|---|---|
| `.git/refs/heads/main:Zone.Identifier` 造成的告警 | 已在 3.5 一并清理，共删除 544 个文件名含冒号的文件；`git branch -vv` 已不再输出告警 |
| 合并方式 | 采用压缩合并，`main` 上只保留一个提交 `6426b75`，分支上的临时实验提交与其反向提交没有进入主分支历史 |
| 本地分支 | 已删除 `ci/minimal-workflow`，并执行 `git fetch --prune` 清理远端已经不存在的跟踪引用 |

### 9.3 尚未处理的事项

| 编号 | 事项 | 下一步动作 |
|---|---|---|
| 1 | 执行器镜像标签的迁移提醒 | 运行 #6 的页面出现了两条提示：`The ubuntu-latest label will migrate to Ubuntu 26 beginning October 19, 2026`。当前两个作业都使用 `ubuntu-latest`，到该日期之后底层系统会发生变化。是否改为写死 `ubuntu-24.04` 需要在 10-14 与作业边界、缓存一并决定；这条提醒与「动作的大版本要写明确版本」属于同一类问题 |
| 2 | 工作流每次运行会同时更新缓存 | `setup-go` 与 `setup-node` 的缓存目前由动作自动管理。是否改为自己控制缓存键、以及缓存键应当包含哪些文件，安排在 10-14 确认 |
| 3 | 镜像构建与推送尚未建立 | 安排到 10-15，需要新建独立工作流并单独申请 `packages: write` 权限 |
| 4 | 是否需要把 `store` 与 `cache` 两个包的测试纳入 | 安排到 10-14，先确认服务容器的使用方式与测试对环境的依赖 |
