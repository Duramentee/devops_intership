# Day 7 · 复盘 + 自测 + 上仓库

> 目标：把 Day 1~6 的产出整理成**别人能看懂、能复现**的作品推到 GitHub，再用 10 题混合自测把盲区钉出来。
> 配套：`plan/week1/任务明细.md` Day 7 节 · `docs/linux/Linux-每日一题.md` Day 7（综合找 bug）
> 笔记落点：`notes/week1/day7.md`
> **验收标准**：① GitHub 上 **≥7 次 commit**（commit 历史就是学习证据）② `docker images` 里 `webapp:v2` < **50MB** ③ `curl localhost:8080` 有响应

---

## 一、今日流程

| 顺序 | 时段 | 做什么 | 产出 |
|---|---|---|---|
| 0 | 15 min | **开场抽背**（Day 6 的坑）：能力位怎么读 / 非 root 时 `--cap-add` 为什么无效 / 三道闸门 | 口述 |
| 1 | 20 min | 推之前自查（第二节 3 条命令） | 3 条原始输出 |
| 2 | 60 min | **自己写**发布版 `Dockerfile` + `.dockerignore` + `README.md`（见第三节，只给问题不给代码） | 3 个文件 |
| 3 | 30 min | 验收三件套：镜像大小 / `curl` / 容器身份 | 实测输出 |
| 4 | 20 min | 推到 GitHub（本周第 7 次 commit） | 远端可见 |
| 5 | 20 min | **Linux 每日一题**（Day 7：综合找 bug，3 个 bug） | 答案 |
| 6 | 40 min | **10 题混合自测**（在 `notes/week1/day7.md` 里答，先自己写） | 答案 |
| 7 | 20 min | 更新 `plan/求职学习计划.md` 勾选表 + 四段收尾 | 笔记 |

> **铁律不变：先做后看。** 第三节的发布文件必须自己写完再对照任何参考。

---

## 二、推之前自查（先跑这 3 条，只抄输出）

| # | 命令 | 看什么 | 期望 |
|---|---|---|---|
| 1 | `git status -s` | 有没有意外文件（`webapp` 二进制 / `*.log` / `.env`） | 只有你今天真想提交的东西 |
| 2 | `git log --oneline \| wc -l` | commit 数 | **≥ 7**（Day1~6 是否每天各一次） |
| 3 | `git ls-files \| grep -E 'assets/pdf\|\.pdf$'` | PDF 有没有被跟踪 | **输出为空**才对（版权书 + 体积大） |

> ⚠️ 第 3 条若**非空**：不要直接 `git rm` 完事 —— 历史里已经有了，先记下来，今天先学会「加 `.gitignore` 阻止新增」，历史清理留到第 5 周学 Actions 之前处理。

---

## 三、发布清单（这三个文件是"作品"，必须自己写）

### 1. `Dockerfile`（发布版 = Day 6 加固版，收敛掉教学注释）

| # | 必须回答的问题 | 你用的指令 / 参数 |
|---|---|---|
| 1 | 构建阶段和运行阶段为什么分开？各用什么底座？ | |
| 2 | 依赖层和代码层的顺序怎么排，为什么？ | |
| 3 | 二进制怎么从 builder 捞过来，属主怎么带？ | |
| 4 | 运行身份是什么？端口为什么选 8080？ | |
| 5 | 健康检查的判定语义是什么（哪个退出码算健康）？ | |
| 6 | 启动命令用哪种 form？为什么？ | |

### 2. `.dockerignore`（至少覆盖哪几类）

| 类别 | 例 | 不排除会怎样 |
|---|---|---|
| 版本控制 | `.git` | 体积 + 历史泄露 |
| 本地构建产物 | `webapp` | **覆盖镜像内真实产物**（Day 2 的坑） |
| 日志 | `*.log` | 体积 |
| 文档 / 笔记 | `*.md`（除需要的） | 无意义层 |
| 密钥 / 证书 / `.env` | `.env`、`/secure` | 直接进镜像，永久留在层里 |

### 3. `README.md`（**给面试官看的**，回答这 5 个问题就够）

| # | 必须写清的内容 |
|---|---|
| 1 | 这是什么服务、提供什么接口（`GET /` → `<h1>Hello DevOps</h1>`） |
| 2 | **怎么构建**：完整 `docker build` 命令 |
| 3 | **怎么运行**：完整 `docker run` 命令（含端口映射、加固参数） |
| 4 | **怎么验证**：`curl` / `docker ps` 期望看到什么（贴实测输出） |
| 5 | 镜像瘦身证据：单阶段 → 多阶段 → 加固，各自多大 |

> 写作要求：**命令要能被他人的机器直接粘走跑通**。写完自己按 README 从头跑一遍，跑不通就改 README。

---

## 四、git 命令表（今天新增）

| 场景 | 命令 | 说明 |
|---|---|---|
| 看工作区状态（短格式） | `git status -s` | `M` 改过、`??` 未跟踪；比长格式省屏 |
| 只暂存今天的产物 | `git add code/week1/day7 notes/week1/day7.md plan/` | **不要 `git add -A`** 一把梭（容易带进二进制） |
| 看"这次到底要提交什么" | `git diff --cached --stat` | 提交前最后一道闸门，看清文件清单与体积 |
| 看历史（验收用） | `git log --oneline` / `... \| wc -l` | 数 commit 数 |
| 提交 | `git commit -m "day7: 发布版 Dockerfile/README + 一周复盘"` | 信息写"做了什么"，不写"修改了一下" |
| 推送 | `git push` | 已设上游（`origin/main`）直接推；新分支用 `git push -u origin <branch>` |
| 确认远端一致 | `git log --oneline -1` ↔ GitHub 页面最后一条 | 两边哈希相同才算真的推上去了 |
| 看某个文件的逐行历史 | `git log -p -- code/week1/day6/Dockerfile` | 面试常问「你怎么迭代的」，这个能当证据 |
| 提交前撤销暂存 | `git restore --staged <file>` | 反悔不丢内容 |
| 提交前丢弃本地改动 | `git restore <file>` | ⚠️ 内容直接没，慎用 |

---

## 五、验收对照

| 验收项 | 命令 | 期望输出 |
|---|---|---|
| 镜像大小 | `docker images webapp` | `v2` 一列 < **50MB**（当前 25.3MB） |
| 接口活着 | `docker run -d -p 8080:8080 --name web7 webapp:v4` + `curl localhost:8080` | `<h1>Hello DevOps</h1>` |
| 身份非 root | `docker inspect -f '{{.Config.User}}' webapp:v4` | `10001:10001` |
| 健康 | `docker ps --format 'table {{.Names}}\t{{.Status}}'` | `Up ... (healthy)` |
| commit 数 | `git log --oneline \| wc -l` | ≥ 7 |
| 远端同步 | GitHub 仓库页 | 最新 commit 与本地一致 |

---

## 六、10 题混合自测

题目与答题区在 `notes/week1/day7.md`。**先自己写完再发我批改** —— 这道题的目的是暴露盲区，不是拿满分。
