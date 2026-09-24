#!/bin/sh

# Alpine Linux installer for shadowsocks-rust AEAD-2022.
# POSIX sh / BusyBox ash compatible.

set -eu
umask 077
PATH=/sbin:/usr/sbin:/bin:/usr/bin
export PATH

LISTEN_ADDRESS="::"
METHOD="2022-blake3-aes-256-gcm"
DEFAULT_PORT="12345"
SERVICE_NAME="ss-rust"
CONFIG_DIR="/etc/shadowsocks-rust"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SERVICE_FILE="/etc/init.d/${SERVICE_NAME}"
KEY_FILE="/root/ss2022-key.txt"
LOG_FILE="/var/log/shadowsocks-rust.log"
ERROR_LOG_FILE="/var/log/shadowsocks-rust.err"

PORT=""
PSK=""
SERVER_ADDRESS=""
SSSERVER_PATH=""
SSSERVICE_PATH=""
BACKUP_DIR=""
SERVICE_WAS_ACTIVE=0
SERVICE_WAS_ENABLED=0
SERVICE_STOPPED=0
SERVICE_START_ATTEMPTED=0
TRANSACTION_STARTED=0
ROLLBACK_FAILED=0
OLD_CONFIG_EXISTS=0
OLD_SERVICE_EXISTS=0
OLD_KEY_EXISTS=0
CONFIG_DIR_CREATED=0
TMP_KEY=""
TMP_CONFIG=""
TMP_SERVICE=""
VALIDATE_FILE=""
URI_TMP=""
LOCK_DIR="/run/shadowsocks-rust-install.lock"
LOCK_HELD=0
SERVICE_ADD_ATTEMPTED=0

info() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

has_command() {
    command -v "$1" >/dev/null 2>&1
}

remove_temp_files() {
    [ -n "$TMP_KEY" ] && rm -f "$TMP_KEY" 2>/dev/null || true
    [ -n "$TMP_CONFIG" ] && rm -f "$TMP_CONFIG" 2>/dev/null || true
    [ -n "$TMP_SERVICE" ] && rm -f "$TMP_SERVICE" 2>/dev/null || true
    [ -n "$VALIDATE_FILE" ] && rm -f "$VALIDATE_FILE" 2>/dev/null || true
    [ -n "$URI_TMP" ] && rm -f "$URI_TMP" 2>/dev/null || true
}

release_lock() {
    if [ "$LOCK_HELD" -eq 1 ]; then
        rm -f "${LOCK_DIR}/pid" 2>/dev/null || true
        rmdir "$LOCK_DIR" 2>/dev/null || true
        LOCK_HELD=0
    fi
}

restore_regular_file() {
    restore_source=$1
    restore_target=$2

    if ! cp -p "$restore_source" "$restore_target" 2>/dev/null; then
        warn "回滚失败，无法恢复 $restore_target。"
        ROLLBACK_FAILED=1
    fi
}

remove_created_file() {
    remove_target=$1
    if [ -e "$remove_target" ] || [ -L "$remove_target" ]; then
        if ! rm -f "$remove_target" 2>/dev/null; then
            warn "回滚失败，无法删除 $remove_target。"
            ROLLBACK_FAILED=1
        fi
    fi
}

service_is_enabled() {
    enabled_services=$(rc-update show default 2>/dev/null) || return 2
    printf '%s\n' "$enabled_services" | awk -v service="$SERVICE_NAME" \
        '$1 == service || $2 == service { found=1 } END { exit !found }'
}

service_pid_is_alive() {
    pid_file="/run/${SERVICE_NAME}.pid"
    [ -r "$pid_file" ] || return 1
    service_pid=$(cat "$pid_file" 2>/dev/null) || return 1
    case "$service_pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ -r "/proc/${service_pid}/comm" ] || return 1
    [ "$(cat "/proc/${service_pid}/comm" 2>/dev/null)" = "ssserver" ] || return 1
    kill -0 "$service_pid" 2>/dev/null
}

service_is_active_or_alive() {
    if rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
        return 0
    fi
    service_pid_is_alive
}

