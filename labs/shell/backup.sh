#!/bin/bash

# ===== 配置区 =====
APP_DIR="/home/drow/devops-practice/app"          # 要备份的目录
BACKUP_DIR="/home/drow/devops-practice/backup"    # 备份存放目录
LOG_FILE="/tmp/backup.log"                        # 日志文件
KEEP_DAYS=7                                       # 保留天数
DATE=$(date +%Y%m%d)                              # 日期，如 20250910
ARCHIVE="${BACKUP_DIR}/app_backup_${DATE}.tar.gz" # 备份文件名

# ===== 检查源目录是否存在 =====
if [[ ! -d "${SOURCE_DIR}" ]]; then
    echo "[$(date '+%F %T')] 备份失败: 源目录不存在 ${SOURCE_DIR}" >> "${LOGFILE}"
    exit 1
fi

# ===== 1. 确保备份目录存在（-p 已存在不报错） =====
mkdir -p "$BACKUP_DIR"

# ===== 2. 打包压缩 app 目录（-C 切到父目录，只存 app 相对路径） =====
tar -czf "$ARCHIVE" -C "$(dirname "$APP_DIR")" "$(basename "$APP_DIR")"
result=$?                                         # 捕获上条命令退出码

# ===== 3. 写日志 =====
if [ $result -eq 0 ]; then
    echo "[$(date '+%F %T')] 备份成功: $ARCHIVE" >> "$LOG_FILE"
else
    echo "[$(date '+%F %T')] 备份失败: $ARCHIVE" >> "$LOG_FILE"
    exit 1
fi

# ===== 4. 删除 7 天前的旧备份（用 +7 天；-delete 或 -exec rm） =====
find "$BACKUP_DIR" -name 'app_backup_*.tar.gz' -mtime +$KEEP_DAYS -exec rm -f {} +