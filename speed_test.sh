#!/bin/bash

# speed_test.sh - Тест скорости интернета
# Использует speedtest-cli для измерения скорости и сохраняет историю

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Директории и файлы
SCRIPT_DIR="$HOME/.speedtest"
DATA_DIR="$SCRIPT_DIR/data"
LOG_FILE="$SCRIPT_DIR/speedtest.log"
HISTORY_FILE="$DATA_DIR/history.csv"
CONFIG_FILE="$SCRIPT_DIR/config.conf"

# Создаем необходимые директории
mkdir -p "$DATA_DIR"

# Значения по умолчанию
DEFAULT_SERVER=""
TEST_DURATION=10
MAX_HISTORY_RECORDS=100

# Функция для логирования
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Функция для показа помощи
show_help() {
    echo "Использование: $0 [опции]"
    echo
    echo "Опции:"
    echo "  -h, --help          Показать эту справку"
    echo "  -s, --simple        Простой вывод (без цветов и графиков)"
    echo "  -g, --graph         Показать графики истории"
    echo "  -l, --list          Показать последние результаты"
    echo "  -c, --clear         Очистить историю"
    echo "  -n, --now           Выполнить тест сейчас"
    echo "  --server ID         Использовать конкретный сервер (ID)"
    echo "  --duration SEC      Длительность теста в секундах (по умолчанию: 10)"
    echo
    echo "Примеры:"
    echo "  $0                  Выполнить тест и показать результаты"
    echo "  $0 -g               Показать графики истории"
    echo "  $0 --server 1234    Использовать сервер с ID 1234"
}

# Функция для проверки наличия speedtest-cli
check_speedtest_cli() {
    if ! command -v speedtest-cli &> /dev/null; then
        echo -e "${RED}Ошибка: speedtest-cli не установлен${NC}"
        echo "Установите его командой:"
        echo "Ubuntu/Debian: sudo apt install speedtest-cli"
        echo "Или: pip install speedtest-cli"
        exit 1
    fi
}

# Функция для проверки наличия gnuplot (для графиков)
check_gnuplot() {
    if ! command -v gnuplot &> /dev/null; then
        echo -e "${YELLOW}Предупреждение: gnuplot не установлен${NC}"
        echo "Для отображения графиков установите его:"
        echo "sudo apt install gnuplot"
        return 1
    fi
    return 0
}

# Функция для выполнения теста скорости
run_speedtest() {
    local server_id="$1"
    local duration="$2"
    
    echo -e "${BLUE}Запуск теста скорости интернета...${NC}"
    log_message "Начало теста скорости"
    
    # Подготовка команды speedtest
    local cmd="speedtest-cli --simple"
    
    if [ -n "$server_id" ]; then
        cmd="$cmd --server $server_id"
    fi
    
    # Выполняем тест
    local start_time=$(date +%s)
    local res
    res=$(eval "$cmd")  # $(eval "$cmd" 2>&1)
    local exit_code=0
    local end_time=$(date +%s)
    
    local test_duration=$((end_time - start_time))
    
    if [ $exit_code -ne 0 ]; then
        echo -e "${RED}Ошибка выполнения теста:${NC}"
        echo "$res"
        log_message "Ошибка теста: $res"
        return 1
    fi
    
    # Парсим результаты
    local ping=$(echo "$res" | grep "Ping:" | awk '{print $2}')
    local download=$(echo "$res" | grep "Download:" | awk '{print $2}')
    local upload=$(echo "$res" | grep "Upload:" | awk '{print $2}')
    
    # Проверяем, что все значения получены
    if [ -z "$ping" ] || [ -z "$download" ] || [ -z "$upload" ]; then
        echo -e "${RED}Ошибка: не удалось получить результаты теста${NC}"
        echo "$res"
        return 1
    fi
    
    # Сохраняем результаты
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local date_iso=$(date '+%Y-%m-%d')
    local time_iso=$(date '+%H:%M')
    
    # Записываем в CSV файл
    if [ ! -f "$HISTORY_FILE" ]; then
        echo "timestamp,date,time,ping,download,upload,duration" > "$HISTORY_FILE"
    fi
    
    echo "$timestamp,$date_iso,$time_iso,$ping,$download,$upload,$test_duration" >> "$HISTORY_FILE"
    
    # Ограничиваем размер истории
    limit_history_records
    
    # Выводим результаты
    echo -e "${GREEN}Тест завершен за ${test_duration} секунд${NC}"
    log_message "Тест завершен: Ping=${ping}ms, Download=${download}Mbps, Upload=${upload}Mbps"
    
    # Возвращаем результаты
    echo "$ping,$download,$upload,$test_duration"
}

