/*
 * Minimal RTL2832 USB IQ -> ESP32 I2S (8-bit stereo) for FPGA rf_cdc.
 * FPGA expects 220500 IQ pairs/s: 882 ksps USB / 4 naive decimation (see sv/types.sv).
 */
#include <string.h>

#include "esp_err.h"
#include "esp_log.h"
#include "driver/i2s_std.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "usb/usb_host.h"

static const char *TAG = "sdr";

#define SDR_BULK_BUFFER_SIZE (16 * 512)
#define NUM_BULK_TRANSFERS 12

/** USB IQ rate programmed into RTL2832 before decimation */
#define SDR_USB_IQ_RATE_HZ 882000u

#define DECIMATION_FACTOR 4
#define IQ_RATE_TO_FPGA (SDR_USB_IQ_RATE_HZ / DECIMATION_FACTOR)

_Static_assert(IQ_RATE_TO_FPGA == 220500,
               "IQ_RATE_TO_FPGA must be 220500 for FPGA decim DECIM_FACTOR=5 -> 44.1 kHz audio");

static i2s_chan_handle_t tx_handle;

#define I2S_WS_GPIO 4
#define I2S_BCK_GPIO 5
#define I2S_DOUT_GPIO 6

static void init_i2s(void)
{
    i2s_chan_config_t chan_cfg = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_AUTO, I2S_ROLE_MASTER);
    /* Deeper DMA smooths USB jitter vs steady I2S drain (same average rate, bursty bulk). */
    chan_cfg.dma_desc_num = 24;
    chan_cfg.dma_frame_num = 1024;
    ESP_ERROR_CHECK(i2s_new_channel(&chan_cfg, &tx_handle, NULL));

    i2s_std_config_t std_cfg = {
        .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(IQ_RATE_TO_FPGA),
        .slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_8BIT, I2S_SLOT_MODE_STEREO),
        .gpio_cfg =
            {
                .mclk = I2S_GPIO_UNUSED,
                .bclk = I2S_BCK_GPIO,
                .ws = I2S_WS_GPIO,
                .dout = I2S_DOUT_GPIO,
                .din = I2S_GPIO_UNUSED,
            },
    };
    std_cfg.clk_cfg.clk_src = I2S_CLK_SRC_APLL;
    std_cfg.clk_cfg.mclk_multiple = I2S_MCLK_MULTIPLE_128;
    ESP_ERROR_CHECK(i2s_channel_init_std_mode(tx_handle, &std_cfg));
    ESP_ERROR_CHECK(i2s_channel_enable(tx_handle));

    ESP_LOGI(TAG, "I2S 8-bit stereo @ %u Hz (IQ pairs/s)", (unsigned)IQ_RATE_TO_FPGA);
}

static usb_host_client_handle_t client_hdl;
static QueueHandle_t sdr_queue;
static QueueHandle_t bucket_queue;
static SemaphoreHandle_t transfer_sem;

static uint8_t r82xx_shadow_regs[27] = {
    0x83, 0x32, 0x75, 0xC0, 0x40, 0xE4, 0x6C, 0xF5, 0x63, 0x75, 0x68, 0x6C, 0x83, 0x80, 0x00,
    0x0F, 0x00, 0xC0, 0x30, 0x48, 0xCC, 0x60, 0x00, 0x54, 0xAE, 0x4A, 0xC0};

static void transfer_cb(usb_transfer_t *t) { xSemaphoreGive(transfer_sem); }

static esp_err_t rtlsdr_read_reg(usb_device_handle_t dev_hdl, uint8_t block, uint16_t addr, uint8_t *data,
                                 uint16_t len)
{
    usb_transfer_t *transfer;
    esp_err_t err = usb_host_transfer_alloc(8 + len, 0, &transfer);
    if (err != ESP_OK)
        return err;

    usb_setup_packet_t *setup = (usb_setup_packet_t *)transfer->data_buffer;
    setup->bmRequestType = 0xC0;
    setup->bRequest = 0;
    setup->wValue = addr;
    setup->wIndex = (uint16_t)(block << 8);
    setup->wLength = len;

    transfer->device_handle = dev_hdl;
    transfer->bEndpointAddress = 0x00;
    transfer->callback = transfer_cb;
    transfer->num_bytes = 8 + len;

    err = usb_host_transfer_submit_control(client_hdl, transfer);
    if (err == ESP_OK) {
        xSemaphoreTake(transfer_sem, pdMS_TO_TICKS(1000));
        err = transfer->status == USB_TRANSFER_STATUS_COMPLETED ? ESP_OK : ESP_FAIL;
        if (err == ESP_OK)
            memcpy(data, transfer->data_buffer + 8, len);
    }
    usb_host_transfer_free(transfer);
    return err;
}

