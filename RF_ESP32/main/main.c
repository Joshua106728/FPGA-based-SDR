#include <stdio.h>
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

// ############################################################################
// ESP FIR FILTER SINCE WE ARE DOING DECIMATION GOING FROM 1 MSPS -> 250 KSPS #
// ############################################################################
// --- ESP-DSP FIR DECIMATION SETUP ---
#define FIR_TAPS 15
#define DECIMATION_FACTOR 4

// CRITICAL: ALIGN EVERYTHING TO 16 BYTES FOR RISC-V VECTOR INSTRUCTIONS
__attribute__((aligned(16))) static float fir_coeffs[FIR_TAPS] = {
    -0.0101f, -0.0175f, -0.0039f,  0.0381f,  0.1042f, 
     0.1741f,  0.2227f,  0.2393f,  0.2227f,  0.1741f, 
     0.1042f,  0.0381f, -0.0039f, -0.0175f, -0.0101f
};

static fir_f32_t fir_state_i;
static fir_f32_t fir_state_q;

// CRITICAL: Pad the delay lines slightly to ensure the vector loop never over-reads
__attribute__((aligned(16))) static float delay_line_i[FIR_TAPS + 4];
__attribute__((aligned(16))) static float delay_line_q[FIR_TAPS + 4];

// CRITICAL: Align the massive conversion arrays
#define MAX_SAMPLES_PER_BUCKET (SDR_BULK_BUFFER_SIZE / 2)
__attribute__((aligned(16))) static float input_i_f32[MAX_SAMPLES_PER_BUCKET];
__attribute__((aligned(16))) static float input_q_f32[MAX_SAMPLES_PER_BUCKET];
__attribute__((aligned(16))) static float output_i_f32[MAX_SAMPLES_PER_BUCKET / DECIMATION_FACTOR];
__attribute__((aligned(16))) static float output_q_f32[MAX_SAMPLES_PER_BUCKET / DECIMATION_FACTOR];

// ############################################################################
// END FIR FILTER SINCE WE ARE DOING DECIMATION GOING FROM 1 MSPS -> 250 KSPS #
// ############################################################################


static const char *TAG = "RTL_SDR_I2S"; // This defines the name used in ESP_LOGI
static i2s_chan_handle_t tx_handle;    // This holds the I2S hardware handle

// #################################################################
// I2S STUFF #######################################################
// #################################################################
// ==========================================
#define I2S_WS_GPIO     4    // Word Select
#define I2S_BCK_GPIO    5    // Bit Clock
#define I2S_DOUT_GPIO   6    // Data Out