rollback_on_error() {
    status=$?

    trap - 0 INT TERM
    set +e
    remove_temp_files

    if [ "$status" -ne 0 ] && [ "$TRANSACTION_STARTED" -eq 1 ]; then
        warn "部署失败，正在恢复之前的配置。"

        if [ "$SERVICE_START_ATTEMPTED" -eq 1 ] && \
           service_is_active_or_alive; then
            if ! rc-service "$SERVICE_NAME" stop >/dev/null 2>&1; then
                warn "回滚失败，无法停止新服务进程。"
                ROLLBACK_FAILED=1
            fi
        fi

        if [ "$OLD_CONFIG_EXISTS" -eq 1 ] && [ -n "$BACKUP_DIR" ]; then
            restore_regular_file "${BACKUP_DIR}/config.json" "$CONFIG_FILE"
        else
            remove_created_file "$CONFIG_FILE"
        fi

        if [ "$OLD_SERVICE_EXISTS" -eq 1 ] && [ -n "$BACKUP_DIR" ]; then
            restore_regular_file "${BACKUP_DIR}/${SERVICE_NAME}" "$SERVICE_FILE"
        else
            remove_created_file "$SERVICE_FILE"
        fi

        if [ "$OLD_KEY_EXISTS" -eq 1 ] && [ -n "$BACKUP_DIR" ]; then
            restore_regular_file "${BACKUP_DIR}/ss2022-key.txt" "$KEY_FILE"
        else
            remove_created_file "$KEY_FILE"
        fi

        if [ "$CONFIG_DIR_CREATED" -eq 1 ]; then
            if ! rmdir "$CONFIG_DIR" 2>/dev/null; then
                warn "回滚失败，无法删除新建的配置目录。"
                ROLLBACK_FAILED=1
            fi
        fi

        if [ "$SERVICE_WAS_ENABLED" -eq 0 ] && \
           [ "$SERVICE_ADD_ATTEMPTED" -eq 1 ]; then
            service_is_enabled
            enabled_state=$?
            if [ "$enabled_state" -eq 0 ]; then
                if ! rc-update del "$SERVICE_NAME" default >/dev/null 2>&1; then
                    warn "回滚失败，无法撤销 OpenRC default runlevel 注册。"
                    ROLLBACK_FAILED=1
                fi
            elif [ "$enabled_state" -ne 1 ]; then
                warn "回滚失败，无法查询 OpenRC default runlevel 状态。"
                ROLLBACK_FAILED=1
            fi
        fi

        if [ "$SERVICE_STOPPED" -eq 1 ] && [ "$SERVICE_WAS_ACTIVE" -eq 1 ]; then
            if ! rc-service "$SERVICE_NAME" start >/dev/null 2>&1; then
                warn "回滚失败，旧服务无法重新启动。"
                ROLLBACK_FAILED=1
            fi
        fi

        if [ "$ROLLBACK_FAILED" -eq 0 ]; then
            warn "旧配置和旧服务状态已恢复。"
        else
            warn "回滚未完全成功，请检查服务、配置和备份目录。"
        fi
        if [ -n "$BACKUP_DIR" ]; then
            warn "旧文件备份位置：$BACKUP_DIR"
        fi
    fi

    release_lock
    trap - 0
    if [ "$status" -eq 0 ]; then
        exit 0
    fi
    exit "$status"
}

trap rollback_on_error 0
trap 'exit 130' INT TERM

require_root_and_alpine() {
    [ "$(id -u)" -eq 0 ] || die "请使用 root 用户运行此脚本。"
    [ -f /etc/alpine-release ] || die "此脚本仅支持 Alpine Linux。"

    has_command apk || die "未找到 apk。"
    has_command rc-service || die "未找到 OpenRC 的 rc-service。"
    has_command rc-update || die "未找到 OpenRC 的 rc-update。"
    [ -x /sbin/openrc-run ] || die "未找到 /sbin/openrc-run。"
}

acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        LOCK_HELD=1
        printf '%s\n' "$$" > "${LOCK_DIR}/pid"
        chmod 0700 "$LOCK_DIR"
        return 0
    fi

    if [ -r "${LOCK_DIR}/pid" ]; then
        lock_pid=$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)
        case "$lock_pid" in
            ''|*[!0-9]*) ;;
            *)
                if kill -0 "$lock_pid" 2>/dev/null; then
                    die "已有另一个部署进程运行中（PID $lock_pid）。"
                fi
                ;;
        esac
    fi

    rm -f "${LOCK_DIR}/pid" 2>/dev/null || die "无法清理失效的部署锁。"
    rmdir "$LOCK_DIR" 2>/dev/null || die "部署锁已存在，请确认没有其他安装进程。"
    mkdir "$LOCK_DIR" || die "无法创建部署锁。"
    LOCK_HELD=1
    printf '%s\n' "$$" > "${LOCK_DIR}/pid"
    chmod 0700 "$LOCK_DIR"
}

