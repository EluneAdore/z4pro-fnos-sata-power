#!/bin/bash

# SATA 电源控制脚本（极空间 Z4 Pro 硬件 GPIO 映射）
# 飞牛 fnOS 适配：优先 sysfs 读基址；必要时自动挂载 debugfs（精简系统常未挂 debug）

DRIVER_NAME="sata-power-control"
DEBUG_GPIO_FILE="/sys/kernel/debug/gpio"
SYSFS_GPIOCHIP0_BASE="/sys/class/gpio/gpiochip0/base"

# legacy: 全局编号 /sys/class/gpio/gpioN；chip: 仅 gpiochip 下按偏移 export（新内核常见）
GPIO_MODE=""
GPIO_CHIP_DIR=""

# SATA 线在 gpiochip0 上的硬件偏移（与极空间 Z4 Pro 一致）
GPIO_OFFSETS=(17 16 8 7)

is_all_digits() {
    [[ -n "$1" && -z "${1//[0-9]/}" ]]
}

# 检测 sysfs 工作方式（飞牛等新内核可能去掉全局 export）
detect_gpio_mode() {
    GPIO_MODE=""
    GPIO_CHIP_DIR=""
    local d
    for d in /sys/class/gpio/gpiochip0 /sys/bus/gpio/devices/gpiochip0; do
        if [[ -d "$d" && -f "$d/export" ]]; then
            GPIO_CHIP_DIR="$d"
            break
        fi
    done

    if [[ -f /sys/class/gpio/export ]]; then
        GPIO_MODE="legacy"
        return 0
    fi
    if [[ -n "$GPIO_CHIP_DIR" ]]; then
        GPIO_MODE="chip"
        log_warn "使用 chip 级 GPIO export（无全局 /sys/class/gpio/export）"
        return 0
    fi
    return 1
}

gpio_value_path() {
    local id=$1
    if [[ "$GPIO_MODE" == "legacy" ]]; then
        echo "/sys/class/gpio/gpio${id}/value"
    else
        echo "$GPIO_CHIP_DIR/gpio${id}/value"
    fi
}

gpio_direction_path() {
    local id=$1
    if [[ "$GPIO_MODE" == "legacy" ]]; then
        echo "/sys/class/gpio/gpio${id}/direction"
    else
        echo "$GPIO_CHIP_DIR/gpio${id}/direction"
    fi
}

gpio_exported_dir() {
    local id=$1
    if [[ "$GPIO_MODE" == "legacy" ]]; then
        echo "/sys/class/gpio/gpio${id}"
    else
        echo "$GPIO_CHIP_DIR/gpio${id}"
    fi
}

# 终端样式（Z4PRO_LOG_PLAIN=1 或 NO_COLOR=1 或非 TTY 时关闭颜色与符号）
C_RST='\033[0m'
C_DIM='\033[2m'
C_BOLD='\033[1m'
C_RED='\033[0;31m'
C_GRN='\033[0;32m'
C_YEL='\033[1;33m'
C_CYN='\033[0;36m'
C_BLU='\033[0;34m'

_log_use_color() {
    [[ "${Z4PRO_LOG_PLAIN:-0}" == 1 ]] && return 1
    [[ -n "${NO_COLOR:-}" ]] && return 1
    [[ -t 2 ]]
}

# 可选：export Z4PRO_LOG_FILE=/var/log/z4pro-sata-power.log 同时写入文件（无颜色纯文本）
_log_ts() {
    date '+%Y-%m-%d %H:%M:%S'
}

_log_file_line() {
    local level=$1
    shift
    [[ -z "${Z4PRO_LOG_FILE:-}" ]] && return 0
    printf '%s  %-7s  %s\n' "$(_log_ts)" "[$level]" "$*" >>"$Z4PRO_LOG_FILE" 2>/dev/null || true
}

_emit_log() {
    local level=$1
    local color=$2
    local sym=$3
    local msg=$4
    local ts
    ts=$(_log_ts)
    if _log_use_color; then
        echo -e "${C_DIM}${ts}${C_RST} ${color}${sym}${C_RST} ${C_BOLD}${level}${C_RST}  ${msg}" >&2
    else
        echo "${ts} [${level}] ${msg}" >&2
    fi
    _log_file_line "$level" "$msg"
}