#define SDR_SAMPLE_RATE  250000 // 250 kHz
void init_i2s_hardware(void)
{
    ESP_LOGI(TAG, "Initializing 8-Bit I2S Pipeline...");
    i2s_chan_config_t chan_cfg = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_AUTO, I2S_ROLE_MASTER);
    
    // Using your exact DMA settings for stability
    chan_cfg.dma_desc_num = 16;
    chan_cfg.dma_frame_num = 1024; 
    ESP_ERROR_CHECK(i2s_new_channel(&chan_cfg, &tx_handle, NULL));

    i2s_std_config_t std_cfg = {
        .clk_cfg  = I2S_STD_CLK_DEFAULT_CONFIG(SDR_SAMPLE_RATE), // 250 kHz
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

// #################################################################
// END I2S STUFF ###################################################
// #################################################################
// ==========================================


// #################################################################
// USB STUFF #######################################################
// #################################################################
// ==========================================
// Upgrade from 2 buckets to 4 buckets to absorb the data spikes
    
static usb_host_client_handle_t client_hdl;

// Synchronization objects to safely pass data between USB callbacks and our code
static QueueHandle_t sdr_queue;
static SemaphoreHandle_t transfer_sem;

// R820T2 initialization array (Registers 0x05 through 0x1F)
// We keep this global so we can modify specific bits later (like changing frequencies)
static uint8_t r82xx_shadow_regs[27] = {
    0x83, 0x32, 0x75, 0xC0, 0x40, 0xD6, 0x6C, 0xF5, // 0x05 to 0x0C
    0x63, 0x75, 0x68, 0x6C, 0x83, 0x80, 0x00, 0x0F, // 0x0D to 0x14
    0x00, 0xC0, 0x30, 0x48, 0xCC, 0x60, 0x00, 0x54, // 0x15 to 0x1C
    0xAE, 0x4A, 0xC0                                // 0x1D to 0x1F
};

// Callback triggered when a USB transfer completes
static void transfer_cb(usb_transfer_t *transfer) {
    xSemaphoreGive(transfer_sem); // Signal that the transfer is done
}

// ---------------------------------------------------------
// NEW: RTL-SDR Register Read Function
// ---------------------------------------------------------
esp_err_t rtlsdr_read_reg(usb_device_handle_t dev_hdl, uint8_t block, uint16_t addr, uint8_t *data, uint16_t len) {
    usb_transfer_t *transfer;
    
    // Allocate transfer buffer (8 bytes for USB setup packet + length of data requested)
    esp_err_t err = usb_host_transfer_alloc(8 + len, 0, &transfer);
    if (err != ESP_OK) return err;

// Format the USB Setup Packet according to RTL-SDR specifications
    usb_setup_packet_t *setup = (usb_setup_packet_t *)transfer->data_buffer;
    setup->bmRequestType = 0xC0;  // 0xC0 = Vendor IN (Read)
    setup->bRequest = 0;          // 0 = Read Register
    setup->wValue = addr;         // Register address
    setup->wIndex = (block << 8); // FIX: Shift the block ID to the high byte!
    setup->wLength = len;         // Number of bytes to read

    transfer->device_handle = dev_hdl;
    transfer->bEndpointAddress = 0x00; // Endpoint 0 is always used for Control Transfers
    transfer->callback = transfer_cb;
    transfer->context = NULL;
    transfer->num_bytes = 8 + len;

    // FIX: Use the specific function for Endpoint 0 Control Transfers!
    err = usb_host_transfer_submit_control(client_hdl, transfer);
    
    if (err == ESP_OK) {
        // Block this task until the transfer_cb gives the semaphore
        xSemaphoreTake(transfer_sem, pdMS_TO_TICKS(1000));
        
        if (transfer->status == USB_TRANSFER_STATUS_COMPLETED) {
            // Copy the payload data (skip the 8-byte setup packet)
            memcpy(data, transfer->data_buffer + 8, len);
        } else {
            ESP_LOGE(TAG, "USB Transfer failed! Status: %d", transfer->status);
            err = ESP_FAIL;
        }
    } else {
        // Print the exact error if it fails to submit again
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
    setup->bmRequestType = 0x40;  // 0x40 = Vendor OUT (Write)
    setup->bRequest = 0;          // 0 = Write Register
    setup->wValue = addr;         // Register address
    
    // FIX: Write commands require the 0x10 magic flag added to the index!
    setup->wIndex = (block << 8) | 0x10; 
    
    setup->wLength = 1;           // Writing 1 byte

    // Place our value into the payload section
    transfer->data_buffer[8] = val;

    transfer->device_handle = dev_hdl;
    transfer->bEndpointAddress = 0x00; // Endpoint 0
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
    
    // Allocate 8 bytes for setup + 2 bytes for the payload
    esp_err_t err = usb_host_transfer_alloc(8 + 2, 0, &transfer);
    if (err != ESP_OK) return err;

    usb_setup_packet_t *setup = (usb_setup_packet_t *)transfer->data_buffer;
    setup->bmRequestType = 0x40;  
    setup->bRequest = 0;          
    setup->wValue = addr;         
    setup->wIndex = (block << 8) | 0x10; 
    setup->wLength = 2; // FIX: 2-byte write

    // FIX: librtlsdr strictly uses Big-Endian for 16-bit payloads!
    transfer->data_buffer[8] = (val >> 8) & 0xFF; // MSB
    transfer->data_buffer[9] = val & 0xFF;        // LSB

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
    setup->wValue = (addr << 8) | 0x20; // FIX: Demodulator addressing
    setup->wIndex = 0x10 | page;        // FIX: Write flag + Page
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
    setup->wValue = (addr << 8) | 0x20; // FIX: Demodulator addressing
    setup->wIndex = page;               // FIX: Reads do not use the 0x10 write flag
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

    ESP_LOGI(TAG, "Setting sample rate to %lu Hz (Ratio: 0x%08lX)", samp_rate, rsamp_ratio);

    // FIX: Use the specific Demodulator 16-bit write function to Page 1
    esp_err_t err = rtlsdr_demod_write_reg_16(dev_hdl, 1, 0x9f, (uint16_t)(rsamp_ratio >> 16));
    if (err != ESP_OK) return err;

    err = rtlsdr_demod_write_reg_16(dev_hdl, 1, 0xa1, (uint16_t)(rsamp_ratio & 0xffff));
    return err;
}

// Matches rtlsdr_i2c_read_reg perfectly
esp_err_t rtlsdr_i2c_read_reg(usb_device_handle_t dev_hdl, uint8_t i2c_addr, uint8_t reg, uint8_t *val) {
    uint16_t addr = i2c_addr | (reg << 8);
    return rtlsdr_read_reg(dev_hdl, 6, addr, val, 1);
}

// Matches rtlsdr_i2c_write_reg perfectly
esp_err_t rtlsdr_i2c_write_reg(usb_device_handle_t dev_hdl, uint8_t i2c_addr, uint8_t reg, uint8_t val) {
    uint16_t addr = i2c_addr | (reg << 8);
    return rtlsdr_write_reg(dev_hdl, 6, addr, val);
}

esp_err_t claim_sdr_interface(usb_device_handle_t dev_hdl) {
    // The RTL-SDR uses Interface 0, Alternate Setting 0
    uint8_t bInterfaceNumber = 0;
    uint8_t bAlternateSetting = 0;
    
    // Correctly passing interface first, then alternate setting
    esp_err_t err = usb_host_interface_claim(client_hdl, dev_hdl, bInterfaceNumber, bAlternateSetting);
    
    if (err == ESP_OK) {
        ESP_LOGI(TAG, "SUCCESS: RTL-SDR Interface 0 claimed!");
    } else {
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

    // --- NEW DEBUGGING OUTPUT: RAW PACKET DUMP ---
    uint8_t *raw_bytes = (uint8_t *)transfer->data_buffer;
    ESP_LOGI(TAG, "--- DEMOD WRITE PACKET DUMP ---");
    ESP_LOGI(TAG, "Target: Page=0x%02X, Addr=0x%02X, Val=0x%02X", page, addr, val);
    ESP_LOGI(TAG, "Setup Bytes: %02X %02X %02X %02X %02X %02X %02X %02X",
             raw_bytes[0], raw_bytes[1], raw_bytes[2], raw_bytes[3], 
             raw_bytes[4], raw_bytes[5], raw_bytes[6], raw_bytes[7]);
    ESP_LOGI(TAG, "Payload: %02X", raw_bytes[8]);
    ESP_LOGI(TAG, "-------------------------------");

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
    // In librtlsdr, this opens Demodulator Page 1, Address 0x01
    // 0x18 turns the gate ON, 0x10 turns it OFF
    return rtlsdr_demod_write_reg(dev_hdl, 1, 0x01, on ? 0x18 : 0x10);
}

esp_err_t rtlsdr_init_baseband_real(usb_device_handle_t dev_hdl) {
    esp_err_t err;
    
    ESP_LOGI(TAG, "Initializing RTL2832U Baseband & SDR Mode...");
    
    // 1. Set USB EPA Maximum Packet Size to 512 bytes
    err = rtlsdr_write_reg_16(dev_hdl, 1, 0x2158, 0x0002);
    if (err != ESP_OK) return err;

    // 2. Power on the Demodulator 
    rtlsdr_write_reg(dev_hdl, 2, 0x300B, 0x22); 
    rtlsdr_write_reg(dev_hdl, 2, 0x3000, 0xE8); 

    // 3. Reset the Demodulator state machine
    rtlsdr_demod_write_reg(dev_hdl, 1, 0x01, 0x14);
    rtlsdr_demod_write_reg(dev_hdl, 1, 0x01, 0x10);

    // 4. THE MAGIC SWITCH: Enable SDR Mode & Disable DAGC
    rtlsdr_demod_write_reg(dev_hdl, 0, 0x19, 0x05);

    // 5. Default ADC datapath 
    rtlsdr_demod_write_reg(dev_hdl, 0, 0x06, 0x80);

    // 6. Enable Zero-IF mode / baseband output
    rtlsdr_demod_write_reg(dev_hdl, 1, 0xB1, 0x1B);

    // --- THE NEW FIXES ---
    
    // 7. KILL THE PID FILTER (Stops the 188-byte fragmentation!)
    rtlsdr_demod_write_reg(dev_hdl, 0, 0x61, 0x60);

    // 8. Disable the Demodulator RF and IF AGC loops (Stops the breathing!)
    rtlsdr_demod_write_reg(dev_hdl, 1, 0x04, 0x00);
    
    // 9. Disable the secondary digital AGC (Bit 0)
    rtlsdr_demod_write_reg(dev_hdl, 1, 0x11, 0x00);

    ESP_LOGI(TAG, "Baseband initialized! PID Filters DEAD. ADC routed to USB.");
    return ESP_OK;
}

esp_err_t rtlsdr_init_tuner(usb_device_handle_t dev_hdl) {
    esp_err_t err = ESP_OK;
    ESP_LOGI(TAG, "Writing R820T2 Initialization Array...");

    // 1. Open I2C gate
    err = rtlsdr_set_i2c_repeater(dev_hdl, true);
    if (err != ESP_OK) return err;

    // 2. Blast the array to registers 0x05 through 0x1F
    for (int i = 0; i < 27; i++) {
        uint8_t reg = 0x05 + i;
        err = rtlsdr_i2c_write_reg(dev_hdl, 0x34, reg, r82xx_shadow_regs[i]);
        
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "Failed to write tuner init reg 0x%02X", reg);
            break; // Stop immediately if a write fails
        }
    }

    // 3. Close I2C gate
    rtlsdr_set_i2c_repeater(dev_hdl, false);

    if (err == ESP_OK) {
        ESP_LOGI(TAG, "===========================================");
        ESP_LOGI(TAG, "SUCCESS! Tuner Initialized to Default State");
        ESP_LOGI(TAG, "===========================================");
    }
    
    return err;
}

esp_err_t rtlsdr_tune_102_9mhz_mock(usb_device_handle_t dev_hdl) {
    ESP_LOGI(TAG, "Tuning R820T2 to 102.9 MHz...");

    esp_err_t err = rtlsdr_set_i2c_repeater(dev_hdl, true);
    if (err != ESP_OK) return err;

    // Write the new calculated PLL values for 102.9 MHz
    rtlsdr_i2c_write_reg(dev_hdl, 0x34, 0x1A, 0x76); // Integer part (118)
    rtlsdr_i2c_write_reg(dev_hdl, 0x34, 0x1B, 0x4C); // Fractional MSB
    rtlsdr_i2c_write_reg(dev_hdl, 0x34, 0x1C, 0xCD); // Fractional LSB

    // Trigger the VCO calibration cycle
    rtlsdr_i2c_write_reg(dev_hdl, 0x34, 0x1A, 0x76); 

    vTaskDelay(pdMS_TO_TICKS(50));

    // Read Register 0x00 to check the lock status
    uint8_t lock_status = 0;
    rtlsdr_i2c_read_reg(dev_hdl, 0x34, 0x02, &lock_status);
    
    rtlsdr_set_i2c_repeater(dev_hdl, false);

    ESP_LOGI(TAG, "Tuner Reg 0x00 (Status): 0x%02X", lock_status);
    
    // Verify Bit 6 (0x40) for PLL Lock
    if (lock_status & 0x40) {
        ESP_LOGI(TAG, "===========================================");
        ESP_LOGI(TAG, "SUCCESS! Hardware PLL Locked to 102.9 MHz!");
        ESP_LOGI(TAG, "===========================================");
    } else {
        ESP_LOGE(TAG, "PLL Failed to lock. Status: 0x%02X", lock_status);
    }

    return ESP_OK;
}

// THIS IS FOR THE 3.57 MHz offset, not 357 MHZ
esp_err_t rtlsdr_set_if_357mhz_mock(usb_device_handle_t dev_hdl) {
    ESP_LOGI(TAG, "Configuring RTL2832U DDC for 3.57 MHz IF mix-down...");

    // Write the pre-calculated 22-bit NCO value (0x381121) to Demodulator Page 1
    rtlsdr_demod_write_reg(dev_hdl, 1, 0x19, 0x38); // High byte
    rtlsdr_demod_write_reg(dev_hdl, 1, 0x1A, 0x11); // Middle byte
    rtlsdr_demod_write_reg(dev_hdl, 1, 0x1B, 0x21); // Low byte

    // Verification Readback
    uint8_t r19 = 0, r1A = 0, r1B = 0;
    rtlsdr_demod_read_reg(dev_hdl, 1, 0x19, &r19, 1);
    rtlsdr_demod_read_reg(dev_hdl, 1, 0x1A, &r1A, 1);
    rtlsdr_demod_read_reg(dev_hdl, 1, 0x1B, &r1B, 1);

    // Reconstruct the 22-bit value
    uint32_t verified_nco = (r19 << 16) | (r1A << 8) | r1B;
    verified_nco &= 0x3FFFFF; // Mask off any stray upper bits (22-bit mask)

    ESP_LOGI(TAG, "Verified NCO Readback: 0x%06lX", verified_nco);

    if (verified_nco == 0x381121) {
        ESP_LOGI(TAG, "===========================================");
        ESP_LOGI(TAG, "SUCCESS! IF Down-Converter Configured!");
        ESP_LOGI(TAG, "===========================================");
    } else {
        ESP_LOGE(TAG, "NCO mismatch! Expected 0x381121, got 0x%06lX", verified_nco);
        return ESP_FAIL;
    }
    return ESP_OK;
}      

// A queue that holds POINTERS to our USB buckets, not the data itself!
static QueueHandle_t bucket_queue;

static volatile uint32_t ringbuf_overflows = 0;

// Diagnostic counters
static volatile uint32_t bytes_received_usb = 0;

static void bulk_transfer_cb(usb_transfer_t *transfer) {
    if (transfer->status == USB_TRANSFER_STATUS_COMPLETED) {
        
        // Toss the POINTER to the bucket into the queue.
        // Timeout is 0. If the DSP task is too slow, we don't wait!
        if (xQueueSend(bucket_queue, &transfer, 0) != pdTRUE) {
            // Queue is full! The DSP task is falling behind.
            // We MUST resubmit immediately to keep the USB hardware alive.
            ringbuf_overflows++;
            usb_host_transfer_submit(transfer);
        }
        
    } else {
        ESP_LOGE(TAG, "Bulk transfer failed! Status: %d", transfer->status);
        // Even on failure, try to keep the stream alive
        usb_host_transfer_submit(transfer);
    }
}

// 3. The function to kick off the Ping-Pong stream
esp_err_t start_sdr_stream(usb_device_handle_t dev_hdl) {
    ESP_LOGI(TAG, "Starting Ping-Pong Bulk Transfers...");
    
    // Clear the FIFO on the RTL2832U
    rtlsdr_write_reg_16(dev_hdl, 1, 0x2148, 0x1002); 
    rtlsdr_write_reg_16(dev_hdl, 1, 0x2148, 0x0000); 

    // Allocate and submit BOTH buckets simultaneously
    for (int i = 0; i < NUM_BULK_TRANSFERS; i++) {
        usb_transfer_t *transfer;
        esp_err_t err = usb_host_transfer_alloc(SDR_BULK_BUFFER_SIZE, 0, &transfer);
        if (err != ESP_OK) return err;

        transfer->device_handle = dev_hdl;
        transfer->bEndpointAddress = 0x81; 
        transfer->callback = bulk_transfer_cb;
        transfer->context = (void*)i; // We can use this to identify Bucket 0 or 1 later
        transfer->num_bytes = SDR_BULK_BUFFER_SIZE;

        err = usb_host_transfer_submit(transfer);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "Failed to submit transfer %d", i);
            return err;
        }
        ESP_LOGI(TAG, "Bucket %d deployed into the stream.", i);
    }
    
    return ESP_OK;
}