# Функция для ограничения количества записей в истории
limit_history_records() {
    if [ -f "$HISTORY_FILE" ]; then
        local line_count=$(wc -l < "$HISTORY_FILE")
        if [ "$line_count" -gt "$MAX_HISTORY_RECORDS" ]; then
            local lines_to_keep=$((MAX_HISTORY_RECORDS + 1))  # +1 для заголовка
            tail -n "$lines_to_keep" "$HISTORY_FILE" > "$HISTORY_FILE.tmp"
            mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"
        fi
    fi
}

# Функция для форматированного вывода результатов
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
    
    # Определяем качество соединения
    local download_quality="Плохое"
    local upload_quality="Плохое"
    
    if (( $(echo "$download > 50" | bc -l) )); then
        download_quality="Отличное"
    elif (( $(echo "$download > 20" | bc -l) )); then
        download_quality="Хорошее"
    elif (( $(echo "$download > 5" | bc -l) )); then
        download_quality="Удовлетворительное"
    fi
    
    if (( $(echo "$upload > 10" | bc -l) )); then
        upload_quality="Отличное"
    elif (( $(echo "$upload > 5" | bc -l) )); then
        upload_quality="Хорошее"
    elif (( $(echo "$upload > 1" | bc -l) )); then
        upload_quality="Удовлетворительное"
    fi
    
    echo -e "${YELLOW}Время теста:${NC} $(date)"
    echo -e "${YELLOW}Длительность:${NC} ${duration} секунд"
    echo
    
    echo -e "${CYAN}Пинг:${NC} ${ping} ms"
    echo -e "${GREEN}Скачивание:${NC} ${download} Mbps ${GREEN}[$download_quality]${NC}"
    echo -e "${PURPLE}Отправка:${NC} ${upload} Mbps ${PURPLE}[$upload_quality]${NC}"
    echo
    
    # Визуализация скорости
    echo -e "${GREEN}Скачивание:${NC}"
    draw_bar "$download" 100 "█" "$GREEN" "$NC"
    
    echo -e "${PURPLE}Отправка:${NC}"
    draw_bar "$upload" 50 "█" "$PURPLE" "$NC"
    
    echo
    echo -e "${BLUE}================================${NC}"
}

# Функция для отрисовки прогресс-бара
draw_bar() {
    local value="$1"
    local max_value="$2"
    local char="$3"
    local color_start="$4"
    local color_end="$5"
    
    local bar_length=30
    local filled_length=$(echo "scale=0; ($value / $max_value) * $bar_length" | bc -l | cut -d'.' -f1)
    
    # Ограничиваем максимальную длину
    if [[ $filled_length -gt $bar_length ]]; then
        filled_length=$bar_length
    fi
    
    local empty_length=$((bar_length - filled_length))
    
    echo -n "$color_start"
    for ((i=0; i<filled_length; i++)); do
        echo -n "$char"
    done
    echo -n "$color_end"
    
    for ((i=0; i<empty_length; i++)); do
        echo -n "░"
    done
    
    echo " ${value} Mbps"
}

