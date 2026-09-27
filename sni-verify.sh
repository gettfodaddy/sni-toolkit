#!/bin/bash
# ============================================================
# sni-verify.sh — глубокая проверка SNI-донора для Xray Reality
#
# ОДИН ФАЙЛ, НИЧЕГО ДОПОЛНИТЕЛЬНО СТАВИТЬ НЕ НАДО — использует только
# bash/curl/openssl/sed/awk/grep, которые есть на любой обычной VPS из
# коробки. mtr/traceroute — по желанию (без них просто пропускается один
# необязательный пункт отчёта, всё остальное работает).
#
# Установить и запустить — прямо с raw-ссылки СВОЕГО репозитория на GitHub
# (github.com/gettfodaddy/sni-toolkit), без стороннего хостинга/доменов:
#
#   Вариант 1 — сохранить как команду (можно запускать повторно):
#     curl -Ls https://raw.githubusercontent.com/gettfodaddy/sni-toolkit/<ветка>/sni-verify.sh \
#       -o /usr/local/bin/sni-verify && chmod +x /usr/local/bin/sni-verify
#     sni-verify -auto
#
#   Вариант 2 — одна строка, без сохранения файла (пайп сразу в bash):
#     wget -qO- https://raw.githubusercontent.com/gettfodaddy/sni-toolkit/<ветка>/sni-verify.sh | bash
#     # (или curl -Ls .../sni-verify.sh | bash)
#     # Без аргументов автоматически уходит в режим -auto — ничего
#     # дополнительно указывать не нужно. Передать флаги в этом виде запуска:
#     #   wget -qO- .../sni-verify.sh | bash -s -- -f candidates.txt
#
#   <ветка> — имя ветки репозитория (обычно main или master); точную
#   raw-ссылку проще всего взять кнопкой "Raw" на странице sni-verify.sh
#   в самом GitHub — она уже содержит правильную ветку.
#
# Запускать С ТОГО САМОГО сервера (ноды), для которого подбираешь донора —
# задержка/маршрут (п.8) важны именно оттуда, а не с локальной машины.
#
# Одиночный домен (цветной отчёт):
#   sni-verify www.example.com
#
# Пачка доменов из файла (по одному на строку) -> таблица + CSV:
#   sni-verify -f candidates.txt
#   sni-verify -f candidates.txt -out result.csv
#
# Авто-режим — сам определяет IP/страну ЭТОЙ ноды (через ip-api.com, без
# доп. файлов — список кандидатов по странам встроен прямо в скрипт, см.
# функцию country_candidates() ниже) и сразу проверяет их батчем:
#   sni-verify -auto
#   sni-verify -auto -out result.csv
#
# Не отсеивает результаты сама — печатает всё, что знает, и метку
# ГОТОВ/ПРОВЕРЬ/НЕ ГОДИТСЯ. Финальное решение — за тобой, особенно по
# post-quantum (см. пункт 4 — это НЕ автоматический провал, смотри текст).
# ============================================================
set -u

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
OK="${GREEN}[OK]${NC}"; FAIL="${RED}[FAIL]${NC}"; WARN="${YELLOW}[WARN]${NC}"; INFO="${CYAN}[INFO]${NC}"

# Стартовые кандидаты в SNI-доноры по стране ноды (ISO countryCode -> домены).
# НЕ гарантированно рабочие доноры — только отправная точка для -auto,
# дальше их всё равно прогоняет полная проверка ниже (TLS1.3/H2/PQ/
# сертификат/CDN/редиректы/маршрут). Хочешь добавить свою страну или
# поменять список — редактируй прямо этот case, файл самодостаточный.
country_candidates() {
    case "$1" in
        DE) echo "www.bosch.de www.siemens.com www.miele.de www.zalando.de www.dm.de www.hensoldt.net" ;;
        NL) echo "www.philips.com www.klm.com www.asml.com www.bol.com www.ing.nl www.tomtom.com" ;;
        FI) echo "www.nokia.com www.kone.com www.fortum.com www.wartsila.com www.neste.com" ;;
        FR) echo "www.michelin.com www.decathlon.fr www.orange.fr www.leroymerlin.fr www.dassault-aviation.com" ;;
        GB) echo "www.dyson.co.uk www.jaguar.com www.arm.com www.sage.com www.rolls-royce.com" ;;
        SE|NO|DK) echo "www.electrolux.com www.volvocars.com www.ikea.com www.equinor.com www.lego.com www.scania.com" ;;
        PL) echo "www.orlen.pl www.play.pl www.inpost.pl www.cdprojekt.com www.allegro.pl" ;;
        TR) echo "www.turkishairlines.com www.arcelik.com.tr www.vestel.com.tr www.beko.com www.ford.com.tr" ;;
        US|CA) echo "www.dell.com www.logitech.com www.nvidia.com www.akamai.com www.redhat.com" ;;
        RU) echo "www.mvideo.ru www.citilink.ru www.dns-shop.ru www.lamoda.ru www.sportmaster.ru" ;;
        *)  echo "www.philips.com www.bosch.de www.logitech.com www.asus.com www.ikea.com www.nokia.com" ;;
    esac
}