# 日志（stderr + 可选文件）
log_info() {
    _emit_log INFO "$C_GRN" ">" "$1"
}

log_warn() {
    _emit_log WARN "$C_YEL" "!" "$1"
}

log_error() {
    _emit_log ERROR "$C_RED" "X" "$1"
}

# 章节标题（大块操作入口）
log_title() {
    local msg=$1
    if _log_use_color; then
        echo "" >&2
        echo -e "${C_CYN}╭${C_RST}${C_BLU}────────────────────────────────────────────────────${C_RST}${C_CYN}╮${C_RST}" >&2
        echo -e "${C_CYN}│${C_RST} ${C_BOLD}${msg}${C_RST} ${C_CYN}│${C_RST}" >&2
        echo -e "${C_CYN}╰${C_RST}${C_BLU}────────────────────────────────────────────────────${C_RST}${C_CYN}╯${C_RST}" >&2
        echo "" >&2
    else
        echo "" >&2
        echo "======== ${msg} ========" >&2
        echo "" >&2
    fi
    _log_file_line "TITLE" "======== ${msg} ========"
}

# 诊断等子节分隔线
log_section() {
    local msg=$1
    if _log_use_color; then
        echo -e "${C_DIM}┄┄ ${msg} ${C_DIM}┄┄${C_RST}" >&2
    else
        echo "---- ${msg} ----" >&2
    fi
    _log_file_line "SECT" "---- ${msg} ----"
}

# 检查root权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限，请使用sudo运行"
        exit 1
    fi
}

# 尝试挂载 debugfs（fnOS 等默认可能未挂载）
ensure_debugfs_gpio() {
    [[ -f "$DEBUG_GPIO_FILE" ]] && return 0
    if [[ ! -d "/sys/kernel/debug" ]]; then
        mkdir -p /sys/kernel/debug 2>/dev/null || true
    fi
    if grep -qE '[[:space:]]/sys/kernel/debug[[:space:]]' /proc/mounts 2>/dev/null; then
        [[ -f "$DEBUG_GPIO_FILE" ]] && return 0
    fi
    if mount -t debugfs none /sys/kernel/debug 2>/dev/null; then
        log_info "已挂载 debugfs 至 /sys/kernel/debug"
        return 0
    fi
    if mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null; then
        log_info "已挂载 debugfs 至 /sys/kernel/debug"
        return 0
    fi
    return 1
}

# 从 sysfs 读取某颗 gpiochip 的 Linux 全局基址（多路径、多芯片）
read_gpio_base_sysfs() {
    local base paths p seen=" " d

    if [[ -n "${Z4PRO_GPIO_SYSFS_CHIP:-}" ]]; then
        for p in "/sys/class/gpio/$Z4PRO_GPIO_SYSFS_CHIP/base" "/sys/bus/gpio/devices/$Z4PRO_GPIO_SYSFS_CHIP/base"; do
            if [[ -r "$p" ]]; then
                base=$(tr -d '[:space:]' <"$p" 2>/dev/null)
                if is_all_digits "$base"; then
                    log_info "从 sysfs 读取基址 ($p): $base"
                    echo "$base"
                    return 0
                fi
            fi
        done
    fi

    paths=()
    [[ -n "$GPIO_CHIP_DIR" ]] && paths+=("$GPIO_CHIP_DIR/base")
    paths+=("$SYSFS_GPIOCHIP0_BASE" /sys/bus/gpio/devices/gpiochip0/base)

    for p in "${paths[@]}"; do
        [[ -z "$p" ]] && continue
        [[ "$seen" == *" $p "* ]] && continue
        seen+=" $p "
        if [[ -r "$p" ]]; then
            base=$(tr -d '[:space:]' <"$p" 2>/dev/null)
            if is_all_digits "$base"; then
                log_info "从 sysfs 读取基址 ($p): $base"
                echo "$base"
                return 0
            fi
        fi
    done

    for d in /sys/bus/gpio/devices/gpiochip*; do
        [[ -d "$d" ]] || continue
        p="$d/base"
        if [[ -r "$p" ]]; then
            base=$(tr -d '[:space:]' <"$p" 2>/dev/null)
            if is_all_digits "$base"; then
                log_warn "使用 sysfs 中首个可读芯片 $d base=$base（若 SATA 不响应可设 Z4PRO_GPIO_SYSFS_CHIP）"
                echo "$base"
                return 0
            fi
        fi
    done

    for d in /sys/class/gpio/gpiochip*; do
        [[ -d "$d" ]] || continue
        p="$d/base"
        if [[ -r "$p" ]]; then
            base=$(tr -d '[:space:]' <"$p" 2>/dev/null)
            if is_all_digits "$base"; then
                log_warn "使用 class/gpio 首个可读 $d base=$base"
                echo "$base"
                return 0
            fi
        fi
    done

    return 1
}

