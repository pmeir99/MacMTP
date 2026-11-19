#include <stdint.h>

typedef struct MacUSB MacUSB;
// error receives the libusb failure when no MTP interface can be opened.
MacUSB *mac_usb_open(int *error);
// Stops an existing local ADB server using the ADB host protocol.
// Returns 1 on success, 0 when absent, and -1 when it could not be stopped.
int mac_adb_stop_server(void);
// Explicit-port variant also allows protocol verification against an isolated server.
int mac_adb_stop_server_on_port(uint16_t port);
void mac_usb_close(MacUSB *connection);
int mac_usb_read(MacUSB *connection, uint8_t *bytes, int capacity);
int mac_usb_write(MacUSB *connection, const uint8_t *bytes, int count);
int mac_usb_packet_size(MacUSB *connection);