install_dependencies() {
    info "安装 Shadowsocks、OpenRC 检查和地址检测所需的软件包。"
    if apk add --no-cache \
        shadowsocks-rust-ssserver \
        shadowsocks-rust-ssservice \
        iproute2-ss \
        curl; then
        :
    else
        apk_status=$?
        case "$apk_status" in
            137|143)
                die "apk 被系统终止（退出码 $apk_status），通常表示内存不足或容器内存限制。请先增加 RAM/Swap 后重试。"
                ;;
            *)
                die "软件包安装失败（退出码 $apk_status）。请确认 Alpine 的 community 仓库已启用。"
                ;;
        esac
    fi

    SSSERVER_PATH="/usr/bin/ssserver"
    SSSERVICE_PATH="/usr/bin/ssservice"
    [ -x "$SSSERVER_PATH" ] || die "未找到 /usr/bin/ssserver。"
    [ -x "$SSSERVICE_PATH" ] || die "未找到 /usr/bin/ssservice。"
    has_command ss || die "未找到 ss 命令。"
    has_command awk || die "未找到 awk。"
    has_command base64 || die "未找到 base64。"
    has_command mktemp || die "未找到 mktemp。"
    id nobody >/dev/null 2>&1 || die "系统中没有 nobody 用户。"
}

prompt_port() {
    while :; do
        printf '监听端口 [1-65535]（直接回车使用 %s）: ' "$DEFAULT_PORT"
        IFS= read -r INPUT_PORT < /dev/tty || die "读取端口失败。"
        if [ -n "$INPUT_PORT" ]; then
            PORT=$INPUT_PORT
        else
            PORT=$DEFAULT_PORT
        fi

        case "$PORT" in
            ''|0*|*[!0-9]*)
                warn "端口必须是 1-65535 的十进制整数，且不能有前导零。"
                continue
                ;;
        esac

        if [ "$PORT" -le 65535 ] 2>/dev/null; then
            return 0
        fi
        warn "端口必须在 1-65535 范围内。"
    done
}

validate_psk() {
    VALIDATE_KEY=$1

    # 32 raw bytes in canonical standard Base64 are 44 characters ending in one '='.
    [ "${#VALIDATE_KEY}" -eq 44 ] || return 1
    case "$VALIDATE_KEY" in
        *[!A-Za-z0-9+/=]*) return 1 ;;
    esac

    VALIDATE_PREFIX=${VALIDATE_KEY%?}
    case "$VALIDATE_PREFIX" in
        *"="*) return 1 ;;
    esac
    case "$VALIDATE_KEY" in
        *=) ;;
        *) return 1 ;;
    esac

    VALIDATE_FILE=$(mktemp /tmp/shadowsocks-rust-key.XXXXXX) || return 1
    if ! printf '%s' "$VALIDATE_KEY" | base64 -d > "$VALIDATE_FILE" 2>/dev/null; then
        rm -f "$VALIDATE_FILE"
        VALIDATE_FILE=""
        return 1
    fi

    VALIDATE_BYTES=$(wc -c < "$VALIDATE_FILE" | tr -d '[:space:]')
    if [ "$VALIDATE_BYTES" != "32" ]; then
        rm -f "$VALIDATE_FILE"
        VALIDATE_FILE=""
        return 1
    fi

    VALIDATE_BASE64_OUTPUT=$(base64 "$VALIDATE_FILE") || {
        rm -f "$VALIDATE_FILE"
        VALIDATE_FILE=""
        return 1
    }
    VALIDATE_CANONICAL=$(printf '%s' "$VALIDATE_BASE64_OUTPUT" | tr -d '\r\n')
    rm -f "$VALIDATE_FILE"
    VALIDATE_FILE=""
    [ "$VALIDATE_CANONICAL" = "$VALIDATE_KEY" ] || return 1
}

prompt_psk() {
    while :; do
        printf '输入自定义 32 字节 Base64 PSK（直接回车自动生成）: '
        IFS= read -r INPUT_KEY < /dev/tty || die "读取 PSK 失败。"

        if [ -z "$INPUT_KEY" ]; then
            PSK=$("$SSSERVICE_PATH" genkey -m "$METHOD") || die "自动生成 PSK 失败。"
            validate_psk "$PSK" || die "ssservice 生成的 PSK 不符合 32 字节 Base64 要求。"
            info "已使用 ssservice 生成合规随机 PSK。"
            return 0
        fi

        if validate_psk "$INPUT_KEY"; then
            PSK=$INPUT_KEY
            return 0
        fi
        warn "PSK 无效：必须是规范 Base64，解码后必须正好为 32 字节。"
    done
}

