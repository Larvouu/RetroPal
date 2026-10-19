#define WINVER 0x501
#include <winsock2.h>
#include <windows.h>
#include "net.h"

uint8_t get_host_address(iface_info *out)
{
	out->ip[0] = 127;
	out->ip[1] = 0;
	out->ip[2] = 0;
	out->ip[3] = 1;
	out->net_mask[0] = 255;
	out->net_mask[0] = 255;
	out->net_mask[0] = 255;
	out->net_mask[0] = 0;
	return 1;
}

static WSADATA wsa_data;
static void socket_cleanup(void)
{
	WSACleanup();
}

void socket_init(void)
{
	static uint8_t started;
	if (!started) {
		started = 1;
		WSAStartup(MAKEWORD(2,2), &wsa_data);
		atexit(socket_cleanup);
	}
}

int socket_blocking(int sock, int should_block)
{
	u_long param = !should_block;
	if (ioctlsocket(sock, FIONBIO, &param)) {
		return WSAGetLastError();
	}
	return 0;
}

void socket_close(int sock)
{
	closesocket(sock);
}

int socket_last_error(void)
{
	return WSAGetLastError();
}

int socket_error_is_wouldblock(void)
{
	return WSAGetLastError() == WSAEWOULDBLOCK;
}
