# Day 4 学习笔记 · GHCR 镜像发布工作流（10-15，实际运行于 10-16）

> 本日主线：在持续集成之上新增一份**独立**的镜像发布工作流，把「构建并推送镜像」严格限制在「`main` 分支上、持续集成已经给出成功结论的 push 提交」这一个前提下。
> 配套清单：[code/week3/day4/README.md](../../code/week3/day4/README.md)。
> 复习部分：[notes/week3/复习-1015.md](./复习-1015.md)。
> 本文件只记录主线；标为「待补」的项尚未取得证据，不得当成结论。

## 一、今日交付物与状态

| 产出物 | 位置 | 状态 |
|---|---|---|
| 镜像发布工作流 | `k8s_proj/.github/workflows/publish-images.yml` | 已合并并在 main 上成功运行 |
| 带注释模板（取值留空） | `k8s_proj/.github/workflows/publish-images.yml.template` | 已提交 |
| 执行清单与证据表 | `code/week3/day4/README.md` | 已生成 |
| 本笔记 | `notes/week3/day4.md` | 已回填实测部分 |
| Shell 复习记录 | `notes/week3/复习-1015.md` | 已完成 |

## 二、概念与边界

| 概念 | 一句话定义 | 本日确认的边界 |
|---|---|---|
| 工作流运行（workflow run） | 一次由事件触发的工作流执行 | 它由**触发它的那个事件**决定权限与上下文 |
| `workflow_run` 事件 | 监听「另一个工作流的运行已经完成」的事件 | 它监听的是工作流**定义**，因此该定义必须已经存在于默认分支上；只在特性分支上的工作流不会被触发 |
| `github.event.workflow_run` | 上游那次运行的信息对象 | 提供 `conclusion`、`event`、`head_branch`、`head_sha` 四项判定依据 |
| `github.sha` | 当前工作流的默认检出目标 | 在 `workflow_run` 触发的工作流里它指向默认分支的**最新**提交，不是被验证的提交 |
| `head_sha` | 上游运行对应的那一个提交 | 它是本次构建源码版本的唯一正确来源 |
| 权限隔离 | 两份工作流各自申请各自的权限 | 持续集成只申请 `contents: read`；发布才申请 `packages: write`。权限按**工作流**申请，无法只在某个作业上单独收紧 |
| GHCR 包（package） | GitHub Container Registry 中按包名管理的镜像仓库 | 包名由「所有者 + 镜像名」组成；命名空间必须全部小写 |
| 不可变标签 | 取值为完整提交 SHA 的镜像标签 | 同一标签永远指向同一份源码构建出的镜像；`latest` 这类浮动标签会被后续推送覆盖 |

## 三、全流程工作链路：从提交到镜像出现在镜像库

| 阶段 | 执行者 | 输入 | 动作 | 产生的对象或状态变化 | 观察方式 |
|---|---|---|---|---|---|
| 1 | 本机开发者 | 工作流文件与模板 | 创建特性分支并提交，推送到远端 | 远端出现特性分支与新提交 | `git status --short`、`git log --oneline` |
| 2 | 本机开发者 | 特性分支 | 向 `main` 发起拉取请求 | 出现拉取请求对象 | 仓库的 Pull requests 页面 |
| 3 | GitHub 事件调度 | 拉取请求事件 | 匹配 `ci.yml` 的 `pull_request` 触发条件，创建持续集成运行 | 一次 `pull_request` 运行，包含三个作业 | Actions → `CI` 运行列表 |
| 4 | 本机开发者或仓库维护者 | 拉取请求的检查结果 | 三个作业全部通过后点击合并 | `main` 上出现一个新的提交 | 提交记录 |
| 5 | GitHub 事件调度 | 推送到 `main` 的事件 | 再次匹配 `ci.yml` 的 `push` 触发条件 | 一次 `push` 运行 | Actions → `CI` 运行列表 |
| 6 | GitHub 事件调度 | 上面那次运行结束 | 匹配 `publish-images.yml` 的 `workflow_run` 触发条件 | 一次 `workflow_run` 运行进入等待或执行 | Actions → `PublishImage` 运行列表 |
| 7 | 发布作业的判定逻辑 | 上游运行的 `conclusion`、`event`、`head_branch` | 三个条件同时成立才继续 | 条件不成立时作业被跳过 | 运行详情中 `if` 段的判定结果 |
| 8 | 运行执行器 | 该次运行对应的 `head_sha` | 按检出的提交取出源码 | 工作区中出现被验证提交的源码 | 运行日志第 1 步 |
| 9 | 运行执行器 | 镜像库域名与所有者名称 | 把命名空间转成小写后写入环境文件 | 环境文件里出现 `IMAGE_NAMESPACE` | 日志「Compute lowercase image namespace」 |
| 10 | 运行执行器 | 短期 `GITHUB_TOKEN` | 登录镜像库 | 本地凭据配置中出现镜像库条目 | 日志「Log in to GHCR」 |
| 11 | 运行执行器 | 构建上下文与 Dockerfile | 构建后端镜像并推送 | 镜像库中出现标签为提交 SHA 的后端镜像 | 日志「Build and push the API image」、包页面 |
| 12 | 运行执行器 | 构建上下文与 Dockerfile | 构建前端镜像并推送 | 镜像库中出现标签为提交 SHA 的前端镜像 | 日志「Build and push the Web image」、包页面 |
| 13 | 镜像库 | 两次推送 | 创建或更新两个包，并记录发布者与来源仓库 | 包页面出现两个包 | `https://github.com/Duramentee?tab=packages` |