TIMEOUT=10
BATCH_FILE=""
OUT_CSV=""
AUTO_MODE=0
TARGETS=()

# Литерал вместо $0 намеренно — при запуске через "wget -qO- URL | bash"
# $0 указывает на "bash"/"-bash", а не на осмысленное имя команды.
usage() {
    echo "Использование:"
    echo "  sni-verify <домен>                    — подробный отчёт по одному домену"
    echo "  sni-verify -f candidates.txt          — пачка доменов (по одному на строку) -> таблица"
    echo "  sni-verify -f candidates.txt -out r.csv  — то же + сохранить в CSV"
    echo "  sni-verify -auto                      — сам определит IP/страну этой ноды и"
    echo "                                           возьмёт стартовый список кандидатов под неё"
    echo "  sni-verify -t 15 <домен>              — таймаут сети в секундах (по умолчанию 10)"
    echo ""
    echo "  Без аргументов (в т.ч. при 'wget -qO- ... | bash') — режим -auto по умолчанию."
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        -f) BATCH_FILE="$2"; shift 2 ;;
        -out) OUT_CSV="$2"; shift 2 ;;
        -t) TIMEOUT="$2"; shift 2 ;;
        -auto) AUTO_MODE=1; shift ;;
        -h|--help) usage ;;
        *) TARGETS+=("$1"); shift ;;
    esac
done