# Функция для показа последних результатов
show_last_results() {
    local count="${1:-10}"
    local simple="$2"
    
    if [ ! -f "$HISTORY_FILE" ] || [ ! -s "$HISTORY_FILE" ]; then
        echo -e "${YELLOW}История тестов пуста${NC}"
        return
    fi
    
    if [ "$simple" = "true" ]; then
        tail -n "$count" "$HISTORY_FILE" | column -t -s ','
        return
    fi
    
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}    ПОСЛЕДНИЕ РЕЗУЛЬТАТЫ${NC}"
    echo -e "${BLUE}================================${NC}"
    echo
    
    # Показываем заголовок
    head -n 1 "$HISTORY_FILE" | tr ',' '\t'
    echo "--------------------------------------------------"
    
    # Показываем последние результаты
    tail -n "$count" "$HISTORY_FILE" | tail -n +2 | while IFS=',' read -r timestamp date time ping download upload duration; do
        printf "%-16s %-8s %-6s %-8s %-10s %-8s %-8s\n" "$date" "$time" "$ping" "$download" "$upload" "$duration"
    done
}

# Функция для создания графиков
create_graphs() {
    if ! check_gnuplot; then
        echo -e "${RED}Невозможно создать графики: gnuplot не установлен${NC}"
        return 1
    fi
    
    if [ ! -f "$HISTORY_FILE" ] || [ $(wc -l < "$HISTORY_FILE") -lt 2 ]; then
        echo -e "${YELLOW}Недостаточно данных для создания графиков${NC}"
        return 1
    fi
    
    echo -e "${BLUE}Создание графиков...${NC}"
    
    # Создаем временные файлы для данных
    local temp_data="/tmp/speedtest_data.tmp"
    local plot_script="/tmp/speedtest_plot.gp"
    
    # Подготавливаем данные (исключаем заголовок)
    tail -n +2 "$HISTORY_FILE" > "$temp_data"
    
    # Создаем скрипт gnuplot для скорости
    cat > "$plot_script" << 'EOF'
set terminal png size 800,600
set output '/tmp/speedtest_speed.png'
set title "Скорость интернета (Mbps)"
set xlabel "Дата и время"
set ylabel "Скорость (Mbps)"
set grid
set xdata time
set timefmt "%Y-%m-%d %H:%M:%S"
set format x "%m/%d\n%H:%M"
set key outside
plot '/tmp/speedtest_data.tmp' using 1:5 with linespoints title "Download" lw 2, \
     '/tmp/speedtest_data.tmp' using 1:6 with linespoints title "Upload" lw 2
EOF
    
    gnuplot "$plot_script"
    
    # Создаем скрипт для пинга
    cat > "$plot_script" << 'EOF'
set terminal png size 800,600
set output '/tmp/speedtest_ping.png'
set title "Пинг (ms)"
set xlabel "Дата и время"
set ylabel "Пинг (ms)"
set grid
set xdata time
set timefmt "%Y-%m-%d %H:%M:%S"
set format x "%m/%d\n%H:%M"
plot '/tmp/speedtest_data.tmp' using 1:4 with linespoints title "Ping" lw 2 lc rgb "red"
EOF
    
    gnuplot "$plot_script"
    
    # Показываем графики (если доступен просмотр изображений)
    echo -e "${GREEN}Графики сохранены:${NC}"
    echo "/tmp/speedtest_speed.png"
    echo "/tmp/speedtest_ping.png"
    
    if command -v xdg-open &> /dev/null; then
        echo
        echo -e "${YELLOW}Открыть графики? (y/N):${NC}"
        read -r answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            xdg-open "/tmp/speedtest_speed.png" &
            xdg-open "/tmp/speedtest_ping.png" &
        fi
    fi
    
    # Очищаем временные файлы
    rm -f "$temp_data" "$plot_script"
}

# Функция для очистки истории
clear_history() {
    if [ -f "$HISTORY_FILE" ]; then
        rm -f "$HISTORY_FILE"
        echo -e "${GREEN}История очищена${NC}"
        log_message "История очищена"
    else
        echo -e "${YELLOW}История уже пуста${NC}"
    fi
}