static esp_err_t rtlsdr_write_reg(usb_device_handle_t dev_hdl, uint8_t block, uint16_t addr, uint8_t val)
{
    usb_transfer_t *transfer;
    esp_err_t err = usb_host_transfer_alloc(8 + 1, 0, &transfer);
    if (err != ESP_OK)
        return err;

    usb_setup_packet_t *setup = (usb_setup_packet_t *)transfer->data_buffer;
    setup->bmRequestType = 0x40;
    setup->bRequest = 0;
    setup->wValue = addr;
    setup->wIndex = (uint16_t)((block << 8) | 0x10);
    setup->wLength = 1;
    transfer->data_buffer[8] = val;
    transfer->device_handle = dev_hdl;
    transfer->callback = transfer_cb;
    transfer->num_bytes = 8 + 1;

    err = usb_host_transfer_submit_control(client_hdl, transfer);
    if (err == ESP_OK) {
        xSemaphoreTake(transfer_sem, pdMS_TO_TICKS(1000));
        err = transfer->status == USB_TRANSFER_STATUS_COMPLETED ? ESP_OK : ESP_FAIL;
    }
    usb_host_transfer_free(transfer);
    return err;
}

static esp_err_t rtlsdr_write_reg_16(usb_device_handle_t dev_hdl, uint8_t block, uint16_t addr, uint16_t val)
{
    usb_transfer_t *transfer;
    esp_err_t err = usb_host_transfer_alloc(8 + 2, 0, &transfer);
    if (err != ESP_OK)
        return err;

    usb_setup_packet_t *setup = (usb_setup_packet_t *)transfer->data_buffer;
    setup->bmRequestType = 0x40;
    setup->bRequest = 0;
    setup->wValue = addr;
    setup->wIndex = (uint16_t)((block << 8) | 0x10);
    setup->wLength = 2;
    transfer->data_buffer[8] = (uint8_t)(val >> 8);
    transfer->data_buffer[9] = (uint8_t)(val & 0xFF);
    transfer->device_handle = dev_hdl;
    transfer->callback = transfer_cb;
    transfer->num_bytes = 8 + 2;

    err = usb_host_transfer_submit_control(client_hdl, transfer);
    if (err == ESP_OK) {
        xSemaphoreTake(transfer_sem, pdMS_TO_TICKS(1000));
        err = transfer->status == USB_TRANSFER_STATUS_COMPLETED ? ESP_OK : ESP_FAIL;
    }
    usb_host_transfer_free(transfer);
    return err;
}

static esp_err_t rtlsdr_demod_write_reg(usb_device_handle_t dev_hdl, uint8_t page, uint16_t addr, uint8_t val)
{
    usb_transfer_t *transfer;
    esp_err_t err = usb_host_transfer_alloc(8 + 1, 0, &transfer);
    if (err != ESP_OK)
        return err;

    usb_setup_packet_t *setup = (usb_setup_packet_t *)transfer->data_buffer;
    setup->bmRequestType = 0x40;
    setup->bRequest = 0;
    setup->wValue = (uint16_t)((addr << 8) | 0x20);
    setup->wIndex = (uint16_t)(0x10 | page);
    setup->wLength = 1;
    transfer->data_buffer[8] = val;
    transfer->device_handle = dev_hdl;
    transfer->callback = transfer_cb;
    transfer->num_bytes = 8 + 1;

    err = usb_host_transfer_submit_control(client_hdl, transfer);
    if (err == ESP_OK) {
        xSemaphoreTake(transfer_sem, pdMS_TO_TICKS(1000));
        err = transfer->status == USB_TRANSFER_STATUS_COMPLETED ? ESP_OK : ESP_FAIL;
    }
    usb_host_transfer_free(transfer);
    return err;
}

static esp_err_t rtlsdr_demod_write_reg_16(usb_device_handle_t dev_hdl, uint8_t page, uint16_t addr, uint16_t val)
{
    usb_transfer_t *transfer;
    esp_err_t err = usb_host_transfer_alloc(8 + 2, 0, &transfer);
    if (err != ESP_OK)
        return err;

    usb_setup_packet_t *setup = (usb_setup_packet_t *)transfer->data_buffer;
    setup->bmRequestType = 0x40;
    setup->bRequest = 0;
    setup->wValue = (uint16_t)((addr << 8) | 0x20);
    setup->wIndex = (uint16_t)(0x10 | page);
    setup->wLength = 2;
    transfer->data_buffer[8] = (uint8_t)(val >> 8);
    transfer->data_buffer[9] = (uint8_t)(val & 0xFF);
    transfer->device_handle = dev_hdl;
    transfer->callback = transfer_cb;
    transfer->num_bytes = 8 + 2;

    err = usb_host_transfer_submit_control(client_hdl, transfer);
    if (err == ESP_OK) {
        xSemaphoreTake(transfer_sem, pdMS_TO_TICKS(1000));
        err = transfer->status == USB_TRANSFER_STATUS_COMPLETED ? ESP_OK : ESP_FAIL;
    }
    usb_host_transfer_free(transfer);
    return err;
}