# 旧格式: gpiochip0: GPIOs 664-1023
# 新格式: gpiochip0: 360 GPIOs, parent: ...（基址只在 sysfs 的 base 文件里）
parse_debugfs_gpiochip_line() {
    local dbg="$DEBUG_GPIO_FILE"
    local line chip base paths p

    line=$(grep -E '^gpiochip0:' "$dbg" 2>/dev/null | head -1)
    if [[ -z "$line" ]]; then
        line=$(grep -E '^gpiochip[0-9]+:' "$dbg" 2>/dev/null | head -1)
    fi
    if [[ -z "$line" ]]; then
        line=$(grep -i 'gpiochip' "$dbg" 2>/dev/null | grep -i 'gpios' | head -1)
    fi
    [[ -z "$line" ]] && return 1

    base=$(echo "$line" | sed -n 's/.*GPIOs[[:space:]]*\([0-9][0-9]*\)-[0-9][0-9]*/\1/p')
    if [[ -n "$base" ]]; then
        log_info "从 debugfs 解析到线范围，基址: $base"
        echo "$base"
        return 0
    fi

    chip=$(echo "$line" | sed -n 's/^\(gpiochip[0-9][0-9]*\):.*/\1/p')
    if [[ -z "$chip" ]]; then
        log_error "无法从 debugfs 行识别芯片名: $line"
        return 1
    fi

    for p in "/sys/bus/gpio/devices/$chip/base" "/sys/class/gpio/$chip/base"; do
        if [[ -r "$p" ]]; then
            base=$(tr -d '[:space:]' <"$p" 2>/dev/null)
            if is_all_digits "$base"; then
                log_info "debugfs 为新格式「N GPIOs」，已从 sysfs 读 $chip 基址 ($p): $base"
                echo "$base"
                return 0
            fi
        fi
    done

    log_warn "debugfs: $line"
    log_error "已识别 $chip，但 sysfs 无可读 $chip/base（请检查权限或内核 ABI）"
    return 1
}

# 获取 GPIO 基地址（legacy 必需；chip 模式仅作显示，失败也可继续）
get_gpio_base() {
    local base out

    if [[ "$GPIO_MODE" == "chip" ]]; then
        if [[ -r "$GPIO_CHIP_DIR/base" ]]; then
            base=$(tr -d '[:space:]' <"$GPIO_CHIP_DIR/base" 2>/dev/null)
            if is_all_digits "$base"; then
                log_info "chip 模式，基址: $base"
                echo "$base"
                return 0
            fi
        fi
        log_warn "chip 模式未读到 base 文件，线控制使用偏移 ${GPIO_OFFSETS[*]}"
        echo "0"
        return 0
    fi

    if [[ -n "${Z4PRO_GPIO_BASE:-}" ]] && is_all_digits "$Z4PRO_GPIO_BASE"; then
        log_warn "使用环境变量 Z4PRO_GPIO_BASE=$Z4PRO_GPIO_BASE"
        echo "$Z4PRO_GPIO_BASE"
        return 0
    fi

    if out=$(read_gpio_base_sysfs); then
        echo "$out"
        return 0
    fi

    log_warn "sysfs 未读到任何 gpiochip 基址，尝试 debugfs: $DEBUG_GPIO_FILE"
    if ! ensure_debugfs_gpio || [[ ! -r "$DEBUG_GPIO_FILE" ]]; then
        log_error "无法访问 GPIO 信息。可设置 Z4PRO_GPIO_BASE 或执行: $0 diagnose"
        return 1
    fi

    if out=$(parse_debugfs_gpiochip_line); then
        echo "$out"
        return 0
    fi

    log_error "无法获取 GPIO 基地址。可手动: export Z4PRO_GPIO_BASE=<数字> 后重试"
    return 1
}

