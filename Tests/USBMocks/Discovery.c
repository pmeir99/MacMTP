#include "libusb.h"
#include "USB.h"
#include <assert.h>
#include <string.h>

static libusb_context context;
static libusb_device devices[] = {{0}, {1}};
static libusb_device *list[] = {&devices[0], &devices[1], NULL};
static libusb_device_handle handles[] = {{0}, {1}};
static struct libusb_endpoint_descriptor endpoints[] = {{0x81, 2, 512}, {0x02, 2, 512}};
static struct libusb_interface_descriptor descriptors[] = {{2, 6, 1, 1, 3, 0, endpoints, 0}, {2, 6, 1, 1, 4, 0, endpoints, 0}};
static struct libusb_interface interfaces[] = {{&descriptors[0], 1}, {&descriptors[1], 1}};
static struct libusb_config_descriptor configs[] = {{1, &interfaces[0]}, {1, &interfaces[1]}};
static int count, opens[2], claims[2], active[2], configured, closed, exited, open_calls, string_calls;
static void reset(void) {
    count = 1; configured = closed = exited = open_calls = string_calls = 0;
    memset(opens, 0, sizeof opens); memset(claims, 0, sizeof claims); memset(active, 0, sizeof active);
    descriptors[0].bAlternateSetting = 0;
    descriptors[0].bInterfaceClass = 6; descriptors[0].bInterfaceSubClass = 1; descriptors[0].bInterfaceProtocol = 0;
}
int libusb_init(libusb_context **out) { *out = &context; return 0; }
ssize_t libusb_get_device_list(libusb_context *c, libusb_device ***out) { (void)c; *out = list; return count; }
int libusb_get_active_config_descriptor(libusb_device *d, struct libusb_config_descriptor **out) { *out = &configs[d->index]; return 0; }
int libusb_get_device_descriptor(libusb_device *d, struct libusb_device_descriptor *out) { out->idVendor = 0x18d1; out->idProduct = (uint16_t)(0x4ee1 + d->index); return 0; }
int libusb_open(libusb_device *d, libusb_device_handle **out) { open_calls++; *out = opens[d->index] ? NULL : &handles[d->index]; return opens[d->index]; }
int libusb_get_string_descriptor_ascii(libusb_device_handle *h, uint8_t i, unsigned char *out, int capacity) { (void)h; (void)i; string_calls++; assert(capacity >= 4); memcpy(out, "MTP", 4); return 3; }
int libusb_claim_interface(libusb_device_handle *h, int i) { (void)i; return claims[h->index]; }
int libusb_kernel_driver_active(libusb_device_handle *h, int i) { (void)i; return active[h->index]; }
int libusb_set_interface_alt_setting(libusb_device_handle *h, int i, int alternate) { (void)h; (void)i; (void)alternate; return configured; }
int libusb_release_interface(libusb_device_handle *h, int i) { (void)h; (void)i; return 0; }
void libusb_close(libusb_device_handle *h) { (void)h; closed++; }
void libusb_free_config_descriptor(struct libusb_config_descriptor *c) { (void)c; }
void libusb_free_device_list(libusb_device **d, int unref) { (void)d; (void)unref; }
void libusb_exit(libusb_context *c) { (void)c; exited++; }
int libusb_bulk_transfer(libusb_device_handle *h, unsigned char endpoint, unsigned char *bytes, int length, int *actual, unsigned int timeout) { (void)h; (void)endpoint; (void)bytes; (void)timeout; *actual = length; return 0; }

int main(void) {
    int error = 0;
    MacUSBDiagnostics diagnostic;
    reset(); opens[0] = -3;
    assert(!mac_usb_open_with_diagnostics(&error, &diagnostic));
    assert(error == -3 && diagnostic.stage == MAC_USB_STAGE_OPEN && diagnostic.kernel_driver_active == -1);
    assert(diagnostic.vendor == 0x18d1 && diagnostic.product == 0x4ee1 && diagnostic.interface_number == 3);
    assert(exited == 1 && closed == 0);

    reset(); claims[0] = -3; active[0] = 1;
    assert(!mac_usb_open_with_diagnostics(&error, &diagnostic));
    assert(error == -3 && diagnostic.stage == MAC_USB_STAGE_CLAIM && diagnostic.kernel_driver_active == 1);
    assert(closed == 1 && exited == 1);

    reset(); count = 2; claims[0] = -6; opens[1] = -3;
    assert(!mac_usb_open_with_diagnostics(&error, &diagnostic));
    assert(error == -6 && diagnostic.stage == MAC_USB_STAGE_CLAIM && diagnostic.interface_number == 3);

    reset(); descriptors[0].bAlternateSetting = 1; configured = -3;
    assert(!mac_usb_open_with_diagnostics(&error, &diagnostic));
    assert(error == -3 && diagnostic.stage == MAC_USB_STAGE_CONFIGURE && closed == 1);

    reset();
    MacUSB *usb = mac_usb_open_with_diagnostics(&error, &diagnostic);
    assert(usb && error == 0 && mac_usb_packet_size(usb) == 512);
    mac_usb_close(usb);
    assert(closed == 1 && exited == 1 && string_calls == 0);

    reset(); descriptors[0].bInterfaceClass = 255; descriptors[0].bInterfaceSubClass = 0x42; descriptors[0].bInterfaceProtocol = 1;
    assert(!mac_usb_open_with_diagnostics(&error, &diagnostic));
    assert(error == -4 && open_calls == 0);

    reset(); descriptors[0].bInterfaceClass = 255; descriptors[0].bInterfaceSubClass = 255;
    usb = mac_usb_open_with_diagnostics(&error, &diagnostic);
    assert(usb && error == 0 && string_calls == 1);
    mac_usb_close(usb);
    return 0;
}
