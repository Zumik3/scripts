#!/bin/bash

# system_monitor.sh - Улучшенный мониторинг системы Linux
# Показывает CPU, RAM, disk, температуру, процессы и отправляет уведомления

# Фиксируем локаль для корректной работы с числами
export LC_ALL=C

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Пороговые значения (в процентах)
CPU_THRESHOLD=80
RAM_THRESHOLD=85
DISK_THRESHOLD=90

# Файл лога
LOG_FILE="/var/log/system_monitor.log"

# Функция для логирования (без падения при отсутствии прав)
log_message() {
    local msg="$(date '+%Y-%m-%d %H:%M:%S') - $1"
    echo "$msg"
    # Пытаемся записать в лог, игнорируем ошибки
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

# Функция для получения использования CPU (стабильный способ)
get_cpu_usage() {
    local cpu_idle=$(vmstat 1 2 | awk 'END {print $15}')
    echo $((100 - cpu_idle))
}

# Функция для получения использования RAM
get_ram_usage() {
    free | awk '/^Mem:/ {printf "%.0f", ($3 / $2) * 100}'
}

# Функция для получения использования диска
get_disk_usage() {
    df / | awk 'NR==2 {gsub(/%/,"",$5); print $5}'
}

# Функция для получения использования Swap
get_swap_usage() {
    free | awk '/^Swap:/ {if ($2 == 0) print 0; else printf "%.0f", ($3 / $2) * 100}'
}

# Функция для получения температуры CPU
get_cpu_temp() {
    local temp_c="N/A"

    # Raspberry Pi / многих embedded
    if [ -f "/sys/class/thermal/thermal_zone0/temp" ]; then
        temp=$(cat /sys/class/thermal/thermal_zone0/temp)
        temp_c=$((temp / 1000))
    # Десктопы/ноутбуки с lm-sensors
    elif command -v sensors &> /dev/null; then
        temp_c=$(sensors | awk '
            /^Core/ || /CPU Temp/ || /Package/ {
                gsub(/\\+|°C|\\(|\\)/, "", $2);
                if ($2+0 > 0) { print $2+0; exit }
            }
        ')
        temp_c=${temp_c:-"N/A"}
    fi

    echo "${temp_c}°C"
}

# Функция для отправки уведомлений
send_notification() {
    local title="$1"
    local message="$2"
    local level="$3"  # info, warning, critical
    
    log_message "[$level] $title: $message"
    
    # Отправка уведомления на рабочий стол (если доступно)
    if command -v notify-send &> /dev/null && [ -n "$DISPLAY" ]; then
        case $level in
            "critical")
                notify-send -u critical -t 5000 "$title" "$message"
                ;;
            "warning")
                notify-send -u normal -t 3000 "$title" "$message"
                ;;
            *)
                notify-send -u low -t 2000 "$title" "$message"
                ;;
        esac
    fi
    
    # Цветной вывод в консоль
    case $level in
        "critical")
            echo -e "${RED}[КРИТИЧНО] $title: $message${NC}"
            ;;
        "warning")
            echo -e "${YELLOW}[ПРЕДУПРЕЖДЕНИЕ] $title: $message${NC}"
            ;;
        *)
            echo -e "${GREEN}[ИНФО] $title: $message${NC}"
            ;;
    esac
}

# Функция для проверки порогов
check_thresholds() {
    local cpu=$1
    local ram=$2
    local disk=$3
    
    if [ "$cpu" -gt "$CPU_THRESHOLD" ]; then
        send_notification "Высокая нагрузка CPU" "Использование CPU: ${cpu}%" "critical"
    fi
    
    if [ "$ram" -gt "$RAM_THRESHOLD" ]; then
        send_notification "Высокое использование RAM" "Использование RAM: ${ram}%" "warning"
    fi
    
    if [ "$disk" -gt "$DISK_THRESHOLD" ]; then
        send_notification "Мало свободного места" "Использование диска: ${disk}%" "critical"
    fi
}

