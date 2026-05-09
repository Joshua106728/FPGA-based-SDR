idf_component_register(SRCS "main.c"
                    INCLUDE_DIRS "."
                    REQUIRES usb esp_ringbuf esp_driver_i2s)