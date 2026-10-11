#!/usr/bin/env bash
# observe.skeleton.sh —— 基线采集与差异比对的骨架（第 2 周周末使用，第 3 周继续沿用）
#
# 设计目的：把「人工执行命令并把输出抄进笔记」替换为「两次采集加一次差异比对」。
#           先采集一份基线，做出变更之后再采集一份，最后只读两份采集之间的差异。
#           这样需要人工阅读的内容从「全部输出」缩减为「发生变化的那几行」。
#
# 用法：
#   ./observe.skeleton.sh snapshot baseline   # 变更之前采集基线
#   ./observe.skeleton.sh snapshot after      # 做出变更之后再采集一次
#   ./observe.skeleton.sh diff                # 只输出两份采集之间的差异
#
# 需要你自己补全的地方只有一个：下面 COLLECT_ITEMS 数组中的每一项。
# 每一项的格式是「输出文件名:要执行的命令」。命令必须只读取状态，不允许修改任何对象。

set -uo pipefail

NS="${NS:-default}"
DIR="${DIR:-outputs/observe}"
STAMP="$(date '+%Y%m%d-%H%M%S')"

# 每一项的格式为「输出文件名:要执行的命令」。
# 下面是三场故障演练各自需要采集的对象示例，请按照你的实际情况改成只读命令。
COLLECT_ITEMS=(
  # 演练 1：Service 的选择器被改错（需要观察端点列表与 Service 定义）
  "svc.txt:kubectl get svc -o wide -n $NS"
  "endpoints.txt:kubectl get endpoints -n $NS"
  "pod-labels.txt:kubectl get po --show-labels -n $NS"

  # 演练 2：镜像标签在节点镜像库中不存在（需要观察 Pod 状态、事件与 Deployment 状态）
  "pod.txt:kubectl get pod -o wide -n $NS"
  "deploy.txt:kubectl get deploy -o wide -n $NS"
  "rs.txt:kubectl get rs -n $NS"
  "events.txt:kubectl get events --sort-by=.lastTimestamp -n $NS"

  # 演练 3：就绪探针指向不存在的路径（需要观察就绪列、重启列与端点列表）
  "po-jsonpath.txt:kubectl get po -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount"

  # TODO: 用上面这些示例的写法补全清单。
  # 演练 4：采集 ConfigMap 和 Secret
  "configmap.txt:kubectl get cm -o wide"
  "secret.txt:kubectl get secret -o wide"
)

# 采集指定快照名称对应的全部条目。
collect() {
  local snapshot="$1"
  local target="${DIR}/${snapshot}"
  rm -rf "$target"
  mkdir -p "$target"

  if [ "${#COLLECT_ITEMS[@]}" -eq 0 ]; then
    echo "COLLECT_ITEMS 数组是空的，请先补全其中的采集条目。" >&2
    exit 1
  fi

  local item name cmd
  for item in "${COLLECT_ITEMS[@]}"; do
    name="${item%%:*}"
    cmd="${item#*:}"
    {
      echo "### ${cmd}"
      echo "### 快照=${snapshot} 时间=${STAMP}"
      eval "$cmd"
    } >"${target}/${name}" 2>&1
    echo "已写出 ${target}/${name}"
  done
}

# 比对基线快照与变更后快照之间的差异，只输出发生变化的部分。
compare() {
  local base="${DIR}/baseline"
  local after="${DIR}/after"

  if [ ! -d "$base" ] || [ ! -d "$after" ]; then
    echo "缺少快照目录：请先分别执行 snapshot baseline 与 snapshot after。" >&2
    exit 1
  fi

  local file
  local changed=0
  for file in "$base"/*; do
    [ -e "$file" ] || continue
    local name
    name="$(basename "$file")"
    if [ ! -e "${after}/${name}" ]; then
      echo "== ${name}：只在基线快照中存在 =="
      changed=1
      continue
    fi
    if ! diff -q "$file" "${after}/${name}" >/dev/null; then
      echo "== ${name}：发生了下面的变化 =="
      diff -u "$file" "${after}/${name}" || true
      changed=1
    fi
  done

  for file in "$after"/*; do
    [ -e "$file" ] || continue
    local name
    name="$(basename "$file")"
    [ -e "${base}/${name}" ] || {
      echo "== ${name}：只在变更后快照中存在 =="
      changed=1
    }
  done

  if [ "$changed" -eq 0 ]; then
    echo "两份快照完全相同，也就是说本次变更没有在采集范围内产生可观察的变化。"
  fi
}

case "${1:-}" in
  snapshot)
    collect "${2:-}"
    ;;
  diff)
    compare
    ;;
  *)
    echo "用法：$0 snapshot <baseline|after>   或者   $0 diff" >&2
    exit 1
    ;;
esac