# Функция для показа статистики
show_statistics() {
    if [ ! -f "$HISTORY_FILE" ] || [ $(wc -l < "$HISTORY_FILE") -lt 2 ]; then
        echo -e "${YELLOW}Недостаточно данных для статистики${NC}"
        return
    fi
    
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}    СТАТИСТИКА ТЕСТОВ${NC}"
    echo -e "${BLUE}================================${NC}"
    echo
    
    # Используем awk для расчета статистики
    tail -n +2 "$HISTORY_FILE" | awk -F',' '
    BEGIN {
        count = 0
        min_ping = 999999
        max_ping = 0
        sum_ping = 0
        min_download = 999999
        max_download = 0
        sum_download = 0
        min_upload = 999999
        max_upload = 0
        sum_upload = 0
    }
    {
        count++
        ping = $4
        download = $5
        upload = $6
        
        sum_ping += ping
        sum_download += download
        sum_upload += upload
        
        if (ping > max_ping) max_ping = ping
        if (ping < min_ping) min_ping = ping
        if (download > max_download) max_download = download
        if (download < min_download) min_download = download
        if (upload > max_upload) max_upload = upload
        if (upload < min_upload) min_upload = upload
    }
    END {
        if (count > 0) {
            avg_ping = sum_ping / count
            avg_download = sum_download / count
            avg_upload = sum_upload / count
            
            printf "Всего тестов: %d\n\n", count
            
            printf "Пинг (ms):\n"
            printf "  Средний: %.2f\n", avg_ping
            printf "  Минимальный: %.2f\n", min_ping
            printf "  Максимальный: %.2f\n\n", max_ping
            
            printf "Скачивание (Mbps):\n"
            printf "  Средняя: %.2f\n", avg_download
            printf "  Минимальная: %.2f\n", min_download
            printf "  Максимальная: %.2f\n\n", max_download
            
            printf "Отправка (Mbps):\n"
            printf "  Средняя: %.2f\n", avg_upload
            printf "  Минимальная: %.2f\n", min_upload
            printf "  Максимальная: %.2f\n", max_upload
        }
    }'
}

# Основная функция
main() {
    local server_id=""
    local duration="$TEST_DURATION"
    local simple_output=false
    local show_graphs=false
    local show_list=false
    local clear_hist=false
    local run_now=false
    local show_stats=false
    
    # Обработка аргументов командной строки
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -s|--simple)
                simple_output=true
                shift
                ;;
            -g|--graph)
                show_graphs=true
                shift
                ;;
            -l|--list)
                show_list=true
                shift
                ;;
            -c|--clear)
                clear_hist=true
                shift
                ;;
            -n|--now)
                run_now=true
                shift
                ;;
            --server)
                server_id="$2"
                shift 2
                ;;
            --duration)
                duration="$2"
                shift 2
                ;;
            --stats)
                show_stats=true
                shift
                ;;
            *)
                echo -e "${RED}Неизвестный параметр: $1${NC}"
                show_help
                exit 1
                ;;
        esac
    done
    
    # Выполняем запрошенные действия
    if [ "$clear_hist" = true ]; then
        clear_history
        exit 0
    fi
    
    if [ "$show_list" = true ]; then
        show_last_results 20 "$simple_output"
        exit 0
    fi
    
    if [ "$show_graphs" = true ]; then
        create_graphs
        exit 0
    fi
    
    if [ "$show_stats" = true ]; then
        show_statistics
        exit 0
    fi
    
    # Проверяем зависимости
    check_speedtest_cli
    
    # Выполняем тест скорости
    local res1
    res1=$(run_speedtest "$server_id" "$duration")
    
    if [ $? -eq 0 ]; then
        # Разбираем результаты
        IFS=',' read -r ping download upload test_duration <<< "$res1"
        
        # Показываем результаты
        show_results "$ping" "$download" "$upload" "$test_duration" "$simple_output"
        
        # Показываем статистику по последним тестам
        if [ "$simple_output" = false ]; then
            echo
            echo -e "${YELLOW}Последние 5 тестов:${NC}"
            show_last_results 5 true
        fi
    else
        exit 1
    fi
}

# Запуск основной функции
main "$@"