esp_err_t rtlsdr_set_tuner_auto_gain(usb_device_handle_t dev_hdl) {
    ESP_LOGI(TAG, "Setting R820T2 Tuner to Auto Gain...");
    
    // Open the I2C bridge
    rtlsdr_set_i2c_repeater(dev_hdl, true);

    // 1. Register 0x05: LNA Gain Mode (Bit 4: 0 = Auto)
    uint8_t reg05 = r82xx_shadow_regs[0x05 - 0x05];
    reg05 &= ~0x10; // Clear bit 4
    rtlsdr_i2c_write_reg(dev_hdl, 0x34, 0x05, reg05);
    r82xx_shadow_regs[0] = reg05;

    // 2. Register 0x07: Mixer Gain Mode (Bit 4: 1 = Auto)
    uint8_t reg07 = r82xx_shadow_regs[0x07 - 0x05];
    reg07 |= 0x10; // Set bit 4
    rtlsdr_i2c_write_reg(dev_hdl, 0x34, 0x07, reg07);
    r82xx_shadow_regs[2] = reg07;

    // 3. Register 0x0C: VGA Gain (Fixed to 26.5 dB -> Mask 0x9F with 0x0B)
    uint8_t reg0c = r82xx_shadow_regs[0x0C - 0x05];
    reg0c = (reg0c & ~0x9F) | 0x0B;
    rtlsdr_i2c_write_reg(dev_hdl, 0x34, 0x0C, reg0c);
    r82xx_shadow_regs[7] = reg0c;

    // Close the I2C bridge
    rtlsdr_set_i2c_repeater(dev_hdl, false);
    
    ESP_LOGI(TAG, "Auto Gain Configured!");
    return ESP_OK;
}