static esp_err_t rtlsdr_i2c_read(usb_device_handle_t dev_hdl, uint8_t i2c_addr, uint8_t reg, uint8_t *val)
{
    uint16_t addr = (uint16_t)(i2c_addr | (reg << 8));
    return rtlsdr_read_reg(dev_hdl, 6, addr, val, 1);
}

static esp_err_t rtlsdr_i2c_write(usb_device_handle_t dev_hdl, uint8_t i2c_addr, uint8_t reg, uint8_t val)
{
    uint16_t addr = (uint16_t)(i2c_addr | (reg << 8));
    return rtlsdr_write_reg(dev_hdl, 6, addr, val);
}

static esp_err_t i2c_repeater(usb_device_handle_t dev_hdl, bool on)
{
    return rtlsdr_demod_write_reg(dev_hdl, 1, 0x01, on ? 0x18 : 0x10);
}

static uint32_t rtl_rsamp_ratio(uint32_t rate_hz)
{
    return ((uint32_t)((28800000ULL << 22) / rate_hz)) & 0x0FFFFFFCu;
}

static esp_err_t rtl_set_sample_rate(usb_device_handle_t dev_hdl, uint32_t samp_rate_hz)
{
    uint32_t r = rtl_rsamp_ratio(samp_rate_hz);
    esp_err_t err = rtlsdr_demod_write_reg_16(dev_hdl, 1, 0x9f, (uint16_t)(r >> 16));
    if (err == ESP_OK)
        err = rtlsdr_demod_write_reg_16(dev_hdl, 1, 0xa1, (uint16_t)(r & 0xFFFF));
    return err;
}

static esp_err_t claim_if0(usb_device_handle_t dev_hdl)
{
    return usb_host_interface_claim(client_hdl, dev_hdl, 0, 0);
}

static esp_err_t init_baseband(usb_device_handle_t dev_hdl)
{
    esp_err_t err = rtlsdr_write_reg_16(dev_hdl, 1, 0x2158, 0x0002);
    if (err != ESP_OK)
        return err;

    rtlsdr_write_reg(dev_hdl, 2, 0x300B, 0x22);
    rtlsdr_write_reg(dev_hdl, 2, 0x3000, 0xE8);

    rtlsdr_demod_write_reg(dev_hdl, 1, 0x01, 0x14);
    rtlsdr_demod_write_reg(dev_hdl, 1, 0x01, 0x10);

    rtlsdr_demod_write_reg(dev_hdl, 0, 0x19, 0x05);
    rtlsdr_demod_write_reg(dev_hdl, 0, 0x06, 0x80);
    rtlsdr_demod_write_reg(dev_hdl, 1, 0xB1, 0x1B);
    rtlsdr_demod_write_reg(dev_hdl, 0, 0x61, 0x60);
    rtlsdr_demod_write_reg(dev_hdl, 1, 0x04, 0x00);
    rtlsdr_demod_write_reg(dev_hdl, 1, 0x11, 0x00);
    return ESP_OK;
}

static esp_err_t init_tuner_regs(usb_device_handle_t dev_hdl)
{
    esp_err_t err = i2c_repeater(dev_hdl, true);
    if (err != ESP_OK)
        return err;

    for (int i = 0; i < 27; i++) {
        uint8_t reg = (uint8_t)(0x05 + i);
        err = rtlsdr_i2c_write(dev_hdl, 0x34, reg, r82xx_shadow_regs[i]);
        if (err != ESP_OK)
            break;
    }
    i2c_repeater(dev_hdl, false);
    return err;
}

