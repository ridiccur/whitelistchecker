#include "DNSSystem.h"
#include <resolv.h>
#include <arpa/inet.h>
#include <string.h>
#include <netinet/in.h>

int wl_system_dns_servers(char *out, int outLen) {
    if (out == NULL || outLen <= 0) return 0;
    out[0] = '\0';

    struct __res_state res;
    memset(&res, 0, sizeof(res));
    if (res_ninit(&res) != 0) return 0;

    union res_sockaddr_union servers[8];
    int n = res_getservers(&res, servers, 8);
    int written = 0;

    for (int i = 0; i < n; i++) {
        char ip[INET6_ADDRSTRLEN];
        ip[0] = '\0';
        if (servers[i].sin.sin_family == AF_INET) {
            inet_ntop(AF_INET, &servers[i].sin.sin_addr, ip, sizeof(ip));
        } else if (servers[i].sin6.sin6_family == AF_INET6) {
            inet_ntop(AF_INET6, &servers[i].sin6.sin6_addr, ip, sizeof(ip));
        } else {
            continue;
        }
        if (ip[0] == '\0') continue;
        if (written > 0) strlcat(out, ",", outLen);
        strlcat(out, ip, outLen);
        written++;
    }

    res_ndestroy(&res);
    return written;
}