> 阶段 6 至阶段 12 属于本项目的工作流机制总结，已由本日实际运行复核。

## 四、预期与实测

### 4.1 执行前的预测（见 `code/week3/day4/README.md` §三）

| 问题 | 预测 | 实测 |
|---|---|---|
| 拉取请求触发且成功的持续集成会不会发布镜像 | 不会 | **通过**：`PublishImage` 的运行列表里只有 `#1` 一个运行 |
| 结论为失败的持续集成会不会触发发布 | 不会 | 未构造失败场景 |
| `github.sha` 与 `head_sha` 的差别 | 前者指向默认分支最新提交，后者指向被验证的提交 | **通过**：该次运行构建出的镜像标签为 `bcf6555f910b325ddc1ea49fc704fa8105f584be`，与 `main` 上的合并提交 `bcf6555` 完全一致 |
| 托管执行器与本地构建的镜像是否字节一致 | 不保证 | 未比较 |

### 4.2 实测记录

| 观察项 | 实测结果 |
|---|---|
| 发布运行编号与地址 | `PublishImage #1`，`https://github.com/Duramentee/shortener_proj_k8s/actions/runs/38837793900/job/116770696984` |
| 触发事件 | `workflow_run`（依据：本工作流只监听 `CI`，且该次运行出现在合并之后） |
| 检出的提交 | `bcf6555f910b325ddc1ea49fc704fa8105f584be`，与 `main` 上的合并提交 `bcf6555` 相同 |
| 作业结论与总耗时 | 作业 `ImagePublishing` 成功，总耗时 1 分 16 秒 |
| 各步骤耗时 | Set up job `0s`；Checkout the exact commit that CI validated `1s`；Compute lowercase image namespace `0s`；Log in to GHCR `1s`；Build and push the API image `57s`；Build and push the Web image `13s`；Post Checkout `0s`；Complete job `1s` |
| 镜像库中的包 | 出现 `shortener-api` 与 `shortener-web` 两个包，均显示 `Published 4 minutes ago by Lv Suxiang in Duramentee/shortener_proj_k8s` |
| 两个包的标签 | `shortener-api` 与 `shortener-web` 各有一个标签，取值都是 `bcf6555f910b325ddc1ea49fc704fa8105f584be` |
| 运行页面上的注释 | `Annotations 1 notice`，内容为执行器镜像迁移提示：`The ubuntu-latest label will migrate to Ubuntu 26 beginning October 19, 2026. For more information, see https://github.com/actions/runner-images/issues/14748`。该提示与本工作流的逻辑无关，只与执行器镜像有关 |
| 拉取请求阶段是否出现发布运行 | **没有**。`PublishImage` 的运行列表只有 `#1` 一个运行，出现在合并之后 |

### 4.3 与预测不符的地方

| 现象 | 说明 |
|---|---|
| 运行页面上出现一条提示 | 该提示说明 `ubuntu-latest` 标签将在 2026 年 10 月 19 日之后迁移到 Ubuntu 26。它属于执行器镜像的公告，不影响本工作流。需要记住的是：把 `runs-on` 写成 `ubuntu-latest` 意味着执行器镜像会随时间变化，需要固定环境时应当写出具体版本 |

## 五、当天新增的硬结论

只保留由运行结果支持的结论：

