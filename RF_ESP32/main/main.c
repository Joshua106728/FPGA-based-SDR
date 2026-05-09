#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "esp_log.h"
#include "usb/usb_host.h"
#include "freertos/ringbuf.h"
#include "esp_err.h"
#include "driver/i2s_std.h"
#include "esp_dsp.h"

#define SDR_BULK_BUFFER_SIZE (16 * 512)
#define NUM_BULK_TRANSFERS 8

// ESP-DSP FIR DECIMATION: 1 MSPS -> 250 KSPS
#define FIR_TAPS 15
#define DECIMATION_FACTOR 4

__attribute__((aligned(16))) static float fir_coeffs[FIR_TAPS] = {
    -0.0101f, -0.0175f, -0.0039f,  0.0381f,  0.1042f,
     0.1741f,  0.2227f,  0.2393f,  0.2227f,  0.1741f,
     0.1042f,  0.0381f, -0.0039f, -0.0175f, -0.0101f
};

static fir_f32_t fir_state_i;
static fir_f32_t fir_state_q;

// Pad delay lines slightly to ensure the vector loop never over-reads
__attribute__((aligned(16))) static float delay_line_i[FIR_TAPS + 4];
__attribute__((aligned(16))) static float delay_line_q[FIR_TAPS + 4];

#define MAX_SAMPLES_PER_BUCKET (SDR_BULK_BUFFER_SIZE / 2)
__attribute__((aligned(16))) static float input_i_f32[MAX_SAMPLES_PER_BUCKET];
__attribute__((aligned(16))) static float input_q_f32[MAX_SAMPLES_PER_BUCKET];
__attribute__((aligned(16))) static float output_i_f32[MAX_SAMPLES_PER_BUCKET / DECIMATION_FACTOR];
__attribute__((aligned(16))) static float output_q_f32[MAX_SAMPLES_PER_BUCKET / DECIMATION_FACTOR];

static const char *TAG = "RTL_SDR_I2S";
static i2s_chan_handle_t tx_handle;

#define I2S_WS_GPIO     32
#define I2S_BCK_GPIO    26
#define I2S_DOUT_GPIO   25
#define SDR_SAMPLE_RATE  250000

void init_i2s_hardware(void)
{
    i2s_chan_config_t chan_cfg = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_AUTO, I2S_ROLE_MASTER);
    chan_cfg.dma_desc_num = 16;
    chan_cfg.dma_frame_num = 1024;
    ESP_ERROR_CHECK(i2s_new_channel(&chan_cfg, &tx_handle, NULL));

    i2s_std_config_t std_cfg = {
        .clk_cfg  = I2S_STD_CLK_DEFAULT_CONFIG(SDR_SAMPLE_RATE),
        .slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_8BIT, I2S_SLOT_MODE_STEREO),
        .gpio_cfg = {
            .mclk = I2S_GPIO_UNUSED,
            .bclk = I2S_BCK_GPIO,
            .ws   = I2S_WS_GPIO,
            .dout = I2S_DOUT_GPIO,
            .din  = I2S_GPIO_UNUSED,
        },
    };
    std_cfg.clk_cfg.clk_src = I2S_CLK_SRC_APLL;
    std_cfg.clk_cfg.mclk_multiple = I2S_MCLK_MULTIPLE_128;

    ESP_ERROR_CHECK(i2s_channel_init_std_mode(tx_handle, &std_cfg));
    ESP_ERROR_CHECK(i2s_channel_enable(tx_handle));
}

static usb_host_client_handle_t client_hdl;
static QueueHandle_t sdr_queue;
static SemaphoreHandle_t transfer_sem;

// R820T2 initialization array (Registers 0x05 through 0x1F)
static uint8_t r82xx_shadow_regs[27] = {
    0x83, 0x32, 0x75, 0xC0, 0x40, 0xD6, 0x6C, 0xF5, // 0x05 to 0x0C
    0x63, 0x75, 0x68, 0x6C, 0x83, 0x80, 0x00, 0x0F, // 0x0D to 0x14
    0x00, 0xC0, 0x30, 0x48, 0xCC, 0x60, 0x00, 0x54, // 0x15 to 0x1C
    0xAE, 0x4A, 0xC0                                 // 0x1D to 0x1F
};

static void transfer_cb(usb_transfer_t *transfer) {
    xSemaphoreGive(transfer_sem);
}

