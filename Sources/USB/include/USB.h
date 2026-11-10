#include <stdint.h>

typedef struct MacUSB MacUSB;
MacUSB *mac_usb_open(void);
void mac_usb_close(MacUSB *connection);
int mac_usb_read(MacUSB *connection, uint8_t *bytes, int capacity);
int mac_usb_write(MacUSB *connection, const uint8_t *bytes, int count);
int mac_usb_packet_size(MacUSB *connection);
