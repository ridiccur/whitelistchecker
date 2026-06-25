#ifndef DNSSystem_h
#define DNSSystem_h

/// Записывает текущие системные DNS-серверы (как "ip1,ip2") в out.
/// Возвращает количество найденных серверов.
int wl_system_dns_servers(char *out, int outLen);

#endif /* DNSSystem_h */
