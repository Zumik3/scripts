#!/bin/bash
# speed_test.sh - Тест скорости интернета с графиками и Telegram-уведомлениями

# Фиксируем локаль для корректной работы с числами
export LC_ALL=C

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Директории и файлы
SCRIPT_DIR="$HOME/.speedtest"
DATA_DIR="$SCRIPT_DIR/data"
LOG_FILE="$SCRIPT_DIR/speedtest.log"
HISTORY_FILE="$DATA_DIR/history.csv"
TELEGRAM_CONFIG_FILE="$SCRIPT_DIR/telegram.conf"
GRAPH_SPEED="/tmp/speedtest_speed.png"

# Значения по умолчанию
MAX_HISTORY_RECORDS=100

# Функция для проверки зависимостей
check_dependencies() {
    local missing_deps=()
    
    # Проверяем необходимые команды
    for cmd in awk grep bc curl; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo -e "${RED}Ошибка: отсутствуют необходимые команды:${NC}"
        printf '%s\n' "${missing_deps[@]}"
        exit 1
    fi
}

# Функция для логирования
log_message() {
    local msg="$(date '+%Y-%m-%d %H:%M:%S') - $1"
    
    # Создаем директорию для лога если её нет
    local log_dir=$(dirname "$LOG_FILE")
    if [ ! -d "$log_dir" ]; then
        mkdir -p "$log_dir" 2>/dev/null || return 1
    fi
    
    # Пытаемся записать в лог, игнорируем ошибки
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

# Функция для валидации server_id
validate_server_id() {
    local server_id="$1"
    
    if [ -z "$server_id" ]; then
        return 0  # Пустой server_id допустим
    fi
    
    # Проверяем, что server_id содержит только цифры
    if ! [[ "$server_id" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Ошибка: server_id должен быть числом${NC}" >&2
        return 1
    fi
    
    # Проверяем разумные границы
    if [ "$server_id" -lt 1 ] || [ "$server_id" -gt 999999 ]; then
        echo -e "${RED}Ошибка: server_id должен быть в диапазоне 1-999999${NC}" >&2
        return 1
    fi
    
    return 0
}

# Функция для показа помощи
show_help() {
    cat << EOF
Использование: $0 [опции]
Опции:
  -h, --help          Показать эту справку
  -s, --simple        Простой вывод (без цветов и графиков)
  -g, --graph         Показать графики истории
  -l, --list          Показать последние результаты
  -c, --clear         Очистить историю

  --server ID         Использовать конкретный сервер (ID)
  --stats             Показать статистику по истории

Примеры:
  $0                  Выполнить тест и показать результаты
  $0 -g               Показать графики истории
  $0 --server 1234    Использовать сервер с ID 1234
EOF
}

# Проверка speedtest (официальный от Ookla)
check_speedtest() {
    if ! command -v speedtest &> /dev/null; then
        echo -e "${RED}Ошибка: speedtest (Ookla) не установлен${NC}"
        echo "Установите: https://www.speedtest.net/apps/cli"
        exit 1
    fi
}

# Проверка bc
check_bc() {
    if ! command -v bc &> /dev/null; then
        echo -e "${RED}Ошибка: 'bc' не установлен${NC}"
        echo "sudo apt install bc"
        exit 1
    fi
}

# Проверка gnuplot
check_gnuplot() {
    if ! command -v gnuplot &> /dev/null; then
        echo -e "${YELLOW}Предупреждение: gnuplot не установлен${NC}"
        echo "Для графиков: sudo apt install gnuplot"
        return 1
    fi
    return 0
}

# Создание безопасных временных файлов
create_temp_files() {
    local temp_data
    local plot_script
    
    temp_data=$(mktemp "/tmp/speedtest_data.XXXXXXXXXX" 2>/dev/null || echo "/tmp/speedtest_data.tmp")
    plot_script=$(mktemp "/tmp/speedtest_plot.XXXXXXXXXX" 2>/dev/null || echo "/tmp/speedtest_plot.gp")
    
    echo "$temp_data:$plot_script"
}

# Очистка временных файлов
cleanup_temp_files() {
    local temp_data="$1"
    local plot_script="$2"
    
    rm -f "$temp_data" "$plot_script" 2>/dev/null || true
}

# Загрузка конфига Telegram
if [ -f "$TELEGRAM_CONFIG_FILE" ]; then
    if [ -r "$TELEGRAM_CONFIG_FILE" ] && [ "$(stat -c %a "$TELEGRAM_CONFIG_FILE" 2>/dev/null)" = "600" ]; then
        . "$TELEGRAM_CONFIG_FILE"
    else
        echo -e "${YELLOW}Предупреждение: небезопасные права на $TELEGRAM_CONFIG_FILE${NC}"
        TELEGRAM_ENABLED=false
    fi
else
    TELEGRAM_ENABLED=false
fi

# Функция для выполнения теста скорости
run_speedtest() {
    local server_id="$1"
    echo -e "${BLUE}Запуск теста скорости интернета...${NC}" >&2
    log_message "Начало теста скорости"

    # Валидация server_id
    if ! validate_server_id "$server_id"; then
        return 1
    fi

    # Безопасное формирование команды
    local cmd_args=("speedtest-cli" "--csv")
    if [ -n "$server_id" ]; then
        cmd_args+=("--server" "$server_id")
    fi

    local start_time=$(date +%s)
    local res
    res=$("${cmd_args[@]}" 2>&1)
    local exit_code=$?
    local end_time=$(date +%s)
    local test_duration=$((end_time - start_time))

    if [ $exit_code -ne 0 ]; then
        echo -e "${RED}Ошибка выполнения speedtest-cli:${NC}" >&2
        echo "$res" >&2
        log_message "Ошибка: $res"
        return 1
    fi

    # Проверка вывода
    if [ -z "$res" ]; then
        echo -e "${RED}Ошибка: пустой вывод от speedtest-cli${NC}" >&2
        return 1
    fi
    
    # Проверка на ошибки в выводе
    if echo "$res" | grep -qi "error\|fail\|not found\|timeout\|connection"; then
        echo -e "${RED}Ошибка: speedtest-cli сообщил об ошибке${NC}" >&2
        echo "$res" >&2
        return 1
    fi

    # Парсим поля (формат: server_id, name, city, ts, distance, ping, download, upload, , ip)
    IFS=',' read -ra fields <<< "$res"
    if [ ${#fields[@]} -lt 8 ]; then
        echo -e "${RED}Ошибка: слишком мало полей в выводе${NC}" >&2
        echo "Получено: $res" >&2
        return 1
    fi

    local ping="${fields[5]}"    # 6-е поле
    local download_bps="${fields[6]}"  # 7-е поле
    local upload_bps="${fields[7]}"    # 8-е поле

    # Проверка чисел
    if ! [[ "$ping" =~ ^[0-9]+\.?[0-9]*$ ]] || \
       ! [[ "$download_bps" =~ ^[0-9]+\.?[0-9]*$ ]] || \
       ! [[ "$upload_bps" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        echo -e "${RED}Ошибка: не удалось извлечь числовые значения${NC}" >&2
        echo "Ping: '$ping', Download: '$download_bps', Upload: '$upload_bps'" >&2
        return 1
    fi

    # Конвертируем в Mbps
    if ! command -v bc &> /dev/null; then
        echo -e "${RED}Ошибка: 'bc' не установлен${NC}" >&2
        return 1
    fi

    local download_mbps=$(echo "scale=2; $download_bps / 1000000" | bc -l 2>/dev/null || echo "0")
    local upload_mbps=$(echo "scale=2; $upload_bps / 1000000" | bc -l 2>/dev/null || echo "0")

    # Проверка результата
    if [ "$download_mbps" = "0" ] && [ $(echo "$download_bps > 10000" | bc -l 2>/dev/null || echo "0") -eq 1 ]; then
        echo -e "${RED}Ошибка: не удалось вычислить download Mbps${NC}" >&2
        return 1
    fi

    # Форматируем
    download_mbps=$(printf "%.2f" "$download_mbps")
    upload_mbps=$(printf "%.2f" "$upload_mbps")

    # Создаем необходимые директории
    if ! mkdir -p "$DATA_DIR" 2>/dev/null; then
        echo -e "${RED}Ошибка: не удалось создать директорию $DATA_DIR${NC}" >&2
        return 1
    fi

    # Сохраняем
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local date_iso=$(date '+%Y-%m-%d')
    local time_iso=$(date '+%H:%M')

    if [ ! -f "$HISTORY_FILE" ]; then
        echo "timestamp,date,time,ping,download,upload,duration" > "$HISTORY_FILE"
    fi
    echo "$timestamp,$date_iso,$time_iso,$ping,$download_mbps,$upload_mbps,$test_duration" >> "$HISTORY_FILE"

    limit_history_records
    log_message "Тест завершен: Ping=${ping}ms, Download=${download_mbps}Mbps, Upload=${upload_mbps}Mbps"

    echo "$ping,$download_mbps,$upload_mbps,$test_duration"
}

# Ограничение истории
limit_history_records() {
    if [ -f "$HISTORY_FILE" ]; then
        local line_count=$(wc -l < "$HISTORY_FILE" 2>/dev/null || echo "0")
        if [ "$line_count" -gt "$MAX_HISTORY_RECORDS" ]; then
            local lines_to_keep=$((MAX_HISTORY_RECORDS + 1))
            tail -n "$lines_to_keep" "$HISTORY_FILE" > "$HISTORY_FILE.tmp" && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"
        fi
    fi
}

# Вывод результатов
show_results() {
    local ping="$1"
    local download="$2"
    local upload="$3"
    local duration="$4"
    local simple="$5"

    if [ "$simple" = "true" ]; then
        echo "Ping: ${ping} ms"
        echo "Download: ${download} Mbps"
        echo "Upload: ${upload} Mbps"
        echo "Duration: ${duration} seconds"
        return
    fi

    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}    РЕЗУЛЬТАТЫ ТЕСТА СКОРОСТИ${NC}"
    echo -e "${BLUE}================================${NC}"
    echo

    local download_quality="Плохое"
    local upload_quality="Плохое"
    if (( $(echo "$download > 50" | bc -l 2>/dev/null || echo "0") )); then
        download_quality="Отличное"
    elif (( $(echo "$download > 20" | bc -l 2>/dev/null || echo "0") )); then
        download_quality="Хорошее"
    elif (( $(echo "$download > 5" | bc -l 2>/dev/null || echo "0") )); then
        download_quality="Удовлетворительное"
    fi
    if (( $(echo "$upload > 10" | bc -l 2>/dev/null || echo "0") )); then
        upload_quality="Отличное"
    elif (( $(echo "$upload > 5" | bc -l 2>/dev/null || echo "0") )); then
        upload_quality="Хорошее"
    elif (( $(echo "$upload > 1" | bc -l 2>/dev/null || echo "0") )); then
        upload_quality="Удовлетворительное"
    fi

    echo -e "${YELLOW}Время теста:${NC} $(date)"
    echo -e "${YELLOW}Длительность:${NC} ${duration} секунд"
    echo
    echo -e "${CYAN}Пинг:${NC} ${ping} ms"
    echo -e "${GREEN}Скачивание:${NC} ${download} Mbps ${GREEN}[$download_quality]${NC}"
    echo -e "${PURPLE}Отправка:${NC} ${upload} Mbps ${PURPLE}[$upload_quality]${NC}"
    echo

    echo -e "${GREEN}Скачивание:${NC}"
    draw_bar "$download" 100 "█" "$GREEN" "$NC"
    echo -e "${PURPLE}Отправка:${NC}"
    draw_bar "$upload" 50 "█" "$PURPLE" "$NC"
    echo
    echo -e "${BLUE}================================${NC}"
}

# Отрисовка бара
draw_bar() {
    local value="$1"
    local max_value="$2"
    local char="${3:-█}"
    local color_start="$4"
    local color_end="$5"
    local bar_length=30

    if ! [[ "$value" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        value=0
    fi

    local filled_length=$(echo "scale=0; ($value / $max_value) * $bar_length" | bc -l 2>/dev/null || echo "0")
    filled_length=$(echo "$filled_length" | cut -d'.' -f1)
    filled_length=$((filled_length > bar_length ? bar_length : filled_length))
    local empty_length=$((bar_length - filled_length))

    printf "%b" "$color_start"
    for ((i=0; i<filled_length; i++)); do
        printf "%b" "$char"
    done
    printf "%b" "$color_end"
    for ((i=0; i<empty_length; i++)); do
        printf "░"
    done
    printf " ${value} Mbps\n"
}

# Показ последних результатов
show_last_results() {
    local count="${1:-10}"
    local simple="$2"
    if [ ! -f "$HISTORY_FILE" ] || [ ! -s "$HISTORY_FILE" ]; then
        echo -e "${YELLOW}История тестов пуста${NC}"
        return
    fi
    if [ "$simple" = "true" ]; then
        tail -n "$count" "$HISTORY_FILE" | awk -F',' '{printf "%-19s %-10s %-8s %-10s %-10s %-8s\n", $1, $2, $3, $4, $5, $6}'
        return
    fi
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}    ПОСЛЕДНИЕ РЕЗУЛЬТАТЫ${NC}"
    echo -e "${BLUE}================================${NC}"
    echo
    head -n 1 "$HISTORY_FILE" | tr ',' '\t'
    echo "--------------------------------------------------"
    tail -n "$count" "$HISTORY_FILE" | tail -n +2 | while IFS=',' read -r timestamp date time ping download upload duration; do
        printf "%-16s %-8s %-6s %-8s %-10s %-8s\n" "$date" "$time" "$ping" "$download" "$upload" "$duration"
    done
}

# Функция для создания графиков (без подписи оси X и без рамки у легенды)
create_graphs() {
    if ! check_gnuplot; then
        echo -e "${RED}Невозможно создать графики: gnuplot не установлен${NC}"
        return 1
    fi

    if [ ! -f "$HISTORY_FILE" ] || [ $(wc -l < "$HISTORY_FILE" 2>/dev/null || echo "0") -lt 2 ]; then
        echo -e "${YELLOW}Недостаточно данных для создания графиков${NC}"
        return 1
    fi

    echo -e "${BLUE}Создание графиков...${NC}"

    # Создаем безопасные временные файлы
    local temp_files
    temp_files=$(create_temp_files)
    local temp_data=$(echo "$temp_files" | cut -d':' -f1)
    local plot_script=$(echo "$temp_files" | cut -d':' -f2)

    # Берём последние 5 тестов и нумеруем от 1 до 5
    tail -n +2 "$HISTORY_FILE" | tail -n 5 | \
        sed 's/"//g' | \
        awk -F',' '{
            test_num = NR
            print test_num, $4, $5, $6
        }' > "$temp_data"

    if [ ! -s "$temp_data" ]; then
        echo -e "${RED}Ошибка: временные данные пусты${NC}"
        cleanup_temp_files "$temp_data" "$plot_script"
        return 1
    fi

    # График скорости
    cat > "$plot_script" << EOF
set terminal png size 1000,650
set output '/tmp/speedtest_speed.png'
set title "Скорость интернета (последние 5 тестов)" font ",14"
set xlabel ""  # Пусто — убрали "Номер теста"
set ylabel "Скорость (Мбит/с)" font ",12"
set grid x y lt rgb "#cccccc" lw 1
set xrange [0.8:5.2]
set yrange [0:500]
set xtics 1
set key outside bottom center horizontal samplen 3 spacing 1.5 width 0 font ",11"
set key nobox  # Правильно: убираем рамку вокруг легенды
plot '$temp_data' using 1:3 with linespoints title "Скачивание (Download)" lw 2 lc rgb "blue" pt 7 ps 0.8, \
     '$temp_data' using 1:4 with linespoints title "Отправка (Upload)" lw 2 lc rgb "green" pt 5 ps 0.8
EOF

    if ! gnuplot "$plot_script" 2>/tmp/gnuplot_error.log; then
        echo -e "${RED}Ошибка gnuplot (график скорости)${NC}"
        cat /tmp/gnuplot_error.log >&2
        cleanup_temp_files "$temp_data" "$plot_script"
        return 1
    fi

    # Проверка результата
    if [ ! -s "/tmp/speedtest_speed.png" ]; then
        echo -e "${RED}Ошибка: график скорости пуст или не создан${NC}"
        cleanup_temp_files "$temp_data" "$plot_script"
        return 1
    fi

    echo -e "${GREEN}График успешно создан:${NC}"
    echo "  📈 /tmp/speedtest_speed.png"

    if command -v xdg-open &> /dev/null; then
        echo -e "${YELLOW}Открыть график? (y/N):${NC}"
        read -r answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            xdg-open "/tmp/speedtest_speed.png"
        fi
    fi

    cleanup_temp_files "$temp_data" "$plot_script"
}

# Экранирование текста для Telegram
escape_telegram_text() {
    local text="$1"
    # Экранируем специальные символы Markdown
    echo "$text" | sed 's/[][\\`*_{}|#+~]/\\&/g'
}

# Отправка в Telegram
send_to_telegram() {
    if [ "$TELEGRAM_ENABLED" != "true" ] || [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        return 0
    fi

    local ping="$1"
    local download="$2"
    local upload="$3"
    local duration="$4"

    # Экранируем значения для безопасной отправки
    local safe_ping=$(escape_telegram_text "$ping")
    local safe_download=$(escape_telegram_text "$download")
    local safe_upload=$(escape_telegram_text "$upload")
    local safe_duration=$(escape_telegram_text "$duration")

    local message="
📶 *Результаты теста скорости*

*Время:* $(date '+%Y-%m-%d %H:%M:%S')
*Длительность:* ${safe_duration} сек

*Пинг:* ${safe_ping} ms
*Скачивание:* ${safe_download} Mbps
*Отправка:* ${safe_upload} Mbps

#speedtest
"

    local url="https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage"
    local photo_url="https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendPhoto"

    # Отправляем текстовое сообщение
    curl -s -X POST "$url" \
        -d chat_id="$TELEGRAM_CHAT_ID" \
        -d text="$message" \
        -d parse_mode="Markdown" \
        -d disable_notification="true" \
        > /dev/null

    # Генерируем графики, если нужно
    if [ ! -f "$GRAPH_SPEED" ]; then
        create_graphs
    fi

    # Отправляем ТОЛЬКО график скорости
    if [ -f "$GRAPH_SPEED" ] && [ -s "$GRAPH_SPEED" ]; then
        curl -s -X POST "$photo_url" \
            -F chat_id="$TELEGRAM_CHAT_ID" \
            -F photo=@"$GRAPH_SPEED" \
            -F caption="📈 График скорости (последние 5 тестов)" \
            -F parse_mode="Markdown" \
            -F disable_notification="true" \
            > /dev/null
    fi

    log_message "Результат и график скорости отправлены в Telegram"
}

# Очистка истории
clear_history() {
    if [ -f "$HISTORY_FILE" ]; then
        rm -f "$HISTORY_FILE"
        echo -e "${GREEN}История очищена${NC}"
        log_message "История очищена"
    else
        echo -e "${YELLOW}История уже пуста${NC}"
    fi
}

# Статистика
show_statistics() {
    if [ ! -f "$HISTORY_FILE" ] || [ $(wc -l < "$HISTORY_FILE" 2>/dev/null || echo "0") -lt 2 ]; then
        echo -e "${YELLOW}Недостаточно данных${NC}"
        return
    fi
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}    СТАТИСТИКА ТЕСТОВ${NC}"
    echo -e "${BLUE}================================${NC}"
    echo
    tail -n +2 "$HISTORY_FILE" | awk -F',' '
    BEGIN {
        count = 0; min_ping = max_ping = sum_ping = 0
        min_download = max_download = sum_download = 0
        min_upload = max_upload = sum_upload = 0
    }
    {
        count++; ping = $4; download = $5; upload = $6
        sum_ping += ping; sum_download += download; sum_upload += upload
        if (count == 1 || ping < min_ping) min_ping = ping
        if (count == 1 || ping > max_ping) max_ping = ping
        if (count == 1 || download < min_download) min_download = download
        if (count == 1 || download > max_download) max_download = download
        if (count == 1 || upload < min_upload) min_upload = upload
        if (count == 1 || upload > max_upload) max_upload = upload
    }
    END {
        if (count > 0) {
            printf "Всего тестов: %d\n", count
            printf "Пинг:    Ср:%.2f  Мин:%.2f  Макс:%.2f\n", sum_ping/count, min_ping, max_ping
            printf "Скач.:   Ср:%.2f  Мин:%.2f  Макс:%.2f\n", sum_download/count, min_download, max_download
            printf "Отпр.:   Ср:%.2f  Мин:%.2f  Макс:%.2f\n", sum_upload/count, min_upload, max_upload
        }
    }'
}

# Обработчик сигналов для корректного завершения
cleanup() {
    echo -e "\n${YELLOW}Завершение теста скорости...${NC}"
    exit 0
}

# Устанавливаем обработчики сигналов
trap cleanup SIGINT SIGTERM

# Основная функция
main() {
    # Проверяем зависимости
    check_dependencies
    
    local server_id="" simple_output=false show_list=false clear_hist=false show_stats=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help) show_help; exit 0 ;;
            -s|--simple) simple_output=true ;;
            -g|--graph)
                check_gnuplot || exit 1
                create_graphs
                echo -e "${GREEN}Графики:${NC} $GRAPH_SPEED"
               if [ -n "$DISPLAY" ] && command -v xdg-open &> /dev/null; then
                    echo -e "${YELLOW}Открыть? (y/N):${NC}"
                    read -r ans
                    [[ "$ans" =~ ^[Yy]$ ]] && xdg-open "$GRAPH_SPEED"
                fi
                exit 0
                ;;
            -l|--list) show_list=true ;;
            -c|--clear) clear_hist=true ;;

            --server) 
                server_id="$2"
                if ! validate_server_id "$server_id"; then
                    exit 1
                fi
                shift 
                ;;
            --stats) show_stats=true ;;
            *) echo -e "${RED}Неизвестный параметр: $1${NC}"; show_help; exit 1 ;;
        esac
        shift
    done

    check_speedtest
    check_bc

    if [ "$clear_hist" = true ]; then clear_history; exit 0; fi
    if [ "$show_list" = true ]; then show_last_results 20 "$simple_output"; exit 0; fi
    if [ "$show_stats" = true ]; then show_statistics; exit 0; fi

    local res
    res=$(run_speedtest "$server_id")
    if [ $? -eq 0 ]; then
        IFS=',' read -r ping download upload duration <<< "$res"
        show_results "$ping" "$download" "$upload" "$duration" "$simple_output"
        send_to_telegram "$ping" "$download" "$upload" "$duration"
        [ "$simple_output" = false ] && show_last_results 5 true
    else
        echo -e "${RED}Тест завершился с ошибкой${NC}"
        exit 1
    fi
}

main "$@"