esp_err_t rtlsdr_read_reg(usb_device_handle_t dev_hdl, uint8_t block, uint16_t addr, uint8_t *data, uint16_t len) {
    usb_transfer_t *transfer;

    esp_err_t err = usb_host_transfer_alloc(8 + len, 0, &transfer);
    if (err != ESP_OK) return err;

    usb_setup_packet_t *setup = (usb_setup_packet_t *)transfer->data_buffer;
    setup->bmRequestType = 0xC0;  // Vendor IN (Read)
    setup->bRequest = 0;
    setup->wValue = addr;
    setup->wIndex = (block << 8);
    setup->wLength = len;

    transfer->device_handle = dev_hdl;
    transfer->bEndpointAddress = 0x00;
    transfer->callback = transfer_cb;
    transfer->context = NULL;
    transfer->num_bytes = 8 + len;

    err = usb_host_transfer_submit_control(client_hdl, transfer);

    if (err == ESP_OK) {
        xSemaphoreTake(transfer_sem, pdMS_TO_TICKS(1000));
        if (transfer->status == USB_TRANSFER_STATUS_COMPLETED) {
            memcpy(data, transfer->data_buffer + 8, len);
        } else {
            ESP_LOGE(TAG, "USB Transfer failed! Status: %d", transfer->status);
            err = ESP_FAIL;
        }
    } else {
        ESP_LOGE(TAG, "Failed to submit control transfer: %s", esp_err_to_name(err));
    }

    usb_host_transfer_free(transfer);
    return err;
}

esp_err_t rtlsdr_write_reg(usb_device_handle_t dev_hdl, uint8_t block, uint16_t addr, uint8_t val) {
    usb_transfer_t *transfer;

    esp_err_t err = usb_host_transfer_alloc(8 + 1, 0, &transfer);
    if (err != ESP_OK) return err;

    usb_setup_packet_t *setup = (usb_setup_packet_t *)transfer->data_buffer;
    setup->bmRequestType = 0x40;  // Vendor OUT (Write)
    setup->bRequest = 0;
    setup->wValue = addr;
    setup->wIndex = (block << 8) | 0x10; // Write flag in high nibble of index
    setup->wLength = 1;

    transfer->data_buffer[8] = val;

    transfer->device_handle = dev_hdl;
    transfer->bEndpointAddress = 0x00;
    transfer->callback = transfer_cb;
    transfer->context = NULL;
    transfer->num_bytes = 8 + 1;

    err = usb_host_transfer_submit_control(client_hdl, transfer);

    if (err == ESP_OK) {
        xSemaphoreTake(transfer_sem, pdMS_TO_TICKS(1000));
        if (transfer->status != USB_TRANSFER_STATUS_COMPLETED) {
            ESP_LOGE(TAG, "Write Transfer failed! Status: %d", transfer->status);
            err = ESP_FAIL;
        }
    } else {
        ESP_LOGE(TAG, "Failed to submit write transfer: %s", esp_err_to_name(err));
    }

    usb_host_transfer_free(transfer);
    return err;
}

esp_err_t rtlsdr_write_reg_16(usb_device_handle_t dev_hdl, uint8_t block, uint16_t addr, uint16_t val) {
    usb_transfer_t *transfer;

    esp_err_t err = usb_host_transfer_alloc(8 + 2, 0, &transfer);
    if (err != ESP_OK) return err;

    usb_setup_packet_t *setup = (usb_setup_packet_t *)transfer->data_buffer;
    setup->bmRequestType = 0x40;
    setup->bRequest = 0;
    setup->wValue = addr;
    setup->wIndex = (block << 8) | 0x10;
    setup->wLength = 2;

    // Big-Endian payload
    transfer->data_buffer[8] = (val >> 8) & 0xFF;
    transfer->data_buffer[9] = val & 0xFF;

    transfer->device_handle = dev_hdl;
    transfer->bEndpointAddress = 0x00;
    transfer->callback = transfer_cb;
    transfer->context = NULL;
    transfer->num_bytes = 8 + 2;

    err = usb_host_transfer_submit_control(client_hdl, transfer);

    if (err == ESP_OK) {
        xSemaphoreTake(transfer_sem, pdMS_TO_TICKS(1000));
        if (transfer->status != USB_TRANSFER_STATUS_COMPLETED) err = ESP_FAIL;
    }

    usb_host_transfer_free(transfer);
    return err;
}

