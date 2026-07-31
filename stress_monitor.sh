#!/bin/bash

# 配置参数
LOG_DIR="/opt/stress"
LOG_FILE="${LOG_DIR}/stress_run.log"
MAX_LOG_SIZE_MB=600
CPU_THRESHOLD=25
MEM_THRESHOLD=65
MONTHLY_EXEC_DAYS=8 # 一个月内执行的天数上限
DAILY_EXEC_TIMES=2  # 一天内执行的次数上限
START_HOUR=9        # 开始时间 9:00
END_HOUR=18         # 结束时间 18:00 (包含17:59)
SLOT_EXPIRE_DAYS=90
USED_TIME_SLOT_FILE="$LOG_DIR/all_used_time_slots.list"

# 确保日志目录存在
mkdir -p "$LOG_DIR"
[ ! -f "$USED_TIME_SLOT_FILE" ] && touch "$USED_TIME_SLOT_FILE"

# 函数：获取当前日期字符串 YYYY-MM-DD
get_current_date_str() {
    date +"%Y-%m-%d"
}

# 函数：获取当前月份字符串 YYYY-MM
get_current_month_str() {
    date +"%Y-%m"
}

# 函数：获取今日执行记录文件
get_today_exec_file() {
    local today=$(get_current_date_str)
    echo "${LOG_DIR}/exec_count_${today}.list"
}

# 函数：获取本月执行日期记录文件
get_month_exec_file() {
    local month=$(get_current_month_str)
    echo "${LOG_DIR}/exec_days_${month}.list"
}