# legacy: 返回全局 GPIO 号；chip: 返回芯片内偏移（与 GPIO_OFFSETS 相同）
compute_gpio_ids() {
    local base=$1
    local ids=()
    local o
    for o in "${GPIO_OFFSETS[@]}"; do
        if [[ "$GPIO_MODE" == "legacy" ]]; then
            ids+=("$((base + o))")
        else
            ids+=("$o")
        fi
    done
    echo "${ids[@]}"
}

# 导出 GPIO（id 为全局编号或芯片偏移，取决于 GPIO_MODE）
export_gpio() {
    local id=$1
    local export_file
    local expdir
    expdir=$(gpio_exported_dir "$id")

    if [[ -d "$expdir" ]]; then
        log_info "GPIO 线 $id 已导出 ($GPIO_MODE)"
        return 0
    fi

    if [[ "$GPIO_MODE" == "legacy" ]]; then
        export_file="/sys/class/gpio/export"
    else
        export_file="$GPIO_CHIP_DIR/export"
    fi

    if ! echo "$id" >"$export_file" 2>/dev/null; then
        log_error "export 失败: 线 id=$id → $export_file（设备忙、权限或内核未开启 GPIO sysfs）"
        log_error "请执行: sudo $0 diagnose"
        return 1
    fi
    log_info "已导出 GPIO 线 $id ($GPIO_MODE)"
}

# 设置GPIO方向
set_gpio_direction() {
    local id=$1
    local direction=$2
    local direction_file
    direction_file=$(gpio_direction_path "$id")

    if [[ -f "$direction_file" ]]; then
        echo "$direction" >"$direction_file"
        if [[ $? -eq 0 ]]; then
            log_info "GPIO 线 $id 方向设置为: $direction"
        else
            log_error "无法设置 GPIO 线 $id 方向为: $direction"
            return 1
        fi
    else
        log_error "GPIO 线 $id 方向文件不存在: $direction_file"
        return 1
    fi
}

# 设置GPIO值
set_gpio_value() {
    local id=$1
    local value=$2
    local value_file
    value_file=$(gpio_value_path "$id")

    if [[ -f "$value_file" ]]; then
        echo "$value" >"$value_file"
        if [[ $? -eq 0 ]]; then
            log_info "GPIO 线 $id 值设置为: $value"
        else
            log_error "无法设置 GPIO 线 $id 值为: $value"
            return 1
        fi
    else
        log_error "GPIO 线 $id 值文件不存在: $value_file"
        return 1
    fi
}

# 取消导出GPIO
unexport_gpio() {
    local id=$1
    local unexport_file

    if [[ "$GPIO_MODE" == "legacy" ]]; then
        unexport_file="/sys/class/gpio/unexport"
    else
        unexport_file="$GPIO_CHIP_DIR/unexport"
    fi

    if [[ -d "$(gpio_exported_dir "$id")" ]]; then
        echo "$id" >"$unexport_file" 2>/dev/null
        log_info "已取消导出 GPIO 线 $id"
    fi
}

# 显示GPIO状态（可选第二参数：端口名，如 SATA0）
show_gpio_status() {
    local id=$1
    local port=${2:-}
    local value_file direction_file
    value_file=$(gpio_value_path "$id")
    direction_file=$(gpio_direction_path "$id")

    if [[ -f "$value_file" && -f "$direction_file" ]]; then
        local value direction line
        value=$(cat "$value_file")
        direction=$(cat "$direction_file")
        if [[ -n "$port" ]]; then
            line=$(printf '%s  │  %-6s  GPIO %-4s  │  %-4s  │  %s' "$port" "$GPIO_MODE" "$id" "$direction" "$value")
        else
            line=$(printf '%-6s  GPIO %-4s  │  %-4s  │  %s' "$GPIO_MODE" "$id" "$direction" "$value")
        fi
        log_info "$line"
    else
        log_warn "无法读取 GPIO 线 $id${port:+（$port）}（可能尚未 export）"
    fi
}

