#include "USB.h"
#include <libusb.h>
#include <stdlib.h>
#include <string.h>

struct MacUSB {
    libusb_context *context;
    libusb_device_handle *handle;
    uint8_t input, output, interface;
    int packet_size;
};

static int claim(MacUSB *connection, libusb_device *device,
                 const struct libusb_interface_descriptor *interface) {
    uint8_t input = 0, output = 0;
    int packet_size = 0;
    for (int index = 0; index < interface->bNumEndpoints; index++) {
        const struct libusb_endpoint_descriptor *endpoint = &interface->endpoint[index];
        if ((endpoint->bmAttributes & 3) != LIBUSB_TRANSFER_TYPE_BULK) continue;
        if (endpoint->bEndpointAddress & LIBUSB_ENDPOINT_IN) {
            input = endpoint->bEndpointAddress;
        } else {
            output = endpoint->bEndpointAddress;
            packet_size = endpoint->wMaxPacketSize & 0x7ff;
        }
    }
    if (!input || !output || !packet_size) return 0;
    libusb_device_handle *handle = NULL;
    if (libusb_open(device, &handle) != 0) return 0;
    int still_image = interface->bInterfaceClass == LIBUSB_CLASS_IMAGE &&
                      interface->bInterfaceSubClass == 1;
    unsigned char name[64] = {0};
    int length = interface->iInterface
        ? libusb_get_string_descriptor_ascii(handle, interface->iInterface, name, sizeof(name))
        : 0;
    if ((!still_image && (length < 3 || strncasecmp((char *)name, "MTP", 3))) ||
        libusb_claim_interface(handle, interface->bInterfaceNumber) != 0) {
        libusb_close(handle);
        return 0;
    }
    if (interface->bAlternateSetting &&
        libusb_set_interface_alt_setting(handle, interface->bInterfaceNumber,
                                         interface->bAlternateSetting) != 0) {
        libusb_release_interface(handle, interface->bInterfaceNumber);
        libusb_close(handle);
        return 0;
    }
    connection->handle = handle;
    connection->interface = interface->bInterfaceNumber;
    connection->input = input;
    connection->output = output;
    connection->packet_size = packet_size;
    return 1;
}

MacUSB *mac_usb_open(void) {
    MacUSB *connection = calloc(1, sizeof(*connection));
    if (!connection) return NULL;
    if (libusb_init(&connection->context) != 0) {
        free(connection);
        return NULL;
    }
    libusb_device **devices = NULL;
    ssize_t count = libusb_get_device_list(connection->context, &devices);
    for (ssize_t i = 0; i < count && !connection->handle; i++) {
        struct libusb_config_descriptor *config = NULL;
        if (libusb_get_active_config_descriptor(devices[i], &config) != 0) continue;
        for (int j = 0; j < config->bNumInterfaces && !connection->handle; j++) {
            const struct libusb_interface *interface = &config->interface[j];
            for (int k = 0; k < interface->num_altsetting && !connection->handle; k++) {
                const struct libusb_interface_descriptor *alternate = &interface->altsetting[k];
                if (alternate->bInterfaceClass == LIBUSB_CLASS_IMAGE ||
                    alternate->bInterfaceClass == LIBUSB_CLASS_VENDOR_SPEC)
                    claim(connection, devices[i], alternate);
            }
        }
        libusb_free_config_descriptor(config);
    }
    if (devices) libusb_free_device_list(devices, 1);
    if (connection->handle) return connection;
    mac_usb_close(connection);
    return NULL;
}

void mac_usb_close(MacUSB *connection) {
    if (!connection) return;
    if (connection->handle) {
        libusb_release_interface(connection->handle, connection->interface);
        libusb_close(connection->handle);
    }
    libusb_exit(connection->context);
    free(connection);
}

int mac_usb_read(MacUSB *connection, uint8_t *bytes, int capacity) {
    int actual = 0;
    int status = libusb_bulk_transfer(connection->handle, connection->input, bytes,
                                      capacity, &actual, 10000);
    return status ? status : actual;
}

int mac_usb_write(MacUSB *connection, const uint8_t *bytes, int count) {
    int actual = 0;
    int status = libusb_bulk_transfer(connection->handle, connection->output,
                                      (uint8_t *)bytes, count, &actual, 10000);
    return status ? status : actual;
}

int mac_usb_packet_size(MacUSB *connection) { return connection->packet_size; }