prompt_server_address() {
    printf '客户端使用的服务器地址（IPv6 地址或域名，直接回车自动检测）: '
    IFS= read -r SERVER_ADDRESS < /dev/tty || die "读取服务器地址失败。"

    if [ -z "$SERVER_ADDRESS" ]; then
        SERVER_ADDRESS=$(curl -6fsS --max-time 5 https://api64.ipify.org 2>/dev/null || true)
    fi

    case "$SERVER_ADDRESS" in
        \[*\])
            SERVER_ADDRESS=${SERVER_ADDRESS#\[}
            SERVER_ADDRESS=${SERVER_ADDRESS%\]}
            ;;
    esac

    if [ -n "$SERVER_ADDRESS" ]; then
        case "$SERVER_ADDRESS" in
            *[!A-Za-z0-9.:-]*)
                die "服务器地址只能包含字母、数字、点、连字符或冒号。"
                ;;
        esac
    fi
}

ensure_safe_target() {
    target=$1
    if [ -L "$target" ]; then
        die "拒绝操作符号链接目标：$target"
    fi
    if [ -e "$target" ] && [ ! -f "$target" ]; then
        die "目标不是普通文件：$target"
    fi
}

backup_existing_files() {
    ensure_safe_target "$CONFIG_FILE"
    ensure_safe_target "$SERVICE_FILE"
    ensure_safe_target "$KEY_FILE"
    ensure_safe_target "$LOG_FILE"
    ensure_safe_target "$ERROR_LOG_FILE"

    [ -f "$CONFIG_FILE" ] && OLD_CONFIG_EXISTS=1
    [ -f "$SERVICE_FILE" ] && OLD_SERVICE_EXISTS=1
    [ -f "$KEY_FILE" ] && OLD_KEY_EXISTS=1

    if [ "$OLD_CONFIG_EXISTS" -eq 1 ] || \
       [ "$OLD_SERVICE_EXISTS" -eq 1 ] || \
       [ "$OLD_KEY_EXISTS" -eq 1 ]; then
        BACKUP_DIR=$(mktemp -d /root/shadowsocks-rust-backup.XXXXXX) || die "无法创建备份目录。"
        [ "$OLD_CONFIG_EXISTS" -eq 1 ] && cp -p "$CONFIG_FILE" "${BACKUP_DIR}/config.json"
        [ "$OLD_SERVICE_EXISTS" -eq 1 ] && cp -p "$SERVICE_FILE" "${BACKUP_DIR}/${SERVICE_NAME}"
        [ "$OLD_KEY_EXISTS" -eq 1 ] && cp -p "$KEY_FILE" "${BACKUP_DIR}/ss2022-key.txt"
        info "已有文件已备份到：$BACKUP_DIR"
    fi
}

stop_existing_service() {
    TRANSACTION_STARTED=1

    if [ -x "$SERVICE_FILE" ] && service_is_active_or_alive; then
        SERVICE_WAS_ACTIVE=1
        if ! rc-service "$SERVICE_NAME" stop >/dev/null 2>&1; then
            die "无法停止旧服务，已中止部署。"
        fi
        SERVICE_STOPPED=1

        attempts=0
        while service_is_active_or_alive; do
            attempts=$((attempts + 1))
            [ "$attempts" -lt 10 ] || die "旧服务停止超时，已中止部署。"
            sleep 1
        done
    elif [ ! -x "$SERVICE_FILE" ] && service_pid_is_alive; then
        die "检测到没有对应 OpenRC 服务文件的 ssserver 进程，已中止部署。"
    fi
}

port_is_in_use() {
    PORT_TCP_OUTPUT=$(ss -ltn 2>/dev/null) || die "无法读取 TCP 监听状态。"
    if printf '%s\n' "$PORT_TCP_OUTPUT" | awk -v p=":$PORT" \
        '$1 == "LISTEN" && $4 ~ (p "$") { found=1 } END { exit !found }'; then
        return 0
    fi

    PORT_UDP_OUTPUT=$(ss -lun 2>/dev/null) || die "无法读取 UDP 监听状态。"
    if printf '%s\n' "$PORT_UDP_OUTPUT" | awk -v p=":$PORT" \
        '$1 == "UNCONN" && $4 ~ (p "$") { found=1 } END { exit !found }'; then
        return 0
    fi
    return 1
}