# 收集诊断信息（飞牛上执行后把输出贴给维护者）
run_diagnose() {
    log_title "z4pro-sata-power · 诊断"
    log_info "内核 $(uname -r)  ·  脚本 $0"
    if command -v od >/dev/null 2>&1; then
        if head -1 "$0" | od -c | grep -q '\\r'; then
            log_warn "脚本首行含 \\r（Windows 换行）。若报错 bad interpreter，在 NAS 上执行: dos2unix $0"
        fi
    fi
    log_section "/sys/class/gpio（前 40 行）"
    ls -la /sys/class/gpio 2>&1 | head -40 >&2 || log_warn "无法列出 /sys/class/gpio"
    log_section "/sys/bus/gpio/devices"
    ls -la /sys/bus/gpio/devices 2>&1 | head -40 >&2 || log_warn "无法列出 devices"
    local p
    for p in /sys/class/gpio/export /sys/class/gpio/unexport \
        /sys/class/gpio/gpiochip0/export /sys/bus/gpio/devices/gpiochip0/export; do
        [[ -e "$p" ]] && log_info "存在: $p"
    done
    if [[ -r /sys/class/gpio/gpiochip0/base ]]; then
        log_info "gpiochip0 base (class): $(cat /sys/class/gpio/gpiochip0/base 2>/dev/null)"
    fi
    if [[ -r /sys/bus/gpio/devices/gpiochip0/base ]]; then
        log_info "gpiochip0 base (bus): $(cat /sys/bus/gpio/devices/gpiochip0/base 2>/dev/null)"
    fi
    log_section "各 gpiochip 的 sysfs base"
    for p in /sys/bus/gpio/devices/gpiochip*/base; do
        [[ -r "$p" ]] && log_info "$(printf '%s  →  %s' "$p" "$(cat "$p" 2>/dev/null)")"
    done
    if ensure_debugfs_gpio && [[ -f "$DEBUG_GPIO_FILE" ]]; then
        log_section "$DEBUG_GPIO_FILE（含 gpiochip / GPIOs，前 20 行）"
        grep -E 'gpiochip|GPIOs' "$DEBUG_GPIO_FILE" 2>/dev/null | head -20 >&2 || true
    else
        log_warn "无法读取 $DEBUG_GPIO_FILE（debugfs 未挂载或被禁用）"
    fi
    log_section "建议"
    log_info "若完全无 /sys/class/gpio/export 且无 gpiochip0/export → 内核可能未提供 GPIO sysfs。"
    log_info "若 export 仍失败 → 查看 dmesg 是否提示 GPIO 已被内核驱动占用。"
    log_section "诊断结束"
}

# 上电单个SATA端口
power_up_sata_port() {
    local port_num=$1
    local gpio=$2
    
    log_info "SATA${port_num}  ·  上电  ·  GPIO ${gpio}  (${GPIO_MODE})"
    
    export_gpio "$gpio" || return 1
    set_gpio_direction "$gpio" "out" || return 1
    set_gpio_value "$gpio" "0" || return 1
    
    # 验证设置
    show_gpio_status "$gpio" "$port_num"
}

# 下电单个SATA端口
power_down_sata_port() {
    local port_num=$1
    local gpio=$2
    
    log_info "SATA${port_num}  ·  下电  ·  GPIO ${gpio}"
    
    set_gpio_value "$gpio" "1"
    show_gpio_status "$gpio" "$port_num"
}

# 为所有SATA端口上电
power_up_all_sata() {
    local base=$1
    local gpios=($(compute_gpio_ids "$base"))
    local ports=("SATA3" "SATA2" "SATA1" "SATA0")
    
    log_section "顺序上电（口间间隔 5s）"
    
    for i in "${!gpios[@]}"; do
        power_up_sata_port "${ports[i]}" "${gpios[i]}" || exit 1
        # 端口之间延时5秒
        sleep 5
    done
    
    log_info "全部 SATA 端口上电流程已完成"
}

# 为所有SATA端口下电
power_down_all_sata() {
    local base=$1
    local gpios=($(compute_gpio_ids "$base"))
    local ports=("SATA3" "SATA2" "SATA1" "SATA0")
    
    log_section "顺序下电"
    
    for i in "${!gpios[@]}"; do
        power_down_sata_port "${ports[i]}" "${gpios[i]}"
        sleep 1
    done
    
    log_info "全部 SATA 端口下电流程已完成"
}

# 清理函数
cleanup() {
    local base=$1
    local gpios=($(compute_gpio_ids "$base"))
    
    log_section "unexport 各线"
    
    for gpio in "${gpios[@]}"; do
        unexport_gpio "$gpio"
    done
}