static esp_err_t tuner_auto_gain(usb_device_handle_t dev_hdl)
{
    esp_err_t err = i2c_repeater(dev_hdl, true);
    if (err != ESP_OK)
        goto done;

    uint8_t reg05 = (uint8_t)(r82xx_shadow_regs[0] & ~(uint8_t)0x10);
    rtlsdr_i2c_write(dev_hdl, 0x34, 0x05, reg05);
    r82xx_shadow_regs[0] = reg05;

    uint8_t reg07 = (uint8_t)(r82xx_shadow_regs[2] | (uint8_t)0x10);
    rtlsdr_i2c_write(dev_hdl, 0x34, 0x07, reg07);
    r82xx_shadow_regs[2] = reg07;

    uint8_t reg0c = (uint8_t)((r82xx_shadow_regs[7] & ~(uint8_t)0x9F) | 0x0B);
    rtlsdr_i2c_write(dev_hdl, 0x34, 0x0C, reg0c);
    r82xx_shadow_regs[7] = reg0c;

done:
    i2c_repeater(dev_hdl, false);
    return err;
}

/** R820T2 ~105.3 MHz (mock PLL words from prior project baseline). */
static esp_err_t tune_fm_band(usb_device_handle_t dev_hdl)
{
    esp_err_t err = i2c_repeater(dev_hdl, true);
    if (err != ESP_OK)
        return err;

    rtlsdr_i2c_write(dev_hdl, 0x34, 0x1A, 0x76);
    rtlsdr_i2c_write(dev_hdl, 0x34, 0x1B, 0x4C);
    rtlsdr_i2c_write(dev_hdl, 0x34, 0x1C, 0xCD);
    rtlsdr_i2c_write(dev_hdl, 0x34, 0x1A, 0x76); /* cal */
    i2c_repeater(dev_hdl, false);
    vTaskDelay(pdMS_TO_TICKS(40));
    return ESP_OK;
}

/** RTL2832 digital mixer (22-bit); value matches FPGA IF plan (~50 kHz offset @ 882 kHz). */
static esp_err_t set_ddc_nco(usb_device_handle_t dev_hdl)
{
    esp_err_t err = rtlsdr_demod_write_reg(dev_hdl, 1, 0x19, 0x37);
    if (err != ESP_OK)
        return err;
    err = rtlsdr_demod_write_reg(dev_hdl, 1, 0x1A, 0x48);
    if (err != ESP_OK)
        return err;
    return rtlsdr_demod_write_reg(dev_hdl, 1, 0x1B, 0x13);
}

static void bulk_cb(usb_transfer_t *transfer)
{
    if (transfer->status != USB_TRANSFER_STATUS_COMPLETED) {
        usb_host_transfer_submit(transfer);
        return;
    }
    if (xQueueSend(bucket_queue, &transfer, 0) != pdTRUE)
        usb_host_transfer_submit(transfer);
}

static esp_err_t start_bulk(usb_device_handle_t dev_hdl)
{
    rtlsdr_write_reg_16(dev_hdl, 1, 0x2148, 0x1002);
    rtlsdr_write_reg_16(dev_hdl, 1, 0x2148, 0x0000);

    for (int i = 0; i < NUM_BULK_TRANSFERS; i++) {
        usb_transfer_t *transfer;
        esp_err_t err = usb_host_transfer_alloc(SDR_BULK_BUFFER_SIZE, 0, &transfer);
        if (err != ESP_OK)
            return err;

        transfer->device_handle = dev_hdl;
        transfer->bEndpointAddress = 0x81;
        transfer->callback = bulk_cb;
        transfer->num_bytes = SDR_BULK_BUFFER_SIZE;

        err = usb_host_transfer_submit(transfer);
        if (err != ESP_OK)
            return err;
    }
    return ESP_OK;
}

static uint8_t decim_dma[SDR_BULK_BUFFER_SIZE / DECIMATION_FACTOR];

static void dsp_task(void *arg)
{
    (void)arg;
    ESP_LOGI(TAG, "streaming (every %u-th IQ pair)", (unsigned)DECIMATION_FACTOR);

    for (;;) {
        usb_transfer_t *transfer;
        if (xQueueReceive(bucket_queue, &transfer, portMAX_DELAY) != pdTRUE)
            continue;

        const uint8_t *raw = transfer->data_buffer;
        int nbytes = transfer->actual_num_bytes;
        int npairs_trim = ((nbytes / 2) / DECIMATION_FACTOR) * DECIMATION_FACTOR;

        int out_idx = 0;
        for (int pair = 0; pair < npairs_trim; pair += DECIMATION_FACTOR) {
            int idx = pair * 2;
            decim_dma[out_idx++] = raw[idx];
            decim_dma[out_idx++] = raw[idx + 1];
        }

        if (out_idx > 0) {
            size_t written = 0;
            i2s_channel_write(tx_handle, decim_dma, (size_t)out_idx, &written, portMAX_DELAY);
            (void)written;
        }

        usb_host_transfer_submit(transfer);
        taskYIELD();
    }
}