esp_err_t rtlsdr_set_tuner_manual_gain(usb_device_handle_t dev_hdl) {
    ESP_LOGI(TAG, "Setting R820T2 Tuner to Manual Gain (High)...");
    
    rtlsdr_set_i2c_repeater(dev_hdl, true);

    // 1. Disable LNA Auto Gain (Register 0x05, Bit 4 = 1) and set LNA to Max (Index 15 -> 0x0F)
    uint8_t reg05 = r82xx_shadow_regs[0x05 - 0x05];
    reg05 = (reg05 & ~0x1F) | 0x1F; // Set bit 4 (manual) and bits 0-3 (max gain index)
    rtlsdr_i2c_write_reg(dev_hdl, 0x34, 0x05, reg05);
    r82xx_shadow_regs[0] = reg05;

    // 2. Disable Mixer Auto Gain (Register 0x07, Bit 4 = 0) and set Mixer to Max (Index 15 -> 0x0F)
    uint8_t reg07 = r82xx_shadow_regs[0x07 - 0x05];
    reg07 = (reg07 & ~0x1F) | 0x0F; // Clear bit 4 (manual) and set bits 0-3 (max gain index)
    rtlsdr_i2c_write_reg(dev_hdl, 0x34, 0x07, reg07);
    r82xx_shadow_regs[2] = reg07;

    // 3. Set VGA Gain (Register 0x0C) to a fixed high value (e.g., 0x08 from the driver)
    uint8_t reg0c = r82xx_shadow_regs[0x0C - 0x05];
    reg0c = (reg0c & ~0x9F) | 0x08;
    rtlsdr_i2c_write_reg(dev_hdl, 0x34, 0x0C, reg0c);
    r82xx_shadow_regs[7] = reg0c;

    rtlsdr_set_i2c_repeater(dev_hdl, false);
    
    ESP_LOGI(TAG, "Manual Gain Configured!");
    return ESP_OK;
}