# Совсем без аргументов — в т.ч. типичный случай "wget -qO- URL | bash" без
# "-s -- ..." — ведём себя как sni-pick: сами уходим в -auto, а не требуем
# явный флаг. Явный "-f"/домен(ы) в аргументах уважаем как раньше.
if [ "$AUTO_MODE" = "0" ] && [ -z "$BATCH_FILE" ] && [ ${#TARGETS[@]} -eq 0 ]; then
    AUTO_MODE=1
fi

# Ширина рамки считается по видимому (ASCII) тексту, без ANSI-кодов, поэтому
# можно спокойно подставить своё имя репозитория — рамка не съедет.
BANNER_TXT="SNI / Reality Donor Check - gettfodaddy/sni-toolkit"
BANNER_W=$(( ${#BANNER_TXT} + 2 ))
printf "${BOLD}${CYAN}┌"; printf '%.0s─' $(seq 1 "$BANNER_W"); printf "┐${NC}\n"
printf "${BOLD}${CYAN}│${NC} ${BOLD}%s${NC} ${BOLD}${CYAN}│${NC}\n" "$BANNER_TXT"
printf "${BOLD}${CYAN}└"; printf '%.0s─' $(seq 1 "$BANNER_W"); printf "┘${NC}\n"

if [ -n "$BATCH_FILE" ]; then
    [ -f "$BATCH_FILE" ] || { echo -e "${RED}Файл не найден: $BATCH_FILE${NC}"; exit 1; }
    while IFS= read -r line; do
        line="$(echo "$line" | sed 's/#.*//' | xargs)"
        [ -n "$line" ] && TARGETS+=("$line")
    done < "$BATCH_FILE"
fi

SELF_IP=""; SELF_ASN=""
if [ "$AUTO_MODE" = "1" ]; then
    echo -e "${CYAN}Определяю IP и страну этой ноды...${NC}"
    SELF_IP=$(curl -s --max-time 6 https://api.ipify.org 2>/dev/null)
    SELF_CC=""
    if [ -n "$SELF_IP" ]; then
        # sed вместо jq намеренно — jq далеко не на всех минимальных VPS
        # стоит из коробки, а sed/curl есть всегда. Порядок полей у сервиса
        # свой, поэтому читаем по имени поля, не по позиции. Заодно берём
        # "as" (ASN+организация) — просто для информативного футера ниже,
        # на выбор доноров не влияет.
        GEO=$(curl -s --max-time 8 "http://ip-api.com/json/${SELF_IP}?fields=countryCode,country,as" 2>/dev/null)
        SELF_CC=$(echo "$GEO" | sed -n 's/.*"countryCode":"\([^"]*\)".*/\1/p')
        SELF_ASN=$(echo "$GEO" | sed -n 's/.*"as":"\([^"]*\)".*/\1/p')
    fi
    [ -z "$SELF_CC" ] && SELF_CC="DEFAULT"
    [ -n "$SELF_IP" ] && echo -e "  $INFO IP этой ноды: ${BOLD}${SELF_IP}${NC}, страна: ${BOLD}${SELF_CC}${NC}${SELF_ASN:+, ${SELF_ASN}}" \
        || echo -e "  $WARN Не удалось определить IP — беру список DEFAULT"

    CANDIDATES="$(country_candidates "$SELF_CC")"
    echo -e "  $INFO Кандидаты под страну ${BOLD}${SELF_CC}${NC}: ${CANDIDATES}"
    echo ""
    for d in $CANDIDATES; do TARGETS+=("$d"); done
fi

[ ${#TARGETS[@]} -eq 0 ] && usage

normalize_domain() {
    echo "$1" | sed 's|https\?://||' | sed 's|/.*||' | xargs
}

# Результат одной проверки складываем в эти переменные (глобально,
# перезаписываются на каждой итерации — используется и в одиночном,
# и в batch-режиме) — плюс копим строки для итоговой CSV/таблицы.
declare -a SUMMARY_ROWS=()

check_one() {
    local DOMAIN="$1"
    local VERBOSE="$2"   # 1 = полный цветной отчёт, 0 = только итог для таблицы

    local TLS13=0 H2=0 PQ=0 REDIRECT_BAD=0 HTTP_CODE="" CDN=""
    local IP="" CERT_ISSUER="" CERT_SAN_OK="?" CERT_BYTES=0
    local CONNECT_TIME="" APPCONNECT_TIME="" RESOLVE_TIME=""
    local RESOLVE_MS="" CONNECT_MS="" HANDSHAKE_MS=""
    local VERDICT="ПРОВЕРЬ"

    [ "$VERBOSE" = "1" ] && {
        echo ""
        echo -e "${BOLD}============================================================${NC}"
        echo -e "${BOLD}  SNI Donor Check: ${CYAN}${DOMAIN}${NC}"
        echo -e "${BOLD}============================================================${NC}"
        echo ""
    }

    # ── 1. TCP connect / DNS timing (ловит именно тот паттерн: DNS/ICMP ок,
    #        а TCP:443 зависает — см. недавний разбор ru-9) ─────────────
    local CURL_TIMING
    CURL_TIMING=$(curl -o /dev/null -s --max-time "$TIMEOUT" \
        -w "%{time_namelookup} %{time_connect} %{time_appconnect} %{http_code} %{remote_ip}" \
        "https://${DOMAIN}" 2>/dev/null)
    RESOLVE_TIME=$(echo "$CURL_TIMING" | awk '{print $1}')
    CONNECT_TIME=$(echo "$CURL_TIMING" | awk '{print $2}')
    APPCONNECT_TIME=$(echo "$CURL_TIMING" | awk '{print $3}')
    HTTP_CODE=$(echo "$CURL_TIMING" | awk '{print $4}')
    IP=$(echo "$CURL_TIMING" | awk '{print $5}')

    # ЗАДЕРЖКА: раньше сюда шло %{time_connect} (только TCP-рукопожатие,
    # БЕЗ TLS) и печаталось как есть, в секундах с 6 знаками после запятой
    # ("0.002550s") — именно из-за этого цифры выглядели неадекватно
    # маленькими и "техническими". time_appconnect включает ещё и TLS-
    # рукопожатие (это и есть реальное время "достучаться и поднять HTTPS"),
    # а показываем — целыми миллисекундами, как принято у похожих утилит.
    # appconnect может быть 0, если TLS не поднялся вовсе — тогда откатываемся
    # на голый TCP-connect, лишь бы не показывать пустоту.
    local TCP_MS
    RESOLVE_MS=$(awk -v t="${RESOLVE_TIME:-0}" 'BEGIN{printf "%d", t*1000}')
    TCP_MS=$(awk -v c="${CONNECT_TIME:-0}" 'BEGIN{printf "%d", c*1000}')
    HANDSHAKE_MS=$(awk -v c="${CONNECT_TIME:-0}" -v a="${APPCONNECT_TIME:-0}" \
        'BEGIN{ t = (a+0>0) ? a : c; printf "%d", t*1000 }')
    CONNECT_MS="$HANDSHAKE_MS"

    [ "$VERBOSE" = "1" ] && {
        echo -e "${BOLD}[1/9] DNS + TCP:443 connect${NC}"
        if [ -n "$IP" ] && [ "$IP" != "0.0.0.0" ]; then
            echo -e "  $OK IP: ${BOLD}${IP}${NC} (DNS: ${RESOLVE_MS}ms, TCP: ${TCP_MS}ms, TCP+TLS: ${BOLD}${HANDSHAKE_MS}ms${NC})"
        else
            echo -e "  $FAIL DNS не резолвится, или TCP:443 не отвечает за ${TIMEOUT}с"
            echo -e "       Если ping/mtr до IP проходят нормально, а тут зависает — это НЕ проблема"
            echo -e "       маршрута, а точечная блокировка/фильтрация именно порта 443 к этому хосту"
            echo -e "       (см. п.8 traceroute ниже для сравнения)."
        fi
        echo ""
    }
    if [ -z "$IP" ] || [ "$IP" = "0.0.0.0" ]; then
        VERDICT="НЕ ГОДИТСЯ"
        SUMMARY_ROWS+=("$DOMAIN|-|0|0|no|-|-|$VERDICT (DNS/TCP)")
        [ "$VERBOSE" = "1" ] && echo -e "  ${RED}${BOLD}Дальше проверять нет смысла — хост недоступен.${NC}"
        return
    fi

    # ── 2. TLS 1.3 ────────────────────────────────────────────────────
    local TLS_CHECK
    TLS_CHECK=$(curl -vI --max-time "$TIMEOUT" "https://${DOMAIN}" 2>&1 | grep -i "TLSv1.3")
    [ -n "$TLS_CHECK" ] && TLS13=1
    [ "$VERBOSE" = "1" ] && {
        echo -e "${BOLD}[2/9] TLS 1.3${NC}"
        if [ "$TLS13" = "1" ]; then echo -e "  $OK TLS 1.3 поддерживается"
        else echo -e "  $FAIL TLS 1.3 не обнаружен — донор не подходит для Reality (обязательное условие)"; fi
        echo ""
    }

    # ── 3. HTTP/2 (ALPN h2) ──────────────────────────────────────────
    local H2_CHECK
    H2_CHECK=$(curl -vI --http2 --max-time "$TIMEOUT" "https://${DOMAIN}" 2>&1 | grep -i "HTTP/2")
    [ -n "$H2_CHECK" ] && H2=1
    [ "$VERBOSE" = "1" ] && {
        echo -e "${BOLD}[3/9] HTTP/2 (ALPN h2)${NC}"
        if [ "$H2" = "1" ]; then echo -e "  $OK HTTP/2 поддерживается"
        else echo -e "  $FAIL HTTP/2 не обнаружен — Reality требует ALPN h2 (обязательное условие)"; fi
        echo ""
    }

    # ── 4. Post-quantum (X25519MLKEM768) — ИНФОРМАЦИОННО, не провал ──
    local PQ_CHECK
    PQ_CHECK=$(echo | timeout "$TIMEOUT" openssl s_client -connect "${DOMAIN}:443" -tls1_3 2>&1 | grep -i "mlkem\|kyber\|X25519MLKEM")
    [ -n "$PQ_CHECK" ] && PQ=1
    [ "$VERBOSE" = "1" ] && {
        echo -e "${BOLD}[4/9] Post-quantum key exchange (X25519MLKEM768)${NC}"
        if [ "$PQ" = "1" ]; then
            echo -e "  $INFO Донор поддерживает post-quantum key exchange"
            echo -e "       Это НЕ провал сам по себе — смотри контекст:"
            echo -e "       • Xray-core < 26.9.8 (клиент): REALITY-клиент сам подхватит PQ от донора."
            echo -e "         Со СТАРЫМИ клиентскими библиотеками (устаревший uTLS/fingerprint,"
            echo -e "         не умеющий PQ) хендшейк может не собраться."
            echo -e "       • Xray-core >= 26.9.8 (сервер): сервер САМ уже требует PQ key share"
            echo -e "         (X25519MLKEM768) в ClientHello независимо от донора — так что тут это"
            echo -e "         не блокер, а факт. Но твои клиенты (sing-box/mihomo/Hiddify-based) должны"
            echo -e "         быть на версиях с обновлённым uTLS Chrome-профилем, иначе они сами не"
            echo -e "         соберут нужный ClientHello и получат silent fallback / verification failed —"
            echo -e "         это уже вопрос версий КЛИЕНТСКИХ приложений, не донора."
        else
            echo -e "  $INFO Post-quantum не обнаружен у донора — донор безопасен для старых клиентов"
            echo -e "       и не задаёт лишних требований поверх того, что уже требует твой Xray-core."
        fi
        echo ""
    }

    # ── 5. Сертификат: issuer, размер, SAN ───────────────────────────
    local CERT_RAW SAN_LIST
    CERT_RAW=$(echo | timeout "$TIMEOUT" openssl s_client -connect "${DOMAIN}:443" -servername "${DOMAIN}" -tls1_3 -showcerts 2>/dev/null)
    CERT_ISSUER=$(echo "$CERT_RAW" | openssl x509 -noout -issuer 2>/dev/null | sed 's/issuer=//')
    SAN_LIST=$(echo "$CERT_RAW" | openssl x509 -noout -ext subjectAltName 2>/dev/null)
    CERT_BYTES=$(echo "$CERT_RAW" | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' | wc -c)
    if echo "$SAN_LIST" | grep -qi "$DOMAIN"; then CERT_SAN_OK="OK"; else CERT_SAN_OK="?"; fi
    [ "$VERBOSE" = "1" ] && {
        echo -e "${BOLD}[5/9] Сертификат${NC}"
        [ -n "$CERT_ISSUER" ] && echo -e "  $INFO Issuer: ${CERT_ISSUER}" || echo -e "  $WARN Не удалось получить сертификат"
        echo -e "  $INFO Размер сертификата (PEM): ~${CERT_BYTES} байт"
        if [ "$CERT_BYTES" -lt 3500 ]; then
            echo -e "       Меньше 3500 байт — не критично сам по себе, но если планируешь включать"
            echo -e "       mldsa65 (post-quantum ПОДПИСЬ сертификата REALITY, отдельная от X25519MLKEM768"
            echo -e "       key exchange выше) — документация Reality явно требует донора с сертификатом"
            echo -e "       ${BOLD}>3500 байт${NC}, иначе temporary-сертификат не влезет."
        fi
        [ "$CERT_SAN_OK" = "OK" ] && echo -e "  $OK Домен присутствует в SAN сертификата" \
            || echo -e "  $WARN Домен не найден в SAN — сверь serverNames в конфиге именно с SAN, а не с доменом"
        echo ""
    }

    # ── 6. CDN-фронтинг (Cloudflare/Akamai/Fastly/CloudFront) ────────
    local HEADERS
    HEADERS=$(curl -sI --max-time "$TIMEOUT" "https://${DOMAIN}" 2>/dev/null)
    if echo "$HEADERS" | grep -qi "cf-ray\|server: cloudflare"; then CDN="Cloudflare"
    elif echo "$HEADERS" | grep -qi "x-amz-cf-id"; then CDN="CloudFront"
    elif echo "$HEADERS" | grep -qi "akamai"; then CDN="Akamai"
    elif echo "$HEADERS" | grep -qi "server: fastly\|x-served-by: cache"; then CDN="Fastly"
    fi
    [ "$VERBOSE" = "1" ] && {
        echo -e "${BOLD}[6/9] CDN-фронтинг${NC}"
        if [ -n "$CDN" ]; then
            echo -e "  $WARN Похоже на $CDN (anycast CDN)"
            echo -e "       Сообществом REALITY обычно не рекомендуется — общий anycast IP means сотни"
            echo -e "       чужих сайтов на том же адресе (выше риск попасть под чужую anti-abuse блокировку"
            echo -e "       CDN), да и сам факт 'дефолтной' страницы CDN за IP слабее маскирует Reality-фолбек."
            echo -e "       Не фатально, но при прочих равных выбирай origin-хостинг без CDN."
        else
            echo -e "  $OK CDN-фронтинг явно не обнаружен (headers чистые)"
        fi
        echo ""
    }

    # ── 7. HTTP-статус / редиректы ────────────────────────────────────
    # Редирект НЕ обязательно плохой — важно, остаётся ли он на том же
    # домене (bare->www, /старая-страница -> /новая — это нормальная жизнь
    # сайта и не проблема) или уводит на ЧУЖОЙ домен (вот это уже плохо:
    # случайный посетитель SNI-домена попадёт не на правдоподобный "сайт",
    # а куда-то ещё — легенда рассыпается).
    [ "$VERBOSE" = "1" ] && echo -e "${BOLD}[7/9] HTTP-статус${NC}"
    case "$HTTP_CODE" in
        200) [ "$VERBOSE" = "1" ] && echo -e "  $OK HTTP 200 — редиректов нет" ;;
        301|302|303|307|308)
            local REDIRECT_URL REDIRECT_HOST BARE_DOMAIN
            REDIRECT_URL=$(curl -o /dev/null -s -w "%{redirect_url}" --max-time "$TIMEOUT" "https://${DOMAIN}")
            REDIRECT_HOST=$(echo "$REDIRECT_URL" | sed -E 's#^[a-zA-Z]+://([^/]+).*#\1#')
            BARE_DOMAIN="${DOMAIN#www.}"
            if [ -z "$REDIRECT_HOST" ] || [ "${REDIRECT_HOST#www.}" = "$BARE_DOMAIN" ]; then
                [ "$VERBOSE" = "1" ] && echo -e "  $OK HTTP ${HTTP_CODE} — редирект внутри того же домена (${REDIRECT_URL:-без Location}), это нормально"
            else
                REDIRECT_BAD=1
                [ "$VERBOSE" = "1" ] && {
                    echo -e "  $FAIL HTTP ${HTTP_CODE} — редирект на ЧУЖОЙ домен: ${REDIRECT_URL}"
                    echo -e "       Легенда рассыпается: зашедший на этот SNI попадёт не на правдоподобный"
                    echo -e "       сайт этого домена, а куда-то ещё. Попробуй ${REDIRECT_HOST} как донора вместо этого."
                }
            fi
            ;;
        401|403)
            [ "$VERBOSE" = "1" ] && echo -e "  $WARN HTTP ${HTTP_CODE} — сервер отвечает, требует авторизацию. Handshake для Reality обычно ок, но не 'красивая' страница для случайного зашедшего."
            ;;
        *)
            [ "$VERBOSE" = "1" ] && echo -e "  $WARN HTTP ${HTTP_CODE:-нет ответа} — нестандартный ответ, проверь вручную"
            ;;
    esac
    [ "$VERBOSE" = "1" ] && echo ""

    # ── 8. Маршрут именно с ЭТОГО хоста (главное — сюда донор реально подбирается) ─
    [ "$VERBOSE" = "1" ] && {
        echo -e "${BOLD}[8/9] Маршрут с этого сервера${NC}"
        echo -e "  $INFO IP донора: ${BOLD}${IP}${NC}"
        if command -v mtr &> /dev/null; then
            echo -e "  $INFO mtr (10 пакетов, сводка):"
            mtr -n -r -c 10 --timeout 2 "$IP" 2>/dev/null | tail -n +2 | while read -r line; do
                echo -e "       ${line}"
            done
        elif command -v traceroute &> /dev/null; then
            echo -e "  $INFO traceroute (первые 8 хопов):"
            traceroute -n -m 8 -w 2 "$IP" 2>/dev/null | tail -n +2 | while read -r line; do
                echo -e "       ${line}"
            done
        else
            echo -e "  $WARN Ни mtr, ни traceroute не установлены. apt install mtr-tiny traceroute"
        fi
        echo ""
    }

    # ── 9. Best-effort ASN/гео (не критично, если сервис недоступен) ─
    # sed вместо jq — см. комментарий у -auto выше, тот же резон.
    if [ "$VERBOSE" = "1" ]; then
        echo -e "${BOLD}[9/9] ASN / гео (best-effort)${NC}"
        local ASN_INFO ORG CTRY
        ASN_INFO=$(curl -s --max-time 4 "http://ip-api.com/json/${IP}?fields=isp,as,countryCode" 2>/dev/null)
        ORG=$(echo "$ASN_INFO" | sed -n 's/.*"as":"\([^"]*\)".*/\1/p')
        CTRY=$(echo "$ASN_INFO" | sed -n 's/.*"countryCode":"\([^"]*\)".*/\1/p')
        if [ -n "$ORG" ] || [ -n "$CTRY" ]; then
            echo -e "  $INFO ASN: ${ORG:-?}, страна: ${CTRY:-?}"
        else
            echo -e "  $INFO (сервис геолокации недоступен с этого сервера — пропущено, не критично)"
        fi
        echo ""
    fi

    # ── Вердикт ────────────────────────────────────────────────────
    if [ "$TLS13" = "1" ] && [ "$H2" = "1" ] && [ "$REDIRECT_BAD" = "0" ]; then
        VERDICT="ГОТОВ"
    elif [ "$TLS13" = "1" ] && [ "$H2" = "1" ]; then
        VERDICT="ПРОВЕРЬ"
    else
        VERDICT="НЕ ГОДИТСЯ"
    fi

    # ASCII-only значения для табличных колонок ниже — в фиксированной ширине
    # (%-Ns) printf считает БАЙТЫ, а не отображаемые символы, и кириллица
    # (2 байта/символ) там уезжает и ломает выравнивание таблицы. Развёрнутый
    # цветной отчёт (VERBOSE=1) выше по-русски без ограничений — там колонок нет.
    local PQ_LABEL="no"; [ "$PQ" = "1" ] && PQ_LABEL="yes"
    local CDN_LABEL="${CDN:--}"

    if [ "$VERBOSE" = "1" ]; then
        echo -e "${BOLD}============================================================${NC}"
        case "$VERDICT" in
            "ГОТОВ") echo -e "  ${GREEN}${BOLD}✓ ГОТОВ${NC} — TLS1.3 + H2 + без редиректов, можно использовать как SNI" ;;
            "ПРОВЕРЬ") echo -e "  ${YELLOW}${BOLD}~ ПРОВЕРЬ${NC} — базовые условия есть, но глянь предупреждения выше" ;;
            *) echo -e "  ${RED}${BOLD}✗ НЕ ГОДИТСЯ${NC} — не хватает TLS1.3 и/или H2, либо хост недоступен" ;;
        esac
        echo -e "${BOLD}============================================================${NC}"
        echo ""
    fi

    SUMMARY_ROWS+=("$DOMAIN|$IP|$TLS13|$H2|$PQ_LABEL|$CDN_LABEL|${CONNECT_MS}|$VERDICT")
}

# Рисует/перерисовывает строку прогресса поверх самой себя (\r, без \n) —
# вызывается перед каждым доменом в батче, создаёт "живой" прогресс-бар.
render_progress() {
    local cur="$1" total="$2" label="$3"
    local width=24
    local filled=$(( total > 0 ? cur * width / total : width ))
    [ "$filled" -gt "$width" ] && filled=$width
    local empty=$(( width - filled ))
    local bar="" i
    for ((i = 0; i < filled; i++)); do bar+="█"; done
    for ((i = 0; i < empty; i++)); do bar+="░"; done
    local pct=$(( total > 0 ? cur * 100 / total : 100 ))
    printf "\r  ${CYAN}Сканирую${NC} [%s] %3d%%  (%d/%d)  %-32s" "$bar" "$pct" "$cur" "$total" "$label"
}

if [ -n "$BATCH_FILE" ] || [ "$AUTO_MODE" = "1" ]; then
    TOTAL=${#TARGETS[@]}
    IDX=0
    SCAN_START=$SECONDS
    for t in "${TARGETS[@]}"; do
        d=$(normalize_domain "$t")
        [ -z "$d" ] && continue
        IDX=$((IDX + 1))
        render_progress "$IDX" "$TOTAL" "$d"
        check_one "$d" "0"
    done
    printf "\r%-90s\r" " "   # стереть строку прогресса перед таблицей
    echo ""

    # Заголовок и yes/no-колонки ниже намеренно на латинице — printf с %-Ns
    # считает ширину в байтах, и кириллица (2 байта/символ) в padded-колонках
    # уезжает и ломает выравнивание таблицы. Только ВЕРДИКТ (последняя,
    # непадженная колонка) остаётся по-русски. CONNECT — целые миллисекунды
    # TCP+TLS-рукопожатия (не секунды с 6 знаками, как раньше).
    printf "%-32s %-16s %-6s %-4s %-4s %-12s %-9s %s\n" "DOMAIN" "IP" "TLS1.3" "H2" "PQ" "CDN" "CONNECT" "VERDICT"
    printf '%.0s-' {1..102}; echo ""
    READY_N=0; CHECK_N=0; BAD_N=0
    for row in "${SUMMARY_ROWS[@]}"; do
        IFS='|' read -r d ip tls13 h2 pq cdn ct verdict <<< "$row"
        tls_s="no"; [ "$tls13" = "1" ] && tls_s="yes"
        h2_s="no"; [ "$h2" = "1" ] && h2_s="yes"
        ct_disp="-"; [ -n "$ct" ] && [ "$ct" != "-" ] && ct_disp="${ct}ms"
        case "$verdict" in
            ГОТОВ*) vc="${GREEN}${verdict}${NC}"; READY_N=$((READY_N + 1)) ;;
            ПРОВЕРЬ*) vc="${YELLOW}${verdict}${NC}"; CHECK_N=$((CHECK_N + 1)) ;;
            *) vc="${RED}${verdict}${NC}"; BAD_N=$((BAD_N + 1)) ;;
        esac
        printf "%-32s %-16s %-6s %-4s %-4s %-12s %-9s " "$d" "$ip" "$tls_s" "$h2_s" "$pq" "$cdn" "$ct_disp"
        echo -e "$vc"
    done
    if [ -n "$OUT_CSV" ]; then
        {
            echo "domain,ip,tls13,h2,post_quantum,cdn,connect_ms,verdict"
            for row in "${SUMMARY_ROWS[@]}"; do
                echo "$row" | tr '|' ','
            done
        } > "$OUT_CSV"
        echo ""
        echo -e "${INFO} Сохранено в ${BOLD}${OUT_CSV}${NC}"
    fi

    # Итоговая строка счётчиков (ГОТОВ/ПРОВЕРЬ/НЕ ГОДИТСЯ) + время скана —
    # тот же смысл, что и "OK:N BLOCKED:N PARTIAL:N Total:N" у похожих
    # утилит, но термины свои: это проверка донора под Reality, а не
    # проверка блокировок у РФ-провайдеров (для этого отдельный инструмент).
    SCAN_ELAPSED=$((SECONDS - SCAN_START))
    echo ""
    echo -e "  ${GREEN}ГОТОВ:${READY_N}${NC}  ${YELLOW}ПРОВЕРЬ:${CHECK_N}${NC}  ${RED}НЕ ГОДИТСЯ:${BAD_N}${NC}  Всего:${#SUMMARY_ROWS[@]}"
    [ -n "$SELF_IP" ] && echo -e "  ${INFO} Нода: ${SELF_IP}${SELF_ASN:+, ${SELF_ASN}}"
    echo -e "  Проверка заняла ${SCAN_ELAPSED}с."

    # Быстрая подсказка — лучший по задержке среди ГОТОВ (без mtr/сертификата/
    # CDN, это уже было учтено самим вердиктом). Финалиста всё равно стоит
    # прогнать отдельно (./sni-verify.sh <домен>) для полного отчёта.
    BEST_ROW=""
    BEST_CT="999999"
    for row in "${SUMMARY_ROWS[@]}"; do
        IFS='|' read -r d ip tls13 h2 pq cdn ct verdict <<< "$row"
        [ "$verdict" != "ГОТОВ" ] && continue
        is_better=$(awk -v a="$ct" -v b="$BEST_CT" 'BEGIN{print (a<b)?1:0}' 2>/dev/null)
        if [ "$is_better" = "1" ]; then BEST_CT="$ct"; BEST_ROW="$row"; fi
    done
    echo ""
    if [ -n "$BEST_ROW" ]; then
        IFS='|' read -r bd bip _ _ _ _ bct _ <<< "$BEST_ROW"
        echo -e "${GREEN}${BOLD}Лучший по задержке среди ГОТОВ:${NC} ${bd} (${bct}ms, IP ${bip})"
        echo "  \"dest\": \"${bd}:443\","
        echo "  \"serverNames\": [ \"${bd}\" ]"
        echo -e "${INFO} Перед вставкой в конфиг прогони полный отчёт: sni-verify ${bd}"
    else
        echo -e "${WARN} Ни один кандидат не дотянул до ГОТОВ — расширь список (-f/-auto другой список) или смотри ПРОВЕРЬ вручную."
    fi
else
    DOMAIN=$(normalize_domain "${TARGETS[0]}")
    check_one "$DOMAIN" "1"
fi