static void usb_lib_task(void *arg)
{
    (void)arg;
    for (;;) {
        uint32_t flags = 0;
        usb_host_lib_handle_events(portMAX_DELAY, &flags);
        if (flags & USB_HOST_LIB_EVENT_FLAGS_NO_CLIENTS)
            ESP_ERROR_CHECK(usb_host_device_free_all());
        if (flags & USB_HOST_LIB_EVENT_FLAGS_ALL_FREE)
            break;
    }
    vTaskDelete(NULL);
}

static void on_client_event(const usb_host_client_event_msg_t *msg, void *arg)
{
    (void)arg;

    if (msg->event == USB_HOST_CLIENT_EVENT_NEW_DEV) {
        usb_device_handle_t dev_hdl;
        if (usb_host_device_open(client_hdl, msg->new_dev.address, &dev_hdl) != ESP_OK)
            return;
        const usb_device_desc_t *desc;
        if (usb_host_get_device_descriptor(dev_hdl, &desc) == ESP_OK)
            ESP_LOGI(TAG, "RTL-SDR USB %04x:%04x", desc->idVendor, desc->idProduct);

        xQueueSend(sdr_queue, &dev_hdl, portMAX_DELAY);
    } else if (msg->event == USB_HOST_CLIENT_EVENT_DEV_GONE) {
        usb_host_device_close(client_hdl, msg->dev_gone.dev_hdl);
    }
}

static void sdr_boot_task(void *arg)
{
    (void)arg;

    for (;;) {
        usb_device_handle_t dev_hdl;
        if (xQueueReceive(sdr_queue, &dev_hdl, portMAX_DELAY) != pdTRUE)
            continue;

        if (claim_if0(dev_hdl) != ESP_OK)
            continue;
        if (init_baseband(dev_hdl) != ESP_OK)
            continue;

        uint8_t tid = 0;
        i2c_repeater(dev_hdl, true);
        rtlsdr_i2c_read(dev_hdl, 0x34, 0x00, &tid);
        i2c_repeater(dev_hdl, false);

        if (tid != 0x69) {
            ESP_LOGW(TAG, "tuner id 0x%02x (expected R820T2 0x69)", tid);
            continue;
        }

        if (init_tuner_regs(dev_hdl) != ESP_OK || tuner_auto_gain(dev_hdl) != ESP_OK)
            continue;

        rtl_set_sample_rate(dev_hdl, SDR_USB_IQ_RATE_HZ);
        tune_fm_band(dev_hdl);
        set_ddc_nco(dev_hdl);

        if (start_bulk(dev_hdl) != ESP_OK) {
            ESP_LOGE(TAG, "bulk start failed");
            continue;
        }

        ESP_LOGI(TAG, "USB %lu Hz -> decim x%u -> I2S %u Hz IQ", (unsigned long)SDR_USB_IQ_RATE_HZ,
                 (unsigned)DECIMATION_FACTOR, (unsigned)IQ_RATE_TO_FPGA);
        /* USB stream persists; blocks here until unplug + replug emits another NEW_DEV (+ queue send). */
    }
}

void app_main(void)
{
    sdr_queue = xQueueCreate(1, sizeof(usb_device_handle_t));
    transfer_sem = xSemaphoreCreateBinary();
    bucket_queue = xQueueCreate(NUM_BULK_TRANSFERS, sizeof(usb_transfer_t *));
    ESP_ERROR_CHECK((bucket_queue && sdr_queue && transfer_sem) ? ESP_OK : ESP_ERR_NO_MEM);

    init_i2s();

    esp_err_t err = usb_host_install(&(usb_host_config_t){
        .skip_phy_setup = false,
        .intr_flags = ESP_INTR_FLAG_LEVEL1,
    });
    ESP_ERROR_CHECK(err);

    xTaskCreatePinnedToCore(usb_lib_task, "usb_lib", 4096, NULL, 10, NULL, 0);
    xTaskCreate(sdr_boot_task, "sdr_boot", 4096, NULL, 8, NULL);
    ESP_ERROR_CHECK(usb_host_client_register(
        &(usb_host_client_config_t){
            .is_synchronous = false,
            .max_num_event_msg = 5,
            .async =
                {
                    .client_event_callback = on_client_event,
                },
        },
        &client_hdl));

    xTaskCreatePinnedToCore(dsp_task, "dsp_i2s", 4096, NULL, 9, NULL, 1);

    for (;;)
        usb_host_client_handle_events(client_hdl, portMAX_DELAY);
}