# 显示使用说明
show_usage() {
    echo "SATA 电源控制脚本（Z4 Pro / 飞牛 fnOS）"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  up          为所有SATA端口上电"
    echo "  down        为所有SATA端口下电"
    echo "  status      先 export 再读取各线状态（不写入方向/电平）"
    echo "  cleanup     清理导出的GPIO"
    echo "  diagnose    诊断 GPIO sysfs / debugfs（排错）"
    echo "  --help      显示此帮助信息"
    echo ""
    echo "环境变量:"
    echo "  Z4PRO_LOG_FILE=路径           追加执行日志（对齐列 + 时间戳，无 ANSI 颜色）"
    echo "  Z4PRO_LOG_PLAIN=1             终端也使用纯文本（无颜色、无框线，便于重定向）"
    echo "  Z4PRO_GPIO_BASE=<n>           手动指定 Linux 全局 GPIO 基址"
    echo "  Z4PRO_GPIO_SYSFS_CHIP=name    指定 sysfs 芯片目录名，如 gpiochip0"
    echo ""
    echo "示例:"
    echo "  $0 up       为所有SATA端口上电"
    echo "  $0 down     为所有SATA端口下电"
    echo "  $0 status   显示GPIO状态"
    echo "  Z4PRO_LOG_FILE=/tmp/sata.log $0 up   上电并写日志"
    echo "https://github.com/lightfex/z4pro-sata-power"
}

# 主函数
main() {
    local action=${1:-"status"}

    if [[ "$action" == "diagnose" ]]; then
        if [[ -n "${Z4PRO_LOG_FILE:-}" ]]; then
            touch "$Z4PRO_LOG_FILE" 2>/dev/null || true
            _log_file_line SESSION "==== diagnose $0 $* ===="
        fi
        run_diagnose
        exit 0
    fi

    check_root

    if [[ -n "${Z4PRO_LOG_FILE:-}" ]]; then
        touch "$Z4PRO_LOG_FILE" 2>/dev/null || true
        _log_file_line SESSION "==== 开始 $0 $* (user=$USER) ===="
    fi

    if ! detect_gpio_mode; then
        log_error "未检测到 GPIO sysfs（无全局 export 且无 gpiochip0/export）。执行: sudo $0 diagnose"
        exit 1
    fi

    case "$action" in
        "up")
            log_title "SATA 端口上电"
            base=$(get_gpio_base)
            if [[ $? -eq 0 ]]; then
                log_info "模式 ${GPIO_MODE}  ·  基址 ${base}"
                power_up_all_sata "$base"
            else
                log_error "无法获取GPIO基地址"
                exit 1
            fi
            ;;
        "down")
            log_title "SATA 端口下电"
            base=$(get_gpio_base)
            if [[ $? -eq 0 ]]; then
                log_info "模式 ${GPIO_MODE}  ·  基址 ${base}"
                power_down_all_sata "$base"
            else
                log_error "无法获取GPIO基地址"
                exit 1
            fi
            ;;
        "status")
            log_title "GPIO / SATA 状态"
            log_info "将依次 export 后读取（不写入方向与电平）"
            base=$(get_gpio_base)
            if [[ $? -eq 0 ]]; then
                log_info "模式 ${GPIO_MODE}  ·  基址 ${base}"
                gpios=($(compute_gpio_ids "$base"))
                ports=("SATA3" "SATA2" "SATA1" "SATA0")
                log_section "各端口"

                local line_id
                for i in "${!gpios[@]}"; do
                    line_id="${gpios[i]}"
                    if export_gpio "$line_id"; then
                        show_gpio_status "$line_id" "${ports[i]}"
                    else
                        log_warn "SATA${ports[i]}: 线 $line_id 无法 export（可能被内核占用），跳过"
                    fi
                done
            else
                log_error "无法获取GPIO基地址"
                exit 1
            fi
            ;;
        "cleanup")
            log_title "GPIO 清理（unexport）"
            base=$(get_gpio_base)
            if [[ $? -eq 0 ]]; then
                cleanup "$base"
            else
                log_error "无法获取GPIO基地址"
                exit 1
            fi
            ;;
        "--help"|"-h"|"help")
            show_usage
            ;;
        *)
            log_error "未知操作: $action"
            show_usage
            exit 1
            ;;
    esac
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