check_port_is_free() {
    if port_is_in_use; then
        die "端口 $PORT 仍被其他进程占用。"
    fi
}

write_key_file() {
    TMP_KEY=$(mktemp /root/ss2022-key.XXXXXX) || die "无法创建 PSK 文件。"
    printf '%s\n' "$PSK" > "$TMP_KEY"
    chown root:root "$TMP_KEY"
    chmod 0600 "$TMP_KEY"
    mv -f "$TMP_KEY" "$KEY_FILE"
    TMP_KEY=""
}

write_config() {
    if [ ! -e "$CONFIG_DIR" ]; then
        mkdir -p "$CONFIG_DIR"
        CONFIG_DIR_CREATED=1
    elif [ -L "$CONFIG_DIR" ] || [ ! -d "$CONFIG_DIR" ]; then
        die "配置路径不是安全的普通目录：$CONFIG_DIR"
    fi

    chown root:nobody "$CONFIG_DIR"
    chmod 0750 "$CONFIG_DIR"

    TMP_CONFIG=$(mktemp "${CONFIG_DIR}/config.json.XXXXXX") || die "无法创建临时配置文件。"
    cat > "$TMP_CONFIG" <<EOF
{
  "server": "$LISTEN_ADDRESS",
  "server_port": $PORT,
  "password": "$PSK",
  "method": "$METHOD",
  "mode": "tcp_and_udp",
  "timeout": 300,
  "no_delay": true,
  "ipv6_only": false
}
EOF
    chown root:nobody "$TMP_CONFIG"
    chmod 0640 "$TMP_CONFIG"
    mv -f "$TMP_CONFIG" "$CONFIG_FILE"
    TMP_CONFIG=""
}

write_service() {
    SERVICE_CAPABILITIES=""
    if [ "$PORT" -lt 1024 ]; then
        SERVICE_CAPABILITIES='capabilities="^cap_net_bind_service"'
    fi

    TMP_SERVICE=$(mktemp "/etc/init.d/${SERVICE_NAME}.XXXXXX") || die "无法创建临时 OpenRC 服务文件。"
    cat > "$TMP_SERVICE" <<EOF
#!/sbin/openrc-run

description="Shadowsocks Rust AEAD-2022 server"
command="$SSSERVER_PATH"
command_args="-c $CONFIG_FILE"
command_user="nobody:nobody"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
required_files="$CONFIG_FILE"
$SERVICE_CAPABILITIES

output_log="$LOG_FILE"
error_log="$ERROR_LOG_FILE"

depend() {
    use net
    after bootmisc
}
EOF
    chmod 0755 "$TMP_SERVICE"
    chown root:root "$TMP_SERVICE"
    mv -f "$TMP_SERVICE" "$SERVICE_FILE"
    TMP_SERVICE=""
}

prepare_logs() {
    touch "$LOG_FILE" "$ERROR_LOG_FILE"
    chown nobody:nobody "$LOG_FILE" "$ERROR_LOG_FILE"
    chmod 0600 "$LOG_FILE" "$ERROR_LOG_FILE"
}

start_service() {
    SERVICE_START_ATTEMPTED=1
    if ! rc-service "$SERVICE_NAME" start; then
        tail -n 40 "$LOG_FILE" "$ERROR_LOG_FILE" 2>/dev/null || true
        die "OpenRC 服务启动失败。"
    fi
    sleep 1
    if ! rc-service "$SERVICE_NAME" status; then
        tail -n 40 "$LOG_FILE" "$ERROR_LOG_FILE" 2>/dev/null || true
        die "服务启动后状态异常。"
    fi
}

listener_matches() {
    listener_output=$1
    protocol=$2

    printf '%s\n' "$listener_output" | awk -v p=":$PORT" -v proto="$protocol" '
        $1 == proto && $5 ~ (p "$") && $0 ~ /ssserver/ {
            found=1
        }
        END { exit !found }
    '
}