esp_err_t rtlsdr_demod_write_reg_16(usb_device_handle_t dev_hdl, uint8_t page, uint16_t addr, uint16_t val) {
    usb_transfer_t *transfer;
    esp_err_t err = usb_host_transfer_alloc(8 + 2, 0, &transfer);
    if (err != ESP_OK) return err;

    usb_setup_packet_t *setup = (usb_setup_packet_t *)transfer->data_buffer;
    setup->bmRequestType = 0x40;
    setup->bRequest = 0;
    setup->wValue = (addr << 8) | 0x20; // Demodulator addressing
    setup->wIndex = 0x10 | page;        // Write flag + Page
    setup->wLength = 2;

    // Big-Endian payload
    transfer->data_buffer[8] = (val >> 8) & 0xFF;
    transfer->data_buffer[9] = val & 0xFF;

    transfer->device_handle = dev_hdl;
    transfer->bEndpointAddress = 0x00;
    transfer->callback = transfer_cb;
    transfer->context = NULL;
    transfer->num_bytes = 8 + 2;

    err = usb_host_transfer_submit_control(client_hdl, transfer);
    if (err == ESP_OK) {
        xSemaphoreTake(transfer_sem, pdMS_TO_TICKS(1000));
        if (transfer->status != USB_TRANSFER_STATUS_COMPLETED) err = ESP_FAIL;
    }

    usb_host_transfer_free(transfer);
    return err;
}

esp_err_t rtlsdr_demod_read_reg(usb_device_handle_t dev_hdl, uint8_t page, uint16_t addr, uint8_t *data, uint16_t len) {
    usb_transfer_t *transfer;
    esp_err_t err = usb_host_transfer_alloc(8 + len, 0, &transfer);
    if (err != ESP_OK) return err;

    usb_setup_packet_t *setup = (usb_setup_packet_t *)transfer->data_buffer;
    setup->bmRequestType = 0xC0;        // IN (Read)
    setup->bRequest = 0;
    setup->wValue = (addr << 8) | 0x20; // Demodulator addressing
    setup->wIndex = page;               // Reads do not use the 0x10 write flag
    setup->wLength = len;

    transfer->device_handle = dev_hdl;
    transfer->bEndpointAddress = 0x00;
    transfer->callback = transfer_cb;
    transfer->context = NULL;
    transfer->num_bytes = 8 + len;

    err = usb_host_transfer_submit_control(client_hdl, transfer);
    if (err == ESP_OK) {
        xSemaphoreTake(transfer_sem, pdMS_TO_TICKS(1000));
        if (transfer->status == USB_TRANSFER_STATUS_COMPLETED) {
            memcpy(data, transfer->data_buffer + 8, len);
        } else {
            err = ESP_FAIL;
        }
    }

    usb_host_transfer_free(transfer);
    return err;
}

esp_err_t rtlsdr_set_sample_rate(usb_device_handle_t dev_hdl, uint32_t samp_rate) {
    uint32_t rsamp_ratio = (uint32_t)((28800000ULL << 22) / samp_rate);
    rsamp_ratio &= 0x0FFFFFFC;

    esp_err_t err = rtlsdr_demod_write_reg_16(dev_hdl, 1, 0x9f, (uint16_t)(rsamp_ratio >> 16));
    if (err != ESP_OK) return err;

    return rtlsdr_demod_write_reg_16(dev_hdl, 1, 0xa1, (uint16_t)(rsamp_ratio & 0xffff));
}

esp_err_t rtlsdr_i2c_read_reg(usb_device_handle_t dev_hdl, uint8_t i2c_addr, uint8_t reg, uint8_t *val) {
    uint16_t addr = i2c_addr | (reg << 8);
    return rtlsdr_read_reg(dev_hdl, 6, addr, val, 1);
}

esp_err_t rtlsdr_i2c_write_reg(usb_device_handle_t dev_hdl, uint8_t i2c_addr, uint8_t reg, uint8_t val) {
    uint16_t addr = i2c_addr | (reg << 8);
    return rtlsdr_write_reg(dev_hdl, 6, addr, val);
}

esp_err_t claim_sdr_interface(usb_device_handle_t dev_hdl) {
    esp_err_t err = usb_host_interface_claim(client_hdl, dev_hdl, 0, 0);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "FAILED to claim interface: %s", esp_err_to_name(err));
    }
    return err;
}

