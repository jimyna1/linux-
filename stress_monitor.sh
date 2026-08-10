#!/bin/bash

# 配置参数
LOG_DIR="/opt/stress"
LOG_FILE="${LOG_DIR}/stress_run.log"
MAX_LOG_SIZE_MB=600
CPU_THRESHOLD=25
MEM_THRESHOLD=65
MONTHLY_EXEC_DAYS=8
DAILY_EXEC_TIMES=2
START_HOUR=9
END_HOUR=18
SLOT_EXPIRE_DAYS=90
USED_TIME_SLOT_FILE="$LOG_DIR/all_used_time_slots.list"
STRESS_PID_FILE="${LOG_DIR}/stress_running.pid"

mkdir -p "$LOG_DIR"
[ ! -f "$USED_TIME_SLOT_FILE" ] && touch "$USED_TIME_SLOT_FILE"
chmod 755 "$LOG_DIR"

get_current_date_str() {
    date +"%Y-%m-%d"
}

get_current_month_str() {
    date +"%Y-%m"
}

get_today_exec_file() {
    local today=$(get_current_date_str)
    echo "${LOG_DIR}/exec_count_${today}.list"
}

get_month_exec_file() {
    local month=$(get_current_month_str)
    echo "${LOG_DIR}/exec_days_${month}.list"
}

is_within_time_window() {
    local current_hour=$(date +"%H")
    current_hour=$((10#$current_hour))
    if [ "$current_hour" -ge "$START_HOUR" ] && [ "$current_hour" -lt "$END_HOUR" ]; then
        return 0
    else
        return 1
    fi
}

is_daily_limit_reached() {
    local exec_file=$(get_today_exec_file)
    [ ! -f "$exec_file" ] && touch "$exec_file"
    local count=$(wc -l < "$exec_file" | tr -d ' ')
    [ -z "$count" ] && count=0
    if [ "$count" -ge "$DAILY_EXEC_TIMES" ]; then
        return 0
    else
        return 1
    fi
}

record_execution() {
    local today_file=$(get_today_exec_file)
    local month_file=$(get_month_exec_file)
    local current_day_of_month=$(date +"%d")
    local current_time_slot=$(date +"%H:%M")
    local current_full_day=$get_current_date_str()
    [ ! -f "$today_file" ] && touch "$today_file"
    echo "$(date '+%H:%M:%S')" >> "$today_file"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [DEBUG] 执行计数文件${today_file}写入成功，当前累计执行行数: $(wc -l < "$today_file")" >> "$LOG_FILE"
    [ ! -f "$month_file" ] && touch "$month_file"
    if ! grep -q "^${current_day_of_month}$" "$month_file"; then
        echo "${current_day_of_month}" >> "$month_file"
        echo "$(date '+%Y-%m-%d %H:%M:%S') [DEBUG] 月度执行日期文件${month_file}写入成功，当日日期${current_day_of_month}已登记" >> "$LOG_FILE"
    fi
    echo "$current_time_slot $current_full_day" >> "$USED_TIME_SLOT_FILE"
}

get_monthly_executed_days_count() {
    local month_file=$(get_month_exec_file)
    [ ! -f "$month_file" ] && touch "$month_file"
    sort -u "$month_file" | wc -l | tr -d ' '
}

cleanup_old_records() {
    find "$LOG_DIR" -name "exec_count_*.list" -mtime +30 -delete
    find "$LOG_DIR" -name "exec_days_*.list" -mtime +90 -delete
}

cleanup_expired_time_slots() {
    local current_timestamp_sec=$(date +%s)
    awk -v now="$current_timestamp_sec" -v expire_days="$SLOT_EXPIRE_DAYS" '
    {
        slot_date = $2
        split(slot_date, d, "-")
        slot_sec = mktime(d " " d " " d " 0 0 0")
        if ((now - slot_sec) < (expire_days * 86400)) print $0
    }
    ' "$USED_TIME_SLOT_FILE" > "${USED_TIME_SLOT_FILE}.tmp"
    mv "${USED_TIME_SLOT_FILE}.tmp" "$USED_TIME_SLOT_FILE"
}

is_time_slot_occupied() {
    local current_time_slot=$(date +"%H:%M")
    grep -q "^$current_time_slot " "$USED_TIME_SLOT_FILE"
    return $?
}

check_and_clean_log() {
    if [ -f "$LOG_FILE" ]; then
        local size_mb=$(du -m "$LOG_FILE" | cut -f1)
        if [ "$size_mb" -gt "$MAX_LOG_SIZE_MB" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] 日志文件大小${size_mb}MB超过上限${MAX_LOG_SIZE_MB}MB，开始清空" >> "$LOG_FILE"
            echo > "$LOG_FILE"
            echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] 日志文件清空完成" >> "$LOG_FILE"
        fi
    fi
}
get_cpu_usage() {
    local idle
    idle=$(top -bn 2 -d 0.1 | grep "Cpu(s)" | tail -n 1 | sed -E 's/.*, *([0-9.]+)%* id.*/\1/')
    # 如果提取失败或为空，默认使用 100（即 CPU 使用率为 0%)
    if [ -z "$idle" ] || ! [[ "$idle" =~ ^[0-9.]+$ ]]; then
        echo "0"
        return
    fi
    # 使用awk确保输出为整数，避免后续比较报错
    awk -v idle_val="$idle" 'BEGIN{printf "%.0f", 100 - idle_val}'
}
get_mem_usage() {
    local mem_total mem_free mem_avail
    mem_total=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    mem_free=$(awk '/MemFree/ {print $2}' /proc/meminfo)
    mem_buffers=$(awk '/Buffers/ {print $2}' /proc/meminfo)
    mem_cached=$(awk '/Cached/ {print $2}' /proc/meminfo)
    mem_avail=$((mem_free + mem_buffers + mem_cached))
    if [ "$mem_total" -eq 0 ]; then
        echo "100"
        return
    fi
    awk -v total="$mem_total" -v avail="$mem_avail" 'BEGIN{printf "%.0f", ((total - avail)/total)*100}'
}

kill_stress_processes() {
    if [ -f "$STRESS_PID_FILE" ]; then
        local old_pid=$(cat "$STRESS_PID_FILE")
        if ps -p "$old_pid" > /dev/null 2>&1; then
            kill -9 "$old_pid"
            echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] 终止上次遗留的stress进程 PID: $old_pid" >> "$LOG_FILE"
        fi
        rm -f "$STRESS_PID_FILE"
    fi
}