static void sdr_control_task(void *arg) {
    usb_device_handle_t dev_hdl;
    
    while (1) {
        if (xQueueReceive(sdr_queue, &dev_hdl, portMAX_DELAY)) {
            ESP_LOGI(TAG, "Device handle received. Claiming interface...");
            if (claim_sdr_interface(dev_hdl) != ESP_OK) continue;
            
            // 1. Wake up the RTL2832U Demodulator
            if (rtlsdr_init_baseband_real(dev_hdl) != ESP_OK) {
                ESP_LOGE(TAG, "Failed to power on Demodulator.");
                continue;
            }
            
            // 2. Ping/Init Tuner
            rtlsdr_set_i2c_repeater(dev_hdl, true);
            uint8_t tuner_id = 0;
            rtlsdr_i2c_read_reg(dev_hdl, 0x34, 0x00, &tuner_id);
            rtlsdr_set_i2c_repeater(dev_hdl, false);
            
            if (tuner_id == 0x69) {
                rtlsdr_init_tuner(dev_hdl);
                
                // raise the gain
                rtlsdr_set_tuner_manual_gain(dev_hdl);

                // 3. Set the Baseband Sample Rate to 250 kSPS
                ESP_LOGI(TAG, "Setting Hardware Sample Rate to 1 MSPS...");
                rtlsdr_set_sample_rate(dev_hdl, 1000000); // Changed from 250000
                
                // 4. Verification Readback
                uint8_t read_buf[2];
                uint16_t high_val, low_val;
                
                // FIX: Use Demodulator Read on Page 1
                rtlsdr_demod_read_reg(dev_hdl, 1, 0x9f, read_buf, 2);
                high_val = (read_buf[0] << 8) | read_buf[1];
                
                rtlsdr_demod_read_reg(dev_hdl, 1, 0xa1, read_buf, 2);
                low_val = (read_buf[0] << 8) | read_buf[1];
                
                uint32_t verified_ratio = (high_val << 16) | low_val;
                
                ESP_LOGI(TAG, "Verified rsamp_ratio Readback: 0x%08lX", verified_ratio);
                
                if (verified_ratio == 0x0CCCCCCC) {
                    ESP_LOGI(TAG, "===========================================");
                    ESP_LOGI(TAG, "SUCCESS! 250 kSPS Sample Rate Confirmed!");
                    ESP_LOGI(TAG, "===========================================");
                } else {
                    ESP_LOGE(TAG, "Sample rate ratio mismatch! Expected 0x0CCCCCCC got 0x%08lX", verified_ratio);
                }

                // --- NEW: Step 7 - Tuner PLL Lock Test ---
                rtlsdr_tune_102_9mhz_mock(dev_hdl);

                // --- NEW STEP: Step 8 - DDC IF Mix-down ---
                rtlsdr_set_if_357mhz_mock(dev_hdl);
                
                // --- NEW STEP: Step 9 - Start the Data Stream! ---
                start_sdr_stream(dev_hdl);

            } else {
                ESP_LOGE(TAG, "Tuner not found. Cannot proceed.");
            }
        }
    }
}

// ---------------------------------------------------------
// Existing USB Event Handling
// ---------------------------------------------------------
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
            const usb_device_desc_t *dev_desc;
            usb_host_get_device_descriptor(dev_hdl, &dev_desc);
            
            // Log the actual hardware IDs!
            ESP_LOGI(TAG, "USB Device Found! VID: 0x%04X, PID: 0x%04X", 
                     dev_desc->idVendor, dev_desc->idProduct);
            
                     // --- NEW DIAGNOSTIC: READ NEGOTIATED ENDPOINT SIZES ---
            const usb_config_desc_t *config_desc;
            if (usb_host_get_active_config_descriptor(dev_hdl, &config_desc) == ESP_OK) {
                const uint8_t *p = (const uint8_t *)config_desc;
                int offset = 0;
                while (offset < config_desc->wTotalLength) {
                    uint8_t len = p[offset];
                    uint8_t type = p[offset + 1];
                    if (type == 0x05) { // 0x05 is the USB code for an Endpoint Descriptor
                        usb_ep_desc_t *ep = (usb_ep_desc_t *)&p[offset];
                        ESP_LOGW(TAG, "DIAGNOSTIC -> Endpoint 0x%02X: MaxPacketSize = %d bytes", 
                                 ep->bEndpointAddress, ep->wMaxPacketSize);
                    }
                    offset += len;
                    if (len == 0) break; // Prevent infinite loop on bad descriptor
                }
            }
            // ------------------------------------------------------
            
            ESP_LOGI(TAG, "SUCCESS: Bypassing strict ID check. Sending to task...");
            
            // PASS THE DEVICE HANDLE TO OUR NEW TASK VIA QUEUE
            xQueueSend(sdr_queue, &dev_hdl, portMAX_DELAY);
        }
    } else if (msg->event == USB_HOST_CLIENT_EVENT_DEV_GONE) {
        ESP_LOGI(TAG, "Device disconnected.");
        usb_host_device_close(client_hdl, msg->dev_gone.dev_hdl);
    }
}

// CAPTURE 1000 SAMPLES
// --- RAM CAPTURE STATE VARIABLES ---
#define CAPTURE_SIZE 1000

static volatile int capture_count = 0;
static volatile bool trigger_fired = false;
static volatile bool dump_complete = false;