# 函数：检查当前时间是否在允许的时间窗口内 (9:00 - 17:59)
is_within_time_window() {
    local current_hour=$(date +"%H")
    current_hour=$((10#$current_hour))
    
    if [ "$current_hour" -ge "$START_HOUR" ] && [ "$current_hour" -lt "$END_HOUR" ]; then
        return 0
    else
        return 1
    fi
}

# 函数：检查今日是否已达到执行次数限制
is_daily_limit_reached() {
    local exec_file=$(get_today_exec_file)
    if [ ! -f "$exec_file" ]; then
        return 1
    fi
    
    local count=$(wc -l < "$exec_file" | tr -d ' ')
    [ -z "$count" ] && count=0
    if [ "$count" -ge "$DAILY_EXEC_TIMES" ]; then
        return 0
    else
        return 1
    fi
}

# 函数：记录一次执行
record_execution() {
    local today_file=$(get_today_exec_file)
    local month_file=$(get_month_exec_file)
    local current_day_of_month=$(date +"%d")
    local current_time_slot=$(date +"%H:%M")
    local current_full_day=$(get_current_date_str())
    
    # 记录今日执行时间戳
    echo "$(date '+%H:%M:%S')" >> "$today_file" || echo "Failed to write to $today_file"
    
    # 记录本月执行日期
    if [ -f "$month_file" ]; then
        if ! grep -q "^${current_day_of_month}$" "$month_file"; then
            echo "${current_day_of_month}" >> "$month_file" || echo "Failed to write to $month_file"
        fi
    else
        echo "${current_day_of_month}" >> "$month_file" || echo "Failed to write to $month_file"
    fi

    echo "$current_time_slot $current_full_day" >> "$USED_TIME_SLOT_FILE" || echo "Failed to write to $USED_TIME_SLOT_FILE"
}

# 函数：获取本月已执行的不同天数
get_monthly_executed_days_count() {
    local month_file=$(get_month_exec_file)
    if [ -f "$month_file" ]; then
        sort -u "$month_file" | wc -l | tr -d ' '
    else
        echo 0
    fi
}

# 函数：清理旧的执行记录文件（保留最近3个月）
cleanup_old_records() {
    find "$LOG_DIR" -name "exec_count_*.list" -mtime +30 -delete
    find "$LOG_DIR" -name "exec_days_*.list" -mtime +90 -delete
}

# 函数：清理过期的时间点记录
cleanup_expired_time_slots() {
    local current_timestamp_sec=$(date +%s)
    awk -v now="$current_timestamp_sec" -v expire_days="$SLOT_EXPIRE_DAYS" '
    {
        slot_date = $2
        split(slot_date, d, "-")
        slot_sec = mktime(d[1] " " d[2] " " d[3] " 0 0 0")
        if ((now - slot_sec) < (expire_days * 86400)) print $0
    }
    ' "$USED_TIME_SLOT_FILE" > "${USED_TIME_SLOT_FILE}.tmp"
    mv "${USED_TIME_SLOT_FILE}.tmp" "$USED_TIME_SLOT_FILE"
}

# 检查当前时间点是否在占用列表中
is_time_slot_occupied() {
    local current_time_slot=$(date +"%H:%M")
    grep -q "^$current_time_slot " "$USED_TIME_SLOT_FILE"
    return $?
}

# 函数：检查并清理日志文件大小
check_and_clean_log() {
    if [ -f "$LOG_FILE" ]; then
        local size_mb=$(du -m "$LOG_FILE" | cut -f1)
        if [ "$size_mb" -gt "$MAX_LOG_SIZE_MB" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Log file size ${size_mb}MB exceeds limit ${MAX_LOG_SIZE_MB}MB. Clearing log." >> "$LOG_FILE"
            echo > "$LOG_FILE"
            echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Log file cleared." >> "$LOG_FILE"
        fi
    fi
}

# 函数：获取CPU使用率
get_cpu_usage() {
    local idle=$(top -bn1 | grep "Cpu(s)" | sed -E 's/.*, *([0-9.]+)%* id.*/\1/')
    if [ -z "$idle" ]; then
        idle=$(vmstat 1 2 | tail -1 | awk '{print $15}')
    fi
    
    if [ -z "$idle" ]; then
        echo "100"
        return
    fi
    
    local usage=$(awk "BEGIN {printf \"%d\", 100 - $idle}")
    echo "$usage"
}

# 函数：获取内存使用率
get_mem_usage() {
    local mem_total=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    local mem_free=$(awk '/MemFree/ {print $2}' /proc/meminfo)
    local mem_avail=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
    
    if [ -z "$mem_avail" ]; then
        mem_avail=$mem_free
    fi

    if [ "$mem_total" -eq 0 ]; then
        echo "100"
        return
    fi
    
    local used=$((mem_total - mem_avail))
    local usage=$(awk "BEGIN {printf \"%d\", ($used / $mem_total) * 100}")
    echo "$usage"
}

# 函数：终止所有stress进程
kill_stress_processes() {
    pkill -f "stress --cpu"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Killed all existing stress processes." >> "$LOG_FILE"
}

# 主逻辑
main() {
    cleanup_old_records
    cleanup_expired_time_slots
    
    check_and_clean_log
    
    if ! is_within_time_window; then
        exit 0
    fi

    if is_time_slot_occupied; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [SKIP] Current time slot $(date +"%H:%M") is still in quarterly occupation period, skip." >> "$LOG_FILE"
        exit 0
    fi
    
    local monthly_count=$(get_monthly_executed_days_count)
    if [ "$monthly_count" -ge "$MONTHLY_EXEC_DAYS" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [SKIP] Monthly execution limit (${MONTHLY_EXEC_DAYS} days) reached." >> "$LOG_FILE"
        exit 0
    fi
    
    if is_daily_limit_reached; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [SKIP] Daily execution limit (${DAILY_EXEC_TIMES} times) reached." >> "$LOG_FILE"
        exit 0
    fi
    
    local cpu_usage=$(get_cpu_usage)
    local mem_usage=$(get_mem_usage)
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Current CPU Usage: ${cpu_usage}%, Mem Usage: ${mem_usage}%" >> "$LOG_FILE"
    
    # 终止之前的stress进程
    kill_stress_processes
    
    local has_executed=false
    if [ "$cpu_usage" -lt "$CPU_THRESHOLD" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [ACTION] CPU usage ${cpu_usage}% < ${CPU_THRESHOLD}%, starting stress --cpu 4" >> "$LOG_FILE"
        stress --cpu 4 &
        has_executed=true
    fi

    if [ "$mem_usage" -lt "$MEM_THRESHOLD" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [ACTION] Mem usage ${mem_usage}% < ${MEM_THRESHOLD}%, starting memory stress task" >> "$LOG_FILE"
        stress --vm-bytes $(awk '/MemFree/{printf "%d\n", ($2 * 0.7)}' /proc/meminfo)k --vm-keep -m 1 -t 600 &
        has_executed=true
    fi

    if [ "$has_executed" = true ]; then
        record_execution
    fi
}

main

