
#!/bin/bash

SCRIPT_PATH="/opt/stress/stress_monitor.sh"
# 每5分钟检查一次，脚本内部会处理时间窗口和频率限制
CRON_JOB="*/15 * * * * /bin/bash ${SCRIPT_PATH}"

# 确保脚本存在且有执行权限
if [ ! -f "$SCRIPT_PATH" ]; then
    echo "Error: Script not found at $SCRIPT_PATH"
    exit 1
fi

chmod +x "$SCRIPT_PATH"

# 检查是否已存在相同的 cron 任务
if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH"; then
    echo "Cron job already exists."
else
    # 添加 cron 任务
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    echo "Cron job added successfully."
fi

# 重启 cron 服务以确保生效 (Ubuntu 18.04)
sudo service cron restart
echo "Cron service restarted."