esp_err_t rtlsdr_demod_write_reg(usb_device_handle_t dev_hdl, uint8_t page, uint16_t addr, uint8_t val) {
    usb_transfer_t *transfer;

    esp_err_t err = usb_host_transfer_alloc(8 + 1, 0, &transfer);
    if (err != ESP_OK) return err;

    usb_setup_packet_t *setup = (usb_setup_packet_t *)transfer->data_buffer;
    setup->bmRequestType = 0x40;
    setup->bRequest = 0;
    setup->wValue = (addr << 8) | 0x20;
    setup->wIndex = 0x10 | page;
    setup->wLength = 1;

    transfer->data_buffer[8] = val;

    transfer->device_handle = dev_hdl;
    transfer->bEndpointAddress = 0x00;
    transfer->callback = transfer_cb;
    transfer->context = NULL;
    transfer->num_bytes = 8 + 1;

    err = usb_host_transfer_submit_control(client_hdl, transfer);

    if (err == ESP_OK) {
        xSemaphoreTake(transfer_sem, pdMS_TO_TICKS(1000));
        if (transfer->status != USB_TRANSFER_STATUS_COMPLETED) {
            ESP_LOGE(TAG, "Demod Write Transfer failed! Status: %d", transfer->status);
            err = ESP_FAIL;
        }
    }

    usb_host_transfer_free(transfer);
    return err;
}

esp_err_t rtlsdr_set_i2c_repeater(usb_device_handle_t dev_hdl, bool on) {
    return rtlsdr_demod_write_reg(dev_hdl, 1, 0x01, on ? 0x18 : 0x10);
}

esp_err_t rtlsdr_init_baseband_real(usb_device_handle_t dev_hdl) {
    esp_err_t err;

    // Set USB EPA Maximum Packet Size to 512 bytes
    err = rtlsdr_write_reg_16(dev_hdl, 1, 0x2158, 0x0002);
    if (err != ESP_OK) return err;

    // Power on the Demodulator
    rtlsdr_write_reg(dev_hdl, 2, 0x300B, 0x22);
    rtlsdr_write_reg(dev_hdl, 2, 0x3000, 0xE8);

    // Reset the Demodulator state machine
    rtlsdr_demod_write_reg(dev_hdl, 1, 0x01, 0x14);
    rtlsdr_demod_write_reg(dev_hdl, 1, 0x01, 0x10);

    // Enable SDR Mode & Disable DAGC
    rtlsdr_demod_write_reg(dev_hdl, 0, 0x19, 0x05);

    // Default ADC datapath
    rtlsdr_demod_write_reg(dev_hdl, 0, 0x06, 0x80);

    // Enable Zero-IF mode / baseband output
    rtlsdr_demod_write_reg(dev_hdl, 1, 0xB1, 0x1B);

    // Kill PID filter (stops 188-byte fragmentation)
    rtlsdr_demod_write_reg(dev_hdl, 0, 0x61, 0x60);

    // Disable RF and IF AGC loops
    rtlsdr_demod_write_reg(dev_hdl, 1, 0x04, 0x00);

    // Disable secondary digital AGC
    rtlsdr_demod_write_reg(dev_hdl, 1, 0x11, 0x00);

    return ESP_OK;
}

esp_err_t rtlsdr_init_tuner(usb_device_handle_t dev_hdl) {
    esp_err_t err = ESP_OK;

    err = rtlsdr_set_i2c_repeater(dev_hdl, true);
    if (err != ESP_OK) return err;

    for (int i = 0; i < 27; i++) {
        uint8_t reg = 0x05 + i;
        err = rtlsdr_i2c_write_reg(dev_hdl, 0x34, reg, r82xx_shadow_regs[i]);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "Failed to write tuner init reg 0x%02X", reg);
            break;
        }
    }

    rtlsdr_set_i2c_repeater(dev_hdl, false);
    return err;
}

esp_err_t rtlsdr_tune_102_9mhz_mock(usb_device_handle_t dev_hdl) {
    esp_err_t err = rtlsdr_set_i2c_repeater(dev_hdl, true);
    if (err != ESP_OK) return err;

    // PLL values for 102.9 MHz
    rtlsdr_i2c_write_reg(dev_hdl, 0x34, 0x1A, 0x76); // Integer part (118)
    rtlsdr_i2c_write_reg(dev_hdl, 0x34, 0x1B, 0x4C); // Fractional MSB
    rtlsdr_i2c_write_reg(dev_hdl, 0x34, 0x1C, 0xCD); // Fractional LSB
    rtlsdr_i2c_write_reg(dev_hdl, 0x34, 0x1A, 0x76); // Trigger VCO calibration

    vTaskDelay(pdMS_TO_TICKS(50));

    uint8_t lock_status = 0;
    rtlsdr_i2c_read_reg(dev_hdl, 0x34, 0x02, &lock_status);

    rtlsdr_set_i2c_repeater(dev_hdl, false);

    if (!(lock_status & 0x40)) {
        ESP_LOGE(TAG, "PLL Failed to lock. Status: 0x%02X", lock_status);
    }

    return ESP_OK;
}

