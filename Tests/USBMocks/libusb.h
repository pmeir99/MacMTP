#ifndef MACMTP_TEST_LIBUSB_H
#define MACMTP_TEST_LIBUSB_H
#include <stdint.h>
#include <sys/types.h>
typedef struct { int unused; } libusb_context;
typedef struct { int index; } libusb_device;
typedef struct { int index; } libusb_device_handle;
struct libusb_endpoint_descriptor { uint8_t bEndpointAddress, bmAttributes; uint16_t wMaxPacketSize; };
struct libusb_interface_descriptor {
    uint8_t bNumEndpoints, bInterfaceClass, bInterfaceSubClass, iInterface, bInterfaceNumber, bAlternateSetting;
    const struct libusb_endpoint_descriptor *endpoint;
    uint8_t bInterfaceProtocol;
};
struct libusb_interface { const struct libusb_interface_descriptor *altsetting; int num_altsetting; };
struct libusb_config_descriptor { uint8_t bNumInterfaces; const struct libusb_interface *interface; };
struct libusb_device_descriptor { uint16_t idVendor, idProduct; };
enum { LIBUSB_TRANSFER_TYPE_BULK = 2, LIBUSB_ENDPOINT_IN = 0x80, LIBUSB_CLASS_IMAGE = 6,
       LIBUSB_CLASS_VENDOR_SPEC = 255, LIBUSB_ERROR_NO_MEM = -11, LIBUSB_ERROR_NO_DEVICE = -4,
       LIBUSB_ERROR_ACCESS = -3, LIBUSB_ERROR_INVALID_PARAM = -2 };
int libusb_init(libusb_context **);
ssize_t libusb_get_device_list(libusb_context *, libusb_device ***);
int libusb_get_active_config_descriptor(libusb_device *, struct libusb_config_descriptor **);
int libusb_get_device_descriptor(libusb_device *, struct libusb_device_descriptor *);
uint8_t libusb_get_bus_number(libusb_device *);
uint8_t libusb_get_device_address(libusb_device *);
int libusb_reset_device(libusb_device_handle *);
int libusb_open(libusb_device *, libusb_device_handle **);
int libusb_get_string_descriptor_ascii(libusb_device_handle *, uint8_t, unsigned char *, int);
int libusb_claim_interface(libusb_device_handle *, int);
int libusb_kernel_driver_active(libusb_device_handle *, int);
int libusb_set_interface_alt_setting(libusb_device_handle *, int, int);
int libusb_release_interface(libusb_device_handle *, int);
void libusb_close(libusb_device_handle *);
void libusb_free_config_descriptor(struct libusb_config_descriptor *);
void libusb_free_device_list(libusb_device **, int);
void libusb_exit(libusb_context *);
int libusb_bulk_transfer(libusb_device_handle *, unsigned char, unsigned char *, int, int *, unsigned int);
#endif