main() {
    kill_stress_processes
    sleep 240
    cleanup_old_records
    cleanup_expired_time_slots
    check_and_clean_log
    if ! is_within_time_window; then
        exit 0
    fi
    if is_time_slot_occupied; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [SKIP] 当前时间点$(date +"%H:%M")仍在90天占用周期内，跳过执行" >> "$LOG_FILE"
        exit 0
    fi
    local monthly_count=$(get_monthly_executed_days_count)
    echo "$(date '+%Y-%m-%d %H:%M:%S') [DEBUG] 当前本月已执行天数: ${monthly_count}" >> "$LOG_FILE"
    if [ "$monthly_count" -ge "$MONTHLY_EXEC_DAYS" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [SKIP] 月度执行上限${MONTHLY_EXEC_DAYS}天已达到，退出" >> "$LOG_FILE"
        exit 0
    fi
    if is_daily_limit_reached; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [SKIP] 当日执行上限${DAILY_EXEC_TIMES}次已达到，退出" >> "$LOG_FILE"
        exit 0
    fi
    local cpu_usage=$(get_cpu_usage)
    local mem_usage=$(get_mem_usage)
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] 当前CPU使用率: ${cpu_usage}%, 当前内存使用率: ${mem_usage}%" >> "$LOG_FILE"
    local has_executed=false
    if [ "$cpu_usage" -lt "$CPU_THRESHOLD" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [ACTION] CPU使用率${cpu_usage}% < ${CPU_THRESHOLD}%，启动stress --cpu 4" >> "$LOG_FILE"
        stress --cpu 4 -t 600 &
        echo $! > "$STRESS_PID_FILE"
        has_executed=true
    fi
    if [ "$mem_usage" -lt "$MEM_THRESHOLD" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [ACTION] 内存使用率${mem_usage}% < ${MEM_THRESHOLD}%，启动内存压测" >> "$LOG_FILE"
        stress --vm-bytes $(awk '/MemFree/{printf "%d\n", ($2 * 0.7)}' /proc/meminfo)k --vm-keep -m 1 -t 600 &
        echo $! >> "$STRESS_PID_FILE"
        has_executed=true
    fi
    if [ "$has_executed" = true ]; then
        record_execution
    fi
}

main "$@"