| 条件句 | 证据 |
|---|---|
| 当发布工作流的定义只存在于特性分支时，上游持续集成即使成功也不会触发它 | `PublishImage` 的运行列表只有 `#1` 一个运行，出现在合并之后 |
| 当 `main` 上以 push 事件触发的持续集成运行成功结束时，`workflow_run` 会触发发布工作流 | 出现 `PublishImage #1`，且作业 `ImagePublishing` 成功 |
| 当发布工作流只申请 `contents: read` 与 `packages: write` 时，检出、登录与两次推送都能完成 | 「Log in to GHCR」用时 `1s` 且成功；两个构建推送步骤成功 |
| 当两个镜像分别以各自的构建上下文构建并推送时，镜像库中出现两个相互独立的包 | 包页面同时列出 `shortener-api` 与 `shortener-web` |
| 当镜像标签使用完整提交 SHA 时，可以从标签定位到产生它的那一次提交 | 两个包的标签都是 `bcf6555f910b325ddc1ea49fc704fa8105f584be`，与 `main` 上的合并提交 `bcf6555`（PR #3）一致 |

## 六、命令与定位顺序

| 场景 | 命令或观察方式 | 说明 |
|---|---|---|
| 确认提交范围 | `git status --short` | 只提交本次相关文件，不把工作区里既有的未提交改动一起提交 |
| 查看工作流结构 | `grep -nE '^(name\|on\|permissions\|concurrency\|jobs):' <工作流文件>` | 快速确认顶层结构与权限段 |
| 检查行尾空白 | `grep -nP '\t\| +$' <工作流文件>` | 行尾空白不是语法错误，但会产生无关差异 |
| 确认工作流是否能被解析 | 在本地无法用 GitHub 的解析器；改由提交之后观察运行列表中是否出现该工作流 | 解析失败时 GitHub 会在 Actions 页面给出错误 |
| 定位发布未触发 | 先看 `CI` 在 `main` 上的运行结论，再看发布运行是否出现 | 上游失败时授权条件不成立，属于预期 |
| 定位登录失败 | 仓库 `Settings → Actions → General → Workflow permissions` | 只读设置会让 `packages: write` 不生效 |
| 核对镜像 | `https://github.com/<所有者>?tab=packages` | 查看包、标签与来源提交 |

## 七、十分钟速记卡

| 项目 | 内容 |
|---|---|
| 一句话定义 | `workflow_run` 监听另一个工作流的运行完成；发布工作流据此把镜像构建与推送绑定在「main 上成功的 push 持续集成」之后；镜像标签使用完整提交 SHA |
| 必须记住的字段 / 键 | `on.workflow_run.workflows`、`on.workflow_run.types`、`on.workflow_run.branches`、`github.event.workflow_run.conclusion`、`.event`、`.head_branch`、`.head_sha`、`permissions.contents`、`permissions.packages`、`actions/checkout` 的 `with.ref` |
| 全流程链路摘要 | 提交 → 特性分支 → 拉取请求 → `CI`（`pull_request`）→ 合并 → `main` 的 push → `CI`（`push`）成功 → `workflow_run` 触发 `PublishImage` → 检出 `head_sha` → 登录 GHCR → 构建并推送两个镜像 → 镜像库出现两个包与 SHA 标签 |
| 当天实测硬结论 | ① 两个镜像的构建推送分别用时 `57s` 与 `13s`，作业总耗时 1 分 16 秒；② 登录步骤用时 `1s`，说明使用短期凭据登录不需要额外等待；③ 镜像库中出现 `shortener-api` 与 `shortener-web` 两个包，来源标记为 `Duramentee/shortener_proj_k8s`；④ 两个包的标签都是 `bcf6555f910b325ddc1ea49fc704fa8105f584be`，等于 `main` 上合并提交 `bcf6555` 的完整 SHA，说明构建源码与被验证源码是同一个提交 |
| 面试问答卡 | **问：为什么发布要单独做一份工作流，而不是在持续集成里直接构建镜像？答：持续集成会在尚未合并的拉取请求上运行不可信代码，而推送镜像需要软件包写入权限；把两步放在同一份工作流里，等于让未合并的代码也有机会拿到写权限。拆开之后，持续集成保持只读，发布工作流只在 main 上成功的 push 持续集成之后运行。** |
| 异常排查顺序 | 先确认上游持续集成是否在 main 上成功 → 再确认发布运行是否出现 → 再看失败的步骤 → 登录失败查仓库的工作流权限设置 → 推送失败查命名空间大小写与包可见性设置 |
| 最容易答错 | 把 `workflow_run` 理解成「push 之后自动运行」；忽略「工作流定义必须先在默认分支存在」这一前提；在发布工作流里使用 `github.sha` 而不是 `head_sha`；认为权限可以只在单个作业上收紧 |
| 合上笔记自测 | ① `workflow_run` 与 `push` 两种触发方式的差别是什么？② 为什么构建源码必须取 `head_sha`？③ 为什么失败的上游运行不会发布镜像？④ 镜像标签为什么不用 `latest`？ |