verify_listener() {
    attempts=0
    while [ "$attempts" -lt 15 ]; do
        if IPV6_OUTPUT=$(ss -6 -tulpn 2>/dev/null); then
            if listener_matches "$IPV6_OUTPUT" tcp && \
               listener_matches "$IPV6_OUTPUT" udp; then
                LISTEN_OUTPUT=$IPV6_OUTPUT
                printf '\n当前 IPv6 监听状态：\n%s\n' "$LISTEN_OUTPUT"
                break
            fi
        fi
        attempts=$((attempts + 1))
        sleep 1
    done

    if [ "$attempts" -ge 15 ]; then
        printf '\n当前监听状态：\n%s\n' "${LISTEN_OUTPUT:-ss 检查失败}"
        die "没有检测到 ssserver 在 IPv6 [::]:$PORT 上同时监听 TCP 和 UDP。"
    fi

    IPV4_MAPPED="未由 ss 显式显示（可能由共享 IPv6 socket 提供）"
    if IPV4_OUTPUT=$(ss -4 -tulpn 2>/dev/null); then
        if listener_matches "$IPV4_OUTPUT" tcp && \
           listener_matches "$IPV4_OUTPUT" udp; then
            IPV4_MAPPED="是（显式 IPv4 socket）"
        fi
    fi
    info "IPv6 TCP/UDP 监听已确认；IPv4-mapped 双栈状态：$IPV4_MAPPED。"
}

build_ss_uri() {
    SS_URI=""
    [ -n "$SERVER_ADDRESS" ] || return 0

    URI_TMP=$(mktemp /tmp/shadowsocks-rust-uri.XXXXXX) || die "无法创建 URI 临时文件。"
    printf '%s:%s' "$METHOD" "$PSK" > "$URI_TMP" || die "无法准备 URI 数据。"
    URI_BASE64=$(base64 "$URI_TMP") || die "URI Base64 编码失败。"
    rm -f "$URI_TMP"
    URI_TMP=""
    URI_USERINFO=$(printf '%s' "$URI_BASE64" | tr -d '\r\n' | tr '+/' '-_' | tr -d '=')
    URI_HOST=$SERVER_ADDRESS
    case "$URI_HOST" in
        *:*)
            case "$URI_HOST" in
                \[*\]) ;;
                *) URI_HOST="[$URI_HOST]" ;;
            esac
            ;;
    esac
    SS_URI="ss://${URI_USERINFO}@${URI_HOST}:${PORT}#shadowsocks-2022"
}

print_summary() {
    build_ss_uri

    printf '\n========================================\n'
    printf 'Shadowsocks 2022 部署完成\n'
    printf '========================================\n'
    printf '监听地址：%s\n' "$LISTEN_ADDRESS"
    printf '端口：    %s\n' "$PORT"
    printf '协议：    TCP + UDP\n'
    printf '加密方式：%s\n' "$METHOD"
    printf 'PSK：     %s\n' "$PSK"
    printf '密钥文件：%s\n' "$KEY_FILE"
    printf '配置文件：%s\n' "$CONFIG_FILE"
    printf '服务名称：%s\n' "$SERVICE_NAME"
    if [ -n "$SS_URI" ]; then
        printf '\nShadowsocks URI：\n%s\n' "$SS_URI"
    else
        printf '\n未能自动确定公网地址，因此未生成 URI。\n'
        printf '请使用服务器公网 IPv6 地址替换下方地址：\n'
        printf '地址：服务器公网 IPv6 或域名\n'
        printf '端口：%s\n' "$PORT"
        printf '加密方式：%s\n' "$METHOD"
        printf '密码：%s\n' "$PSK"
    fi
    printf '\n请在 VPS 安全组/云防火墙放行 TCP 和 UDP 端口 %s。\n' "$PORT"
    if [ -n "$BACKUP_DIR" ]; then
        printf '旧文件备份：%s\n' "$BACKUP_DIR"
    fi
    printf '========================================\n'
}

main() {
    require_root_and_alpine
    acquire_lock
    install_dependencies
    prompt_port
    prompt_psk
    prompt_server_address
    backup_existing_files
    if service_is_enabled; then
        enabled_state=0
    else
        enabled_state=$?
    fi
    if [ "$enabled_state" -eq 0 ]; then
        SERVICE_WAS_ENABLED=1
    elif [ "$enabled_state" -ne 1 ]; then
        die "无法查询 OpenRC default runlevel 状态。"
    fi
    stop_existing_service
    check_port_is_free
    write_key_file
    write_config
    write_service
    prepare_logs
    start_service
    verify_listener

    SERVICE_ADD_ATTEMPTED=1
    if ! rc-update add "$SERVICE_NAME" default; then
        die "设置 OpenRC 开机启动失败。"
    fi
    print_summary
}

main "$@"
