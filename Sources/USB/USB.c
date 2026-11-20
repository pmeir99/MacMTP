#include "USB.h"
#include <libusb.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

struct MacUSB {
    libusb_context *context;
    libusb_device_handle *handle;
    uint8_t input, output, interface;
    int packet_size;
    int last_error;
    MacUSBDiagnostics diagnostic;
    MacUSBDiagnostics recovery_target;
    int recovery_enabled;
    int stop_scan;
};

static int matches_target(libusb_device *device, const MacUSBDiagnostics *target) {
    struct libusb_device_descriptor descriptor = {0};
    if (libusb_get_device_descriptor(device, &descriptor) != 0) return 0;
    return descriptor.idVendor == target->vendor && descriptor.idProduct == target->product &&
           libusb_get_bus_number(device) == target->bus_number &&
           libusb_get_device_address(device) == target->device_address;
}

static void record_failure(MacUSB *connection, libusb_device *device,
                           const struct libusb_interface_descriptor *interface,
                           int status, int stage, int driver_active) {
    // Prefer a confirmed MTP interface failure over a later discovery/open failure.
    if (connection->diagnostic.stage > stage) return;
    struct libusb_device_descriptor descriptor = {0};
    (void)libusb_get_device_descriptor(device, &descriptor);
    connection->last_error = status;
    connection->diagnostic.stage = stage;
    connection->diagnostic.kernel_driver_active = driver_active;
    connection->diagnostic.vendor = descriptor.idVendor;
    connection->diagnostic.product = descriptor.idProduct;
    connection->diagnostic.interface_number = interface->bInterfaceNumber;
    connection->diagnostic.bus_number = libusb_get_bus_number(device);
    connection->diagnostic.device_address = libusb_get_device_address(device);
}