// #################################################
// dsp_i2s_task: FIR DECIMATION + RAM CAPTURE ######
// #################################################
// static uint8_t capture_i[CAPTURE_SIZE];
// static uint8_t capture_q[CAPTURE_SIZE];
// static void dsp_i2s_task(void *arg) {
//     ESP_LOGI(TAG, "Initializing Hardware FIR Decimator...");
    
//     // Initialize the ESP-DSP FIR decimation structures
//     dsps_fird_init_f32(&fir_state_i, fir_coeffs, delay_line_i, FIR_TAPS, DECIMATION_FACTOR);
//     dsps_fird_init_f32(&fir_state_q, fir_coeffs, delay_line_q, FIR_TAPS, DECIMATION_FACTOR);

//     ESP_LOGI(TAG, "FIR Decimator Online. Waiting for Signal Swing...");
    
//     usb_transfer_t *transfer;
//     uint8_t *decimated_buffer = malloc(SDR_BULK_BUFFER_SIZE / 4);
    
//     uint32_t bytes_processed = 0;
//     TickType_t last_print = xTaskGetTickCount();

//     uint8_t heartbeat_min = 255;
//     uint8_t heartbeat_max = 0;

//     while (1) {
//         if (xQueueReceive(bucket_queue, &transfer, portMAX_DELAY)) {
//             uint8_t *raw_data = transfer->data_buffer;
//             int raw_len = transfer->actual_num_bytes;
            
//             // --- THE FIX ---
//             // Ensure input pairs are a perfect multiple of the decimation factor (4).
//             // Using bitwise AND (~3) chops off any loose, fragmented bytes at the end of the bucket.
//             int num_input_pairs = (raw_len / 2) & ~3; 

//             // 1. SPLIT & FLOAT
//             for (int k = 0; k < num_input_pairs; k++) {
//                 input_i_f32[k] = (float)raw_data[k * 2] - 128.0f;
//                 input_q_f32[k] = (float)raw_data[(k * 2) + 1] - 128.0f;
//             }

//             // ESP-DSP Decimators require the number of OUTPUT samples to generate, NOT the input length!
//             int num_output_pairs = num_input_pairs / DECIMATION_FACTOR;

//             // 2. HARDWARE FILTER & DECIMATE
//             dsps_fird_f32(&fir_state_i, input_i_f32, output_i_f32, num_output_pairs);
//             dsps_fird_f32(&fir_state_q, input_q_f32, output_q_f32, num_output_pairs);

//             // 3. RE-PACK, CLAMP & SMART TRIGGER
//             int out_idx = 0;

//             for (int k = 0; k < num_output_pairs; k++) {
                
//                 float i_val_f = output_i_f32[k] + 128.0f;
//                 float q_val_f = output_q_f32[k] + 128.0f;

//                 if (i_val_f > 255.0f) i_val_f = 255.0f;
//                 if (i_val_f < 0.0f) i_val_f = 0.0f;
//                 if (q_val_f > 255.0f) q_val_f = 255.0f;
//                 if (q_val_f < 0.0f) q_val_f = 0.0f;

//                 uint8_t i_val = (uint8_t)i_val_f;
//                 uint8_t q_val = (uint8_t)q_val_f;

//                 decimated_buffer[out_idx++] = i_val;
//                 decimated_buffer[out_idx++] = q_val;

//                 // Track the swing of the FILTERED data
//                 if (i_val < heartbeat_min) heartbeat_min = i_val;
//                 if (i_val > heartbeat_max) heartbeat_max = i_val;

//                 // Trigger Logic
//                 if (!trigger_fired && (i_val > 132 || i_val < 123)) {
//                     trigger_fired = true;
//                     ESP_LOGW(TAG, "SIGNAL DETECTED! Snapping 1000 FIR-filtered samples to RAM...");
//                 }

//                 // Zero-Delay RAM Capture
//                 if (trigger_fired && capture_count < CAPTURE_SIZE) {
//                     capture_i[capture_count] = i_val;
//                     capture_q[capture_count] = q_val;
//                     capture_count++;
//                 }
//             }

//             // 4. Send the pristine baseband to the I2S Hardware
//             size_t written = 0;
//             i2s_channel_write(tx_handle, decimated_buffer, out_idx, &written, portMAX_DELAY);
//             bytes_processed += written; 

//             // 5. Hand the bucket back to USB immediately
//             usb_host_transfer_submit(transfer);

//             // 6. HEARTBEAT & SLOW PRINTING
//             if (xTaskGetTickCount() - last_print >= pdMS_TO_TICKS(1000)) {
                
//                 // If we filled the RAM buffer, slowly dump it to the terminal!
//                 if (capture_count == CAPTURE_SIZE && !dump_complete) {
//                     ESP_LOGW(TAG, "--- STARTING SLOW CSV DUMP ---");
//                     printf("Sample_Index, I, Q\n");
//                     for(int k = 0; k < CAPTURE_SIZE; k++) {
//                         printf("%d, %d, %d\n", k, capture_i[k], capture_q[k]);
                        
//                         // Feed the Watchdog every 50 lines so the chip doesn't crash!
//                         if (k % 50 == 0) vTaskDelay(pdMS_TO_TICKS(10));
//                     }
//                     printf("--- END OF CAPTURE ---\n");
//                     dump_complete = true;
//                 } 
//                 else if (!dump_complete) {
//                     // Normal Telemetry while waiting
//                     ESP_LOGI(TAG, "I2S: %lu KB/s | State: WAITING | Live Swing: Min=%03d, Max=%03d", 
//                                 bytes_processed / 1024, heartbeat_min, heartbeat_max);
//                 }
                
//                 bytes_processed = 0;
//                 heartbeat_min = 255;
//                 heartbeat_max = 0;
//                 last_print = xTaskGetTickCount();
//             }
//         }
//     }
// }