// 3.57 MHz IF offset configuration
esp_err_t rtlsdr_set_if_357mhz_mock(usb_device_handle_t dev_hdl) {
    // Pre-calculated 22-bit NCO value (0x381121) for 3.57 MHz IF
    rtlsdr_demod_write_reg(dev_hdl, 1, 0x19, 0x38); // High byte
    rtlsdr_demod_write_reg(dev_hdl, 1, 0x1A, 0x11); // Middle byte
    rtlsdr_demod_write_reg(dev_hdl, 1, 0x1B, 0x21); // Low byte

    uint8_t r19 = 0, r1A = 0, r1B = 0;
    rtlsdr_demod_read_reg(dev_hdl, 1, 0x19, &r19, 1);
    rtlsdr_demod_read_reg(dev_hdl, 1, 0x1A, &r1A, 1);
    rtlsdr_demod_read_reg(dev_hdl, 1, 0x1B, &r1B, 1);

    uint32_t verified_nco = ((uint32_t)r19 << 16) | ((uint32_t)r1A << 8) | r1B;
    verified_nco &= 0x3FFFFF;

    if (verified_nco != 0x381121) {
        ESP_LOGE(TAG, "NCO mismatch! Expected 0x381121, got 0x%06lX", verified_nco);
        return ESP_FAIL;
    }
    return ESP_OK;
}

static QueueHandle_t bucket_queue;

static volatile uint32_t ringbuf_overflows = 0;

static void bulk_transfer_cb(usb_transfer_t *transfer) {
    if (transfer->status == USB_TRANSFER_STATUS_COMPLETED) {
        if (xQueueSend(bucket_queue, &transfer, 0) != pdTRUE) {
            ringbuf_overflows++;
            usb_host_transfer_submit(transfer);
        }
    } else {
        ESP_LOGE(TAG, "Bulk transfer failed! Status: %d", transfer->status);
        usb_host_transfer_submit(transfer);
    }
}

esp_err_t start_sdr_stream(usb_device_handle_t dev_hdl) {
    // Clear the FIFO on the RTL2832U
    rtlsdr_write_reg_16(dev_hdl, 1, 0x2148, 0x1002);
    rtlsdr_write_reg_16(dev_hdl, 1, 0x2148, 0x0000);

    for (int i = 0; i < NUM_BULK_TRANSFERS; i++) {
        usb_transfer_t *transfer;
        esp_err_t err = usb_host_transfer_alloc(SDR_BULK_BUFFER_SIZE, 0, &transfer);
        if (err != ESP_OK) return err;

        transfer->device_handle = dev_hdl;
        transfer->bEndpointAddress = 0x81;
        transfer->callback = bulk_transfer_cb;
        transfer->context = (void*)i;
        transfer->num_bytes = SDR_BULK_BUFFER_SIZE;

        err = usb_host_transfer_submit(transfer);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "Failed to submit transfer %d", i);
            return err;
        }
    }

    return ESP_OK;
}

esp_err_t rtlsdr_set_tuner_auto_gain(usb_device_handle_t dev_hdl) {
    rtlsdr_set_i2c_repeater(dev_hdl, true);

    // Register 0x05: LNA Gain Mode (Bit 4: 0 = Auto)
    uint8_t reg05 = r82xx_shadow_regs[0x05 - 0x05];
    reg05 &= ~0x10;
    rtlsdr_i2c_write_reg(dev_hdl, 0x34, 0x05, reg05);
    r82xx_shadow_regs[0] = reg05;

    // Register 0x07: Mixer Gain Mode (Bit 4: 1 = Auto)
    uint8_t reg07 = r82xx_shadow_regs[0x07 - 0x05];
    reg07 |= 0x10;
    rtlsdr_i2c_write_reg(dev_hdl, 0x34, 0x07, reg07);
    r82xx_shadow_regs[2] = reg07;

    // Register 0x0C: VGA Gain fixed to 26.5 dB
    uint8_t reg0c = r82xx_shadow_regs[0x0C - 0x05];
    reg0c = (reg0c & ~0x9F) | 0x0B;
    rtlsdr_i2c_write_reg(dev_hdl, 0x34, 0x0C, reg0c);
    r82xx_shadow_regs[7] = reg0c;

    rtlsdr_set_i2c_repeater(dev_hdl, false);
    return ESP_OK;
}