static int claim(MacUSB *connection, libusb_device *device,
                 const struct libusb_interface_descriptor *interface) {
    if (connection->recovery_enabled &&
        interface->bInterfaceNumber != connection->recovery_target.interface_number) return 0;
    // Android's ADB interface is not MTP; do not open it while discovering storage.
    if (interface->bInterfaceClass == LIBUSB_CLASS_VENDOR_SPEC &&
        interface->bInterfaceSubClass == 0x42 && interface->bInterfaceProtocol == 1) return 0;
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
    int still_image = interface->bInterfaceClass == LIBUSB_CLASS_IMAGE &&
                      interface->bInterfaceSubClass == 1;
    int status = libusb_open(device, &handle);
    if (status != 0) {
        if (still_image) record_failure(connection, device, interface, status, MAC_USB_STAGE_OPEN, -1);
        return 0;
    }
    if (!still_image) {
        unsigned char name[64] = {0};
        int length = interface->iInterface
            ? libusb_get_string_descriptor_ascii(handle, interface->iInterface, name, sizeof(name))
            : 0;
        if (length < 3 || strncasecmp((char *)name, "MTP", 3)) {
            libusb_close(handle);
            return 0;
        }
    }
    status = libusb_claim_interface(handle, interface->bInterfaceNumber);
    int driver_active = status != 0
        ? libusb_kernel_driver_active(handle, interface->bInterfaceNumber) : 0;
    // No resets during discovery or ordinary retries. A user-initiated recovery
    // gets at most two attempts, on the previously diagnosed phone only.
    if (connection->recovery_enabled && status == LIBUSB_ERROR_ACCESS && driver_active == 1) {
        while (connection->diagnostic.reset_attempts < 2 && status == LIBUSB_ERROR_ACCESS && driver_active == 1) {
            connection->diagnostic.reset_attempts++;
            int reset_status = libusb_reset_device(handle);
            connection->diagnostic.reset_status = reset_status;
            if (reset_status != 0) {
                record_failure(connection, device, interface, reset_status, MAC_USB_STAGE_RESET, -1);
                connection->stop_scan = 1;
                libusb_close(handle); // The handle can be invalid after re-enumeration.
                return 0;
            }
            // Claim immediately after reset; pausing gives the system driver a chance to reclaim it.
            status = libusb_claim_interface(handle, interface->bInterfaceNumber);
            driver_active = status != 0 ? libusb_kernel_driver_active(handle, interface->bInterfaceNumber) : 0;
        }
    }
    if (status != 0) {
        record_failure(connection, device, interface, status, MAC_USB_STAGE_CLAIM, driver_active);
        libusb_close(handle);
        return 0;
    }
    if (interface->bAlternateSetting) {
        status = libusb_set_interface_alt_setting(handle, interface->bInterfaceNumber,
                                                  interface->bAlternateSetting);
    }
    if (status != 0) {
        record_failure(connection, device, interface, status, MAC_USB_STAGE_CONFIGURE, -1);
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

MacUSB *mac_usb_open(int *error) {
    return mac_usb_open_with_diagnostics(error, NULL);
}

static MacUSB *open_device(int *error, MacUSBDiagnostics *diagnostics, const MacUSBDiagnostics *target) {
    if (diagnostics) {
        memset(diagnostics, 0, sizeof(*diagnostics));
        diagnostics->kernel_driver_active = -1;
    }
    if (!error) return NULL;
    *error = LIBUSB_ERROR_NO_MEM;
    MacUSB *connection = calloc(1, sizeof(*connection));
    if (!connection) return NULL;
    int status = libusb_init(&connection->context);
    if (status != 0) {
        *error = status;
        free(connection);
        return NULL;
    }
    if (target) {
        connection->recovery_enabled = 1;
        connection->recovery_target = *target;
    }
    connection->last_error = LIBUSB_ERROR_NO_DEVICE;
    connection->diagnostic.kernel_driver_active = -1;
    libusb_device **devices = NULL;
    ssize_t count = libusb_get_device_list(connection->context, &devices);
    if (count < 0) connection->last_error = (int)count;
    for (ssize_t i = 0; i < count && !connection->handle && !connection->stop_scan; i++) {
        if (target && !matches_target(devices[i], target)) continue;
        struct libusb_config_descriptor *config = NULL;
        if (libusb_get_active_config_descriptor(devices[i], &config) != 0) continue;
        for (int j = 0; j < config->bNumInterfaces && !connection->handle && !connection->stop_scan; j++) {
            const struct libusb_interface *interface = &config->interface[j];
            for (int k = 0; k < interface->num_altsetting && !connection->handle && !connection->stop_scan; k++) {
                const struct libusb_interface_descriptor *alternate = &interface->altsetting[k];
                if (alternate->bInterfaceClass == LIBUSB_CLASS_IMAGE ||
                    alternate->bInterfaceClass == LIBUSB_CLASS_VENDOR_SPEC)
                    claim(connection, devices[i], alternate);
            }
        }
        libusb_free_config_descriptor(config);
    }
    if (devices) libusb_free_device_list(devices, 1);
    if (connection->handle) {
        *error = 0;
        if (diagnostics) *diagnostics = connection->diagnostic;
        return connection;
    }
    *error = connection->last_error;
    if (diagnostics) *diagnostics = connection->diagnostic;
    mac_usb_close(connection);
    return NULL;
}

MacUSB *mac_usb_open_with_diagnostics(int *error, MacUSBDiagnostics *diagnostics) {
    return open_device(error, diagnostics, NULL);
}

MacUSB *mac_usb_open_recovering(int *error, MacUSBDiagnostics *diagnostics, const MacUSBDiagnostics *target) {
    if (!error) return NULL;
    if (!target || target->stage != MAC_USB_STAGE_CLAIM || target->kernel_driver_active != 1 ||
        target->device_address == 0 || target->vendor == 0) {
        *error = LIBUSB_ERROR_INVALID_PARAM;
        return NULL;
    }
    MacUSBDiagnostics saved = *target;
    return open_device(error, diagnostics, &saved);
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