// -----------------------------------
// #################################################
// dsp_i2s_task: PRODUCTION MODE (SILENT STREAMING)
// #################################################
static void dsp_i2s_task(void *arg) {
    ESP_LOGI(TAG, "Initializing Hardware FIR Decimator...");
    
    // Initialize the ESP-DSP FIR decimation structures
    dsps_fird_init_f32(&fir_state_i, fir_coeffs, delay_line_i, FIR_TAPS, DECIMATION_FACTOR);
    dsps_fird_init_f32(&fir_state_q, fir_coeffs, delay_line_q, FIR_TAPS, DECIMATION_FACTOR);

    ESP_LOGI(TAG, "FIR Decimator Online. Streaming pristine baseband to I2S...");
    
    usb_transfer_t *transfer;
    uint8_t *decimated_buffer = malloc(SDR_BULK_BUFFER_SIZE / 4);
    
    uint32_t bytes_processed = 0;
    TickType_t last_print = xTaskGetTickCount();

    // Trackers to monitor the live RF swing
    uint8_t local_min = 255;
    uint8_t local_max = 0;

    while (1) {
        if (xQueueReceive(bucket_queue, &transfer, portMAX_DELAY)) {
            uint8_t *raw_data = transfer->data_buffer;
            int raw_len = transfer->actual_num_bytes;
            
            // CRITICAL FIX: Ensure input pairs are a perfect multiple of the decimation factor (4).
            // Using bitwise AND (~3) chops off any loose, fragmented bytes at the end of the bucket.
            int num_input_pairs = (raw_len / 2) & ~3; 

            // 1. SPLIT & FLOAT: Separate the interleaved 8-bit data and center it around 0.0
            for (int k = 0; k < num_input_pairs; k++) {
                input_i_f32[k] = (float)raw_data[k * 2] - 128.0f;
                input_q_f32[k] = (float)raw_data[(k * 2) + 1] - 128.0f;
            }

            // --- THE FINAL FIX ---
            // Calculate the OUTPUT length BEFORE calling the filter!
            int num_output_pairs = num_input_pairs / DECIMATION_FACTOR;

            // 2. HARDWARE FILTER & DECIMATE: 
            // Pass num_output_pairs so the vector unit stays strictly inside its memory bounds!
            dsps_fird_f32(&fir_state_i, input_i_f32, output_i_f32, num_output_pairs);
            dsps_fird_f32(&fir_state_q, input_q_f32, output_q_f32, num_output_pairs);

            // 3. RE-PACK & CLAMP: Convert the floats back to 8-bit interleaved for the I2S hardware
            int out_idx = 0;

            for (int k = 0; k < num_output_pairs; k++) {
                float i_val_f = output_i_f32[k] + 128.0f;
                float q_val_f = output_q_f32[k] + 128.0f;

                // Safety clamp to prevent hardware overflow just in case the math peaks hard
                if (i_val_f > 255.0f) i_val_f = 255.0f;
                if (i_val_f < 0.0f) i_val_f = 0.0f;
                if (q_val_f > 255.0f) q_val_f = 255.0f;
                if (q_val_f < 0.0f) q_val_f = 0.0f;

                uint8_t i_val = (uint8_t)i_val_f;
                uint8_t q_val = (uint8_t)q_val_f;

                decimated_buffer[out_idx++] = i_val;
                decimated_buffer[out_idx++] = q_val;

                // Track the swing of the cleanly filtered data
                if (i_val < local_min) local_min = i_val;
                if (i_val > local_max) local_max = i_val;
            }

            // 4. Send the pristine baseband to the I2S Hardware
            size_t written = 0;
            i2s_channel_write(tx_handle, decimated_buffer, out_idx, &written, portMAX_DELAY);
            bytes_processed += written; 

            // 5. Hand the bucket back to USB immediately
            usb_host_transfer_submit(transfer);

            // 6. Quiet 1-Second Telemetry Heartbeat
            if (xTaskGetTickCount() - last_print >= pdMS_TO_TICKS(1000)) {
                ESP_LOGI(TAG, "I2S OUT: %lu KB/s | FIR ACTIVE | Live Swing: Min=%03d, Max=%03d", 
                            bytes_processed / 1024, local_min, local_max);
                
                // Reset trackers for the next second
                bytes_processed = 0;
                local_min = 255;
                local_max = 0;
                last_print = xTaskGetTickCount();
            }
        }
    }
}

// #################################################
// PRIMITIVE DECIMATION I2S SENDING ################
// #################################################

// WORKING VERSION WITH PRIMITIVE DECIMATION
// #################################################
// dsp_i2s_task: PRODUCTION MODE (SILENT STREAMING)#
// #################################################
// static void dsp_i2s_task(void *arg) {
//     ESP_LOGI(TAG, "Production DSP Task started - Streaming straight to I2S...");
    
//     usb_transfer_t *transfer;
//     uint8_t *decimated_buffer = malloc(SDR_BULK_BUFFER_SIZE / 4);
    
//     uint32_t bytes_processed = 0;
//     TickType_t last_print = xTaskGetTickCount();

//     uint8_t local_min = 255;
//     uint8_t local_max = 0;

//     while (1) {
//         if (xQueueReceive(bucket_queue, &transfer, portMAX_DELAY)) {
//             uint8_t *raw_data = transfer->data_buffer;
//             int raw_len = transfer->actual_num_bytes;
//             int out_idx = 0;

//             // 1. Process and Decimate (4x)
//             for (int i = 0; i < raw_len; i += 8) {
//                 uint8_t i_val = raw_data[i];
//                 uint8_t q_val = raw_data[i + 1];
                
//                 decimated_buffer[out_idx++] = i_val;
//                 decimated_buffer[out_idx++] = q_val;

//                 // Track the swing so you can make sure the antenna is still connected
//                 if (i_val < local_min) local_min = i_val;
//                 if (i_val > local_max) local_max = i_val;
//             }

//             // 2. Push directly to I2S Hardware
//             size_t written = 0;
//             i2s_channel_write(tx_handle, decimated_buffer, out_idx, &written, portMAX_DELAY);
//             bytes_processed += written; 