esp_err_t rtlsdr_set_tuner_manual_gain(usb_device_handle_t dev_hdl) {
    rtlsdr_set_i2c_repeater(dev_hdl, true);

    // Register 0x05: Disable LNA Auto Gain (Bit 4 = 1), set LNA to Max (Index 15)
    uint8_t reg05 = r82xx_shadow_regs[0x05 - 0x05];
    reg05 = (reg05 & ~0x1F) | 0x1F;
    rtlsdr_i2c_write_reg(dev_hdl, 0x34, 0x05, reg05);
    r82xx_shadow_regs[0] = reg05;

    // Register 0x07: Disable Mixer Auto Gain (Bit 4 = 0), set Mixer to Max (Index 15)
    uint8_t reg07 = r82xx_shadow_regs[0x07 - 0x05];
    reg07 = (reg07 & ~0x1F) | 0x0F;
    rtlsdr_i2c_write_reg(dev_hdl, 0x34, 0x07, reg07);
    r82xx_shadow_regs[2] = reg07;

    // Register 0x0C: VGA Gain fixed high
    uint8_t reg0c = r82xx_shadow_regs[0x0C - 0x05];
    reg0c = (reg0c & ~0x9F) | 0x08;
    rtlsdr_i2c_write_reg(dev_hdl, 0x34, 0x0C, reg0c);
    r82xx_shadow_regs[7] = reg0c;

    rtlsdr_set_i2c_repeater(dev_hdl, false);
    return ESP_OK;
}

static void sdr_control_task(void *arg) {
    usb_device_handle_t dev_hdl;

    while (1) {
        if (xQueueReceive(sdr_queue, &dev_hdl, portMAX_DELAY)) {
            if (claim_sdr_interface(dev_hdl) != ESP_OK) continue;

            if (rtlsdr_init_baseband_real(dev_hdl) != ESP_OK) {
                ESP_LOGE(TAG, "Failed to power on Demodulator.");
                continue;
            }

            rtlsdr_set_i2c_repeater(dev_hdl, true);
            uint8_t tuner_id = 0;
            rtlsdr_i2c_read_reg(dev_hdl, 0x34, 0x00, &tuner_id);
            rtlsdr_set_i2c_repeater(dev_hdl, false);

            if (tuner_id == 0x69) {
                rtlsdr_init_tuner(dev_hdl);
                rtlsdr_set_tuner_manual_gain(dev_hdl);
                rtlsdr_set_sample_rate(dev_hdl, 1000000);

                // Verify sample rate ratio readback
                uint8_t read_buf[2];
                rtlsdr_demod_read_reg(dev_hdl, 1, 0x9f, read_buf, 2);
                uint16_t high_val = (read_buf[0] << 8) | read_buf[1];

                rtlsdr_demod_read_reg(dev_hdl, 1, 0xa1, read_buf, 2);
                uint16_t low_val = (read_buf[0] << 8) | read_buf[1];

                uint32_t verified_ratio = ((uint32_t)high_val << 16) | low_val;
                if (verified_ratio != 0x0CCCCCCC) {
                    ESP_LOGE(TAG, "Sample rate ratio mismatch! Expected 0x0CCCCCCC got 0x%08lX", verified_ratio);
                }

                rtlsdr_tune_102_9mhz_mock(dev_hdl);
                rtlsdr_set_if_357mhz_mock(dev_hdl);
                start_sdr_stream(dev_hdl);

            } else {
                ESP_LOGE(TAG, "Tuner not found. Cannot proceed.");
            }
        }
    }
}

static void usb_lib_task(void *arg) {
    while (1) {
        uint32_t event_flags;
        usb_host_lib_handle_events(portMAX_DELAY, &event_flags);
        if (event_flags & USB_HOST_LIB_EVENT_FLAGS_NO_CLIENTS) {
            ESP_ERROR_CHECK(usb_host_device_free_all());
        }
        if (event_flags & USB_HOST_LIB_EVENT_FLAGS_ALL_FREE) {
            break;
        }
    }
    vTaskDelete(NULL);
}

