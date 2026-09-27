#!/bin/bash
# ============================================================
# sni-scan.sh — обёртка над официальным XTLS/RealiTLScanner для массового
# поиска кандидатов в SNI-доноры (TLS1.3 + ALPN h2) по списку IP/CIDR/URL.
#
# ВАЖНО (из README самого RealiTLScanner): "It is recommended to run this
# tool locally, as running the scanner in the cloud may cause the VPS to
# be flagged." Массовое сканирование тысяч хостов с одного IP — заметный
# паттерн трафика. Не запускай это с боевой Reality-ноды — только с
# отдельной локальной машины / одноразовой VM. На саму ноду переносится
# уже ГОТОВЫЙ короткий список кандидатов (для точечной проверки sni-verify.sh).
#
# Собирается из исходников по официальной инструкции проекта — никаких
# сторонних precompiled-бинарников с непроверяемых доменов (в отличие от
# curl-pipe-to-bin скриптов вида sni-pick.sh — см. README.md этого тулкита).
#
# Использование:
#   ./sni-scan.sh build                       — склонировать + собрать бинарник
#   ./sni-scan.sh -addr 1.2.3.0/24 -thread 20  — скан диапазона
#   ./sni-scan.sh -in candidates_ips.txt       — скан списка IP/доменов из файла
#   ./sni-scan.sh -url https://launchpad.net/ubuntu/+archivemirrors
#                                              — скан по ссылкам со страницы-каталога
#   (любые доп. флаги передаются напрямую в RealiTLScanner — см. -h)
# ============================================================
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

REPO_URL="https://github.com/XTLS/RealiTLScanner.git"
WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.realitlscanner"
BIN="${WORKDIR}/RealiTLScanner"

banner() {
    echo -e "${YELLOW}${BOLD}============================================================${NC}"
    echo -e "${YELLOW}${BOLD}  Массовое сканирование — не с боевой Reality-ноды!${NC}"
    echo -e "${YELLOW}  Запускай локально или с одноразовой VM, не привязанной к твоей${NC}"
    echo -e "${YELLOW}  VPN-инфраструктуре. На ноду переносится только итоговый короткий${NC}"
    echo -e "${YELLOW}  список кандидатов — дальше его точечно проверяет sni-verify.sh${NC}"
    echo -e "${YELLOW}  ${BOLD}с самой ноды${NC}${YELLOW} (там важна задержка/маршрут именно оттуда).${NC}"
    echo -e "${YELLOW}${BOLD}============================================================${NC}"
    echo ""
}

build() {
    if ! command -v go &> /dev/null; then
        echo -e "${RED}Go не найден.${NC} Установи Go 1.21+ (https://go.dev/dl/) и повтори."
        echo "Либо используй Docker-вариант — см. README.md этого тулкита."
        exit 1
    fi
    if [ ! -d "$WORKDIR" ]; then
        echo -e "${CYAN}Клонирую XTLS/RealiTLScanner...${NC}"
        git clone --depth 1 "$REPO_URL" "$WORKDIR"
    else
        echo -e "${CYAN}Уже склонировано, обновляю...${NC}"
        (cd "$WORKDIR" && git pull --ff-only) || true
    fi
    echo -e "${CYAN}Собираю бинарник (go build)...${NC}"
    # GOTOOLCHAIN=local — не даём go самому лезть качать более новый Go
    # с proxy.golang.org, если go.mod просит версию новее установленной:
    # на машине с ограниченным egress (типичная минимальная VPS/VM) это
    # падает с 403 по прокси-политике вместо внятной ошибки "обнови Go".
    if ! (cd "$WORKDIR" && GOTOOLCHAIN=local go build -o RealiTLScanner .); then
        echo ""
        echo -e "${RED}Сборка не удалась.${NC} Часто причина — версия Go старее той, что просит"
        echo "go.mod проекта, а автозагрузка нужного тулчейна недоступна (нет сети до"
        echo "proxy.golang.org). Обнови Go: https://go.dev/dl/ — и повтори '$0 build'."
        exit 1
    fi
    echo -e "${GREEN}Готово:${NC} ${BIN}"
}

if [ "${1:-}" = "build" ]; then
    banner
    build
    exit 0
fi

if [ ! -x "$BIN" ]; then
    echo -e "${YELLOW}Бинарник не найден — собираю сам (первый запуск)...${NC}"
    banner
    build
fi

banner
echo -e "${CYAN}Запускаю: ${BIN} $*${NC}"
echo ""
exec "$BIN" "$@"