//             // 3. Hand the bucket back to USB immediately
//             usb_host_transfer_submit(transfer);

//             // 4. Quiet 1-Second Telemetry Heartbeat
//             if (xTaskGetTickCount() - last_print >= pdMS_TO_TICKS(1000)) {
                
//                 ESP_LOGI(TAG, "I2S OUT: %lu KB/s | Live Swing: Min=%03d, Max=%03d", 
//                             bytes_processed / 1024, local_min, local_max);
                
//                 // Reset trackers for the next second
//                 bytes_processed = 0;
//                 local_min = 255;
//                 local_max = 0;
//                 last_print = xTaskGetTickCount();
//             }
//         }
//     }
// }

// Primitive Decimation technique (Capture samples)
// ##################################################
// dsp_i2s_task: SMART TRIGGER + CONTINUOUS CAPTURE #
// ##################################################
// static void dsp_i2s_task(void *arg) {
//     ESP_LOGI(TAG, "DSP Task started - Waiting for Signal Swing...");
    
//     usb_transfer_t *transfer;
//     uint8_t *decimated_buffer = malloc(SDR_BULK_BUFFER_SIZE / 4);
    
//     static bool csv_done = false;
//     static bool signal_found = false;
    
//     // NEW: Trackers for continuous accumulation
//     static int samples_saved = 0; 
//     const int TARGET_SAMPLES = 1000;

//     uint32_t bytes_processed = 0;
//     TickType_t last_print = xTaskGetTickCount();

//     uint8_t heartbeat_min = 255;
//     uint8_t heartbeat_max = 0;

//     while (1) {
//         if (xQueueReceive(bucket_queue, &transfer, portMAX_DELAY)) {
//             uint8_t *raw_data = transfer->data_buffer;
//             int raw_len = transfer->actual_num_bytes;
//             int out_idx = 0;

//             // 1. THE SMART TRIGGER
//             if (!signal_found) {
//                 for (int i = 0; i < raw_len; i += 8) {
//                     if (raw_data[i] > 132 || raw_data[i] < 123) {
//                         signal_found = true;
//                         ESP_LOGW(TAG, "SIGNAL DETECTED! Starting continuous capture...");
//                         printf("Sample_Index, I, Q\n"); // Print header once
//                         break; 
//                     }
//                 }
//             }

//             // 2. Process, Decimate, and Track
//             for (int i = 0; i < raw_len; i += 8) {
//                 uint8_t i_val = raw_data[i];
//                 uint8_t q_val = raw_data[i + 1];
                
//                 decimated_buffer[out_idx++] = i_val;
//                 decimated_buffer[out_idx++] = q_val;

//                 if (i_val < heartbeat_min) heartbeat_min = i_val;
//                 if (i_val > heartbeat_max) heartbeat_max = i_val;

//                 // --- CONTINUOUS CSV EXPORT LOGIC ---
//                 // If we found the signal, keep printing until we hit the target!
//                 if (signal_found && !csv_done) {
//                     printf("%d, %d, %d\n", samples_saved, i_val, q_val);
//                     samples_saved++;

//                     if (samples_saved >= TARGET_SAMPLES) {
//                         printf("--- END OF CAPTURE (%d Samples) ---\n", samples_saved);
//                         csv_done = true; 
//                     }
//                 }
//             }

//             // 3. Keep I2S hardware happy
//             size_t written = 0;
//             i2s_channel_write(tx_handle, decimated_buffer, out_idx, &written, portMAX_DELAY);
//             bytes_processed += written; 

//             // 4. Hand the bucket back to USB
//             usb_host_transfer_submit(transfer);

//             // 5. HEARTBEAT
//             if (xTaskGetTickCount() - last_print >= pdMS_TO_TICKS(1000)) {
                
//                 char *state_str = "WAITING";
//                 if (signal_found && !csv_done) state_str = "CAPTURING";
//                 if (csv_done) state_str = "DONE";

//                 ESP_LOGI(TAG, "I2S: %lu KB/s | State: %s | Live Swing: Min=%03d, Max=%03d", 
//                             bytes_processed / 1024, 
//                             state_str,
//                             heartbeat_min, heartbeat_max);
                
//                 bytes_processed = 0;
//                 heartbeat_min = 255;
//                 heartbeat_max = 0;
//                 last_print = xTaskGetTickCount();
//             }
//         }
//     }
// }

// #################################################
// END PRIMITIVE DECIMATION I2S SENDING ############
// #################################################

// #################################################################
// END USB STUFF ###################################################
// #################################################################
// ==========================================

void app_main(void) {
    // Initialize our synchronization objects
    sdr_queue = xQueueCreate(1, sizeof(usb_device_handle_t));
    transfer_sem = xSemaphoreCreateBinary();

    // Create a queue that holds exactly NUM_BULK_TRANSFERS pointers
    bucket_queue = xQueueCreate(NUM_BULK_TRANSFERS, sizeof(usb_transfer_t *));
    if (bucket_queue == NULL) {
        ESP_LOGE(TAG, "Failed to create bucket queue!");
        return;
    }
    
    // initialize I2S
    init_i2s_hardware();

    ESP_LOGI(TAG, "Starting USB Host Controller...");

    usb_host_config_t host_config = {
        .skip_phy_setup = false,
        .intr_flags = ESP_INTR_FLAG_LEVEL1,
    };
    ESP_ERROR_CHECK(usb_host_install(&host_config));

    xTaskCreatePinnedToCore(usb_lib_task, "usb_lib", 4096, NULL, 10, NULL, 0);
    
    // Start our new SDR Control Task
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

    ESP_LOGI(TAG, "Setup complete. Waiting for RTL-SDR to be plugged in...");

    // 6. Start the DSP/I2S Task on Core 1
    xTaskCreatePinnedToCore(dsp_i2s_task, "dsp_i2s", 8192, NULL, 5, NULL, 1);

    while (1) {
        usb_host_client_handle_events(client_hdl, portMAX_DELAY);
    }
    
}