static void client_event_cb(const usb_host_client_event_msg_t *msg, void *arg) {
    if (msg->event == USB_HOST_CLIENT_EVENT_NEW_DEV) {
        usb_device_handle_t dev_hdl;
        esp_err_t err = usb_host_device_open(client_hdl, msg->new_dev.address, &dev_hdl);
        if (err == ESP_OK) {
            xQueueSend(sdr_queue, &dev_hdl, portMAX_DELAY);
        }
    } else if (msg->event == USB_HOST_CLIENT_EVENT_DEV_GONE) {
        usb_host_device_close(client_hdl, msg->dev_gone.dev_hdl);
    }
}

static void dsp_i2s_task(void *arg) {
    dsps_fird_init_f32(&fir_state_i, fir_coeffs, delay_line_i, FIR_TAPS, DECIMATION_FACTOR);
    dsps_fird_init_f32(&fir_state_q, fir_coeffs, delay_line_q, FIR_TAPS, DECIMATION_FACTOR);

    usb_transfer_t *transfer;
    uint8_t *decimated_buffer = malloc(SDR_BULK_BUFFER_SIZE / 4);

    while (1) {
        if (xQueueReceive(bucket_queue, &transfer, portMAX_DELAY)) {
            uint8_t *raw_data = transfer->data_buffer;
            int raw_len = transfer->actual_num_bytes;

            // Align to decimation factor boundary to prevent vector over-read
            int num_input_pairs = (raw_len / 2) & ~3;

            for (int k = 0; k < num_input_pairs; k++) {
                input_i_f32[k] = (float)raw_data[k * 2] - 128.0f;
                input_q_f32[k] = (float)raw_data[(k * 2) + 1] - 128.0f;
            }

            int num_output_pairs = num_input_pairs / DECIMATION_FACTOR;

            dsps_fird_f32(&fir_state_i, input_i_f32, output_i_f32, num_output_pairs);
            dsps_fird_f32(&fir_state_q, input_q_f32, output_q_f32, num_output_pairs);

            int out_idx = 0;
            for (int k = 0; k < num_output_pairs; k++) {
                float i_val_f = output_i_f32[k] + 128.0f;
                float q_val_f = output_q_f32[k] + 128.0f;

                if (i_val_f > 255.0f) i_val_f = 255.0f;
                if (i_val_f < 0.0f)   i_val_f = 0.0f;
                if (q_val_f > 255.0f) q_val_f = 255.0f;
                if (q_val_f < 0.0f)   q_val_f = 0.0f;

                decimated_buffer[out_idx++] = (uint8_t)i_val_f;
                decimated_buffer[out_idx++] = (uint8_t)q_val_f;
            }

            size_t written = 0;
            i2s_channel_write(tx_handle, decimated_buffer, out_idx, &written, portMAX_DELAY);

            usb_host_transfer_submit(transfer);
        }
    }
}

void app_main(void) {
    sdr_queue = xQueueCreate(1, sizeof(usb_device_handle_t));
    transfer_sem = xSemaphoreCreateBinary();

    bucket_queue = xQueueCreate(NUM_BULK_TRANSFERS, sizeof(usb_transfer_t *));
    if (bucket_queue == NULL) {
        ESP_LOGE(TAG, "Failed to create bucket queue!");
        return;
    }

    init_i2s_hardware();

    usb_host_config_t host_config = {
        .skip_phy_setup = false,
        .intr_flags = ESP_INTR_FLAG_LEVEL1,
    };
    ESP_ERROR_CHECK(usb_host_install(&host_config));

    xTaskCreatePinnedToCore(usb_lib_task, "usb_lib", 4096, NULL, 10, NULL, 0);
    xTaskCreate(sdr_control_task, "sdr_ctrl", 4096, NULL, 5, NULL);

    usb_host_client_config_t client_config = {
        .is_synchronous = false,
        .max_num_event_msg = 5,
        .async = {
            .client_event_callback = client_event_cb,
            .callback_arg = NULL,
        },
    };
    ESP_ERROR_CHECK(usb_host_client_register(&client_config, &client_hdl));

    xTaskCreatePinnedToCore(dsp_i2s_task, "dsp_i2s", 8192, NULL, 5, NULL, 1);

    while (1) {
        usb_host_client_handle_events(client_hdl, portMAX_DELAY);
    }
}
