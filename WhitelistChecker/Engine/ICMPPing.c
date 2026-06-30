#include "ICMPPing.h"

#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <netinet/ip_icmp.h>
#include <arpa/inet.h>

/// Контрольная сумма ICMP: 16-битное дополнение до единицы.
static uint16_t wl_cksum(const void *data, int len) {
    const uint16_t *p = (const uint16_t *)data;
    uint32_t sum = 0;
    while (len > 1) { sum += *p++; len -= 2; }
    if (len == 1) sum += *(const uint8_t *)p;
    sum = (sum >> 16) + (sum & 0xFFFF);
    sum += (sum >> 16);
    return (uint16_t)~sum;
}

double wl_icmp_ping(const char *ipv4, int timeout_ms) {
    int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP);
    if (fd < 0) return -1.0;

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    if (inet_pton(AF_INET, ipv4, &addr.sin_addr) != 1) { close(fd); return -1.0; }

    struct timeval tv;
    tv.tv_sec = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    // ICMP echo request: type(8) code(0) cksum(2) id(2) seq(2) — заголовок 8 байт.
    uint8_t pkt[8];
    memset(pkt, 0, sizeof(pkt));
    pkt[0] = ICMP_ECHO;
    uint16_t ident = (uint16_t)(getpid() & 0xFFFF);
    pkt[4] = (uint8_t)(ident >> 8);
    pkt[5] = (uint8_t)(ident & 0xFF);
    pkt[7] = 1;  // seq = 1
    uint16_t ck = wl_cksum(pkt, sizeof(pkt));
    pkt[2] = (uint8_t)(ck & 0xFF);
    pkt[3] = (uint8_t)(ck >> 8);

    struct timeval t0, t1;
    gettimeofday(&t0, NULL);
    if (sendto(fd, pkt, sizeof(pkt), 0, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd); return -1.0;
    }

    uint8_t buf[256];
    ssize_t n = recv(fd, buf, sizeof(buf), 0);  // ждём ответ до SO_RCVTIMEO
    close(fd);
    if (n <= 0) return -1.0;  // таймаут или ошибка → нет ответа

    gettimeofday(&t1, NULL);
    return (t1.tv_sec - t0.tv_sec) * 1000.0 + (t1.tv_usec - t0.tv_usec) / 1000.0;
}