# Универсальная функция для вывода top процессов
show_top_processes() {
    local sort_key="$1"
    local title="$2"
    local field=3

    # Определяем номер поля для сортировки
    case "$sort_key" in
        "%cpu") field=3 ;;
        "%mem") field=4 ;;
        "rss")  field=6 ;;
        *)      field=3 ;;
    esac

    # Заголовок
    printf '%b\n' "${YELLOW}=== Топ 5 процессов по $title ===${NC}"
    echo

    # Шапка таблицы
    printf "${BLUE}%-10s %-8s %-8s %-10s %-12s %s${NC}\n" \
        "USER" "PID" "$sort_key" "VSZ (MB)" "RSS (MB)" "COMMAND"

    # Разделитель
    printf "${BLUE}%-10s %-8s %-8s %-10s %-12s %s${NC}\n" \
        "----------" "--------" "--------" "----------" "------------" "----------------------------------------"

    # Данные через awk
    ps aux --sort=-"$sort_key" | awk -v field="$field" '
    NR == 1 { next }           # Пропускаем заголовок ps
    NR > 6  { exit }           # Только первые 5 процессов

    {
        user = $1
        pid  = $2
        cpu  = $3
        mem  = $4
        vsz  = int($5 / 1024)   # KB → MB
        rss  = int($6 / 1024)   # KB → MB

        # Собираем команду
        cmd = ""
        for (i = 11; i <= NF; i++) {
            cmd = cmd " " $i
        }
        gsub(/^ +/, "", cmd)
        if (cmd == "") cmd = "<none>"

        # Определяем цвет в зависимости от типа сортировки и значения
        if (field == 3 && $3 > 50) {
            color = "\033[1;31m"   # Красный: высокий CPU
        } else if (field == 3 && $3 > 20) {
            color = "\033[1;33m"   # Жёлтый: средний CPU
        } else if (field == 4 && $4 > 20) {
            color = "\033[1;33m"   # Жёлтый: высокая RAM
        } else {
            color = "\033[0;32m"   # Зелёный: норма
        }

        # Сбрасываем цвет после значения
        reset = "\033[0m"

        # Форматированный вывод
        printf "%-10s %-8s %s%-8s%s %-10d %-12d %s\n",
            user, pid, color, sprintf("%.1f", $field), reset, vsz, rss, cmd
    }'

    echo
}

# Функция для вывода всей системной информации
show_system_info() {
    local cpu=$1
    local ram=$2
    local disk=$3
    local temp=$4
    local swap=$5

    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}    СИСТЕМНЫЙ МОНИТОРИНГ${NC}"
    echo -e "${BLUE}================================${NC}"
    echo

    # Общая информация
    echo -e "${GREEN}Система:${NC} $(hostnamectl)"
    echo -e "${GREEN}Время:${NC} $(date)"
    echo -e "${GREEN}Uptime:${NC} $(uptime -p 2>/dev/null || echo 'N/A')"
    echo

    # Ресурсы
    echo -e "${YELLOW}=== Использование ресурсов ===${NC}"

    # CPU
    if [ "$cpu" -gt "$CPU_THRESHOLD" ]; then
        echo -e "${RED}CPU:${NC} ${cpu}% ${RED}[ВЫСОКАЯ НАГРУЗКА]${NC}"
    else
        echo -e "${GREEN}CPU:${NC} ${cpu}%"
    fi

    # RAM
    if [ "$ram" -gt "$RAM_THRESHOLD" ]; then
        echo -e "${RED}RAM:${NC} ${ram}% ${RED}[ВЫСОКОЕ ИСПОЛЬЗОВАНИЕ]${NC}"
    else
        echo -e "${GREEN}RAM:${NC} ${ram}%"
    fi

    # Диск
    if [ "$disk" -gt "$DISK_THRESHOLD" ]; then
        echo -e "${RED}Диск:${NC} ${disk}% ${RED}[МАЛО МЕСТА]${NC}"
    else
        echo -e "${GREEN}Диск:${NC} ${disk}%"
    fi

    # Swap
    if [ "$swap" -gt 50 ]; then
        echo -e "${YELLOW}Swap:${NC} ${swap}% ${YELLOW}[АКТИВЕН]${NC}"
    else
        echo -e "${GREEN}Swap:${NC} ${swap}%"
    fi

    # Температура
    echo -e "${GREEN}Температура:${NC} $temp"

    # Top процессы
    echo
    show_top_processes "%cpu" "CPU"
    echo
    show_top_processes "%mem" "RAM"
}

