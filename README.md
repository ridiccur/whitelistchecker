# WhitelistChecker (iOS)

Диагностика мобильной сети в режиме «белых списков»: для каждого адреса определяет,
**заблокирован** он, **зашейплен** или идёт на **полной скорости** (в белом списке).

## Что делает

Ввод — **IP, CIDR-подсеть или домен** (по одному в строке). Для каждой цели:

| Проба | Сигнал | API |
|---|---|---|
| **TCP-handshake** к :443 | block: `OPEN` / `RST` / `DROP` | `NWConnection` (tcp) |
| **throughput** (КБ/с) | shape: быстро / медленно | `NWConnection` (tls) + ручной HTTP GET |

Вердикт по цели:

- 🟢 **WHITE** — полная скорость (в белом списке)
- 🟡 **SHAPED** — соединение есть, но полоса задушена
- ⛔ **BLOCKED** — TCP не устанавливается (RST/таймаут)
- ⚪ **INCONCLUSIVE** — мало данных (мелкий объект на хосте) или DNS

Плюс **агрегатный «режим сети»** по набору целей: блокировка по белым спискам vs шейп.

### По типам ввода
- **IP / домен** — полный цикл: TCP + throughput.
- **CIDR** — только TCP-карта по всем адресам подсети (throughput для подсетей не меряется).
  Авторазворот до `/24`; крупнее — запрос подтверждения.

## Канал
Селектор **Сотовый / Wi-Fi / Авто** форсирует интерфейс через
`NWParameters.requiredInterfaceType`. Для проверки именно мобильных ограничений
выбирай «Сотовый» (работает даже при активном Wi-Fi).

## Сборка (без подписи)

```bash
./build-ipa.sh
# → dist/WhitelistChecker-unsigned.ipa
```

Требуется Xcode 16+ (проект использует synchronized folder groups, objectVersion 77).
На выходе — **голый unsigned .ipa**. Подпись — отдельно: Sideloadly / Feather / Gbox
своим сертификатом разработчика.

## ⚠️ Тестировать только на устройстве
Симулятор ходит через сеть Mac и **шейп/блокировку не увидит**. Ставить на реальный
телефон в мобильной сети.

## Ограничения
- Throughput для произвольного IP/домена бывает `INCONCLUSIVE`, если на хосте нет
  крупного объекта по `/`.
- raw ICMP/SYN на iOS недоступны без спец-entitlement — block-детект делается через
  состояния `NWConnection`, чего достаточно для классов OPEN/RST/DROP.

## Структура
```
WhitelistChecker/
├─ Engine/
│  ├─ InputParser.swift   — разбор IP/CIDR/домена, разворот подсети
│  ├─ Types.swift         — Channel, TCPResult, Verdict, ProbeResult, NetworkMode
│  ├─ TCPProbe.swift      — block-сигнал (NWConnection tcp)
│  ├─ ThroughputProbe.swift — shape-сигнал (NWConnection tls + HTTP GET)
│  ├─ Calibration.swift   — встроенные эталоны, порог
│  └─ ScanEngine.swift    — оркестратор, классификация, режим сети
├─ UI/
│  ├─ ContentView.swift   — ввод, канал, баннер режима, список
│  └─ RowView.swift       — строка результата
└─ WhitelistCheckerApp.swift
```
