#ifndef ICMPPing_h
#define ICMPPing_h

/// Пинг IPv4-адреса через непривилегированный ICMP-сокет
/// (socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)) — работает на iOS/macOS без root
/// и без спец-entitlement (так устроен официальный пример Apple SimplePing).
/// Возвращает RTT в миллисекундах или -1 при таймауте/ошибке.
double wl_icmp_ping(const char *ipv4, int timeout_ms);

#endif /* ICMPPing_h */
