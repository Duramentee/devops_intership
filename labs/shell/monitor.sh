#!/bin/bash
# ===== 配置区 =====
THRESHOLD=80                                # 告警阈值（百分比）
LOG_FILE="/tmp/monitor.log"                 # 告警日志

# ===== 1. 用 free 取内存数据（取 Mem: 那一行，$2=total $3=used，单位 MB） =====
total=$(free -m | awk '/^Mem:/ {print $2}')
used=$(free -m  | awk '/^Mem:/ {print $3}')

# ===== 2. 计算使用率 =====
# 用 awk 做浮点计算（bc 也可）；先乘 100 再除避免整数截断为 0
usage=$(awk -v u="$used" -v t="$total" 'BEGIN {printf "%.1f", u/t*100}')

# ===== 3. 超阈值则告警 + 记录日志（邮件用 echo 模拟） =====
if awk -v x="$usage" -v y="$THRESHOLD" 'BEGIN {exit !(x > y)}'; then
    msg="[$(date '+%F %T')] 警告: 内存使用率 ${usage}% 超过阈值 ${THRESHOLD}% (used=${used}MB/total=${total}MB)"
    echo "$msg" >> "$LOG_FILE"
    echo "邮件模拟: $msg"        # 真实环境可换成 mail -s "内存告警" root@localhost
else
    echo "[$(date '+%F %T')] 正常: 内存使用率 ${usage}%"
fi