# Основная функция
main() {
    # Создаём директорию и файл лога с правами текущего пользователя
    sudo mkdir -p "$(dirname "$LOG_FILE")"
    if [ ! -f "$LOG_FILE" ]; then
        sudo touch "$LOG_FILE"
        sudo chown "$USER":"$USER" "$LOG_FILE"
    fi

    # Получаем данные
    cpu_usage=$(get_cpu_usage)
    ram_usage=$(get_ram_usage)
    disk_usage=$(get_disk_usage)
    cpu_temp=$(get_cpu_temp)
    swap_usage=$(get_swap_usage)

    # Проверяем пороги
    check_thresholds "$cpu_usage" "$ram_usage" "$disk_usage"

    # Выводим информацию
    show_system_info "$cpu_usage" "$ram_usage" "$disk_usage" "$cpu_temp" "$swap_usage"

    # Дополнительная информация
    echo
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}    Дополнительная информация${NC}"
    echo -e "${BLUE}================================${NC}"

    # Количество процессов
    process_count=$(ps aux | wc -l)
    echo -e "${GREEN}Активных процессов:${NC} $((process_count - 1))"

    # Сетевая статистика (если vnstat установлен)
    if command -v vnstat &> /dev/null; then
        iface=$(ip route | grep default | awk '{print $5}' | head -1)
        if [ -n "$iface" ]; then
            echo -e "${GREEN}Трафик ($iface):${NC}"
            vnstat -i "$iface" --oneline | cut -d';' -f4,5 | \
                awk -F';' '{print "  Вход: " $1 "   Выход: " $2}'
        fi
    fi

    # Проверка логов на критические ошибки
    if [ -f "/var/log/syslog" ]; then
        critical_errors=$(tail -30 /var/log/syslog | grep -iE "error|critical|fail|warn" | grep -c .)
        if [ "$critical_errors" -gt 0 ]; then
            echo -e "${RED}Ошибок в /var/log/syslog:${NC} $critical_errors (см. последние 30 строк)"
        fi
    fi
}

# Непрерывный мониторинг
continuous_monitor() {
    local interval=${1:-60}
    echo "Непрерывный мониторинг каждые $interval секунд. Нажмите Ctrl+C для остановки."
    while true; do
        clear
        main
        sleep "$interval"
    done
}

# Обработка аргументов
case "${1:-}" in
    "--continuous"|"--c")
        continuous_monitor "${2:-60}"
        ;;
    "--log"|"--l")
        # Только логирование и проверка порогов
        cpu_usage=$(get_cpu_usage)
        ram_usage=$(get_ram_usage)
        disk_usage=$(get_disk_usage)
        check_thresholds "$cpu_usage" "$ram_usage" "$disk_usage"
        ;;
    "--help"|"-h")
        echo "Использование: $0 [опции]"
        echo "Опции:"
        echo "  (без опций)       - показать информацию один раз"
        echo "  --continuous N    - непрерывный мониторинг каждые N секунд (по умолчанию 60)"
        echo "  --log             - только проверить и залогировать (без вывода)"
        echo "  --help            - показать эту справку"
        echo
        echo "Пороги:"
        echo "  CPU:  $CPU_THRESHOLD%"
        echo "  RAM:  $RAM_THRESHOLD%"
        echo "  Диск: $DISK_THRESHOLD%"
        ;;
    *)
        main
        ;;
esac