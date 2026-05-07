#include <stdio.h>
#include <string.h>
#include <stdbool.h>
#include <math.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/ringbuf.h"

#include "nvs_flash.h"
#include "esp_log.h"
#include "esp_err.h"
#include "esp_bt.h"
#include "esp_bt_main.h"
#include "esp_gap_bt_api.h"
#include "esp_a2dp_api.h"
#include "esp_timer.h"
#include "driver/i2s_common.h"
#include "driver/i2s_std.h"
#include "driver/gpio.h"

#include "csv_audio_data.h"

#define SAMPLE_RATE 44100

#define CHANNELS 2
#define BYTES_PER_SAMPLE 2
#define FRAME_SIZE (CHANNELS * BYTES_PER_SAMPLE)

#define CHUNK_SAMPLES 256
#define CHUNK_BYTES (CHUNK_SAMPLES * FRAME_SIZE)
#define RINGBUF_SIZE (32 * 1024)

#define AUDIO_SRC_FPGA_I2S_PCM 0
#define AUDIO_SRC_TEST_TONE 1
#define AUDIO_SRC_CSV_DATA 2
#define AUDIO_SOURCE AUDIO_SRC_FPGA_I2S_PCM

#define TEST_TONE_FREQ_HZ 1000.0f
#define TEST_TONE_AMPLITUDE 0.20f

// Standard I2S RX GPIOs: FPGA drives BCLK/WS/DIN into ESP32.
#define I2S_BCLK_GPIO GPIO_NUM_26
#define I2S_WS_GPIO GPIO_NUM_25
#define I2S_DIN_GPIO GPIO_NUM_34
#define I2S_BCLK_INVERT true
#define I2S_WS_INVERT false

// ---- I2S compatibility toggles (build-time) ----
// If live I2S sounds like static, the common causes are a mismatch in:
// - Edge/polarity (BCLK/WS inversion)
// - Framing standard (Philips I2S vs MSB/left-justified)
// - Slot width (16-bit audio transported in 32-bit slots)
//
// These toggles let you try alternate receive formats without rewriting code.
#define I2S_USE_MSB_FORMAT false
#define I2S_RX_SLOT_BITS_32 false
#define I2S_RX_SHIFT_RIGHT 0  // For 32-bit slots, try 8 or 16 if alignment is off
// Logging control:
// - Set to 1 to print every I2S read (very noisy; can disrupt streaming on slow UART).
// - Set to e.g. 50 to print about once per second-ish depending on CHUNK_SAMPLES.
#define I2S_LOG_EVERY_N_BLOCKS 100

// Output gain applied before sending to A2DP (saturating).
// Start with 2 (x2). If you hear distortion/clipping, lower it.
#define AUDIO_GAIN_SHIFT 1  // x(2^shift)

static const char *TAG = "BT_AUDIO";
static const char *TARGET_NAME = "Tribit XSound Go";

static bool already_connecting = false;
static volatile bool a2dp_streaming = false;
static RingbufHandle_t audio_rb = NULL;
static i2s_chan_handle_t i2s_rx_handle = NULL;
static uint32_t audio_cb_calls = 0;
static uint32_t audio_cb_underflows = 0;

static inline int16_t sat16(int32_t x)
{
    if (x > 32767) return 32767;
    if (x < -32768) return -32768;
    return (int16_t)x;
}

static inline void apply_gain(int16_t *samples, int sample_count)
{
    if (AUDIO_GAIN_SHIFT <= 0) return;
    for (int i = 0; i < sample_count; i++) {
        samples[i] = sat16(((int32_t)samples[i]) << AUDIO_GAIN_SHIFT);
    }
}

// Minimal underflow telemetry (uses printf so it still works with ESP_LOG disabled).
// Prints at most once per second, and only when the counter changed.
#define UNDERFLOW_BRIEF_PRINT 1
static const char *UF_TAG = "UF";

static int32_t audio_data_cb(uint8_t *data, int32_t len)
{
    memset(data, 0, len); //incase its empty so silence

    size_t item_size;
    // get audio data from ring buffer, block if empty
    uint8_t *item = (uint8_t *)xRingbufferReceiveUpTo(audio_rb, &item_size, 0, len);

    if (item) {
        size_t bytes_to_copy = item_size < (size_t)len ? item_size : (size_t)len;
        memcpy(data, item, bytes_to_copy);
        if (bytes_to_copy < (size_t)len) {
            audio_cb_underflows++;
        }
        vRingbufferReturnItem(audio_rb, item);
    } else {
        audio_cb_underflows++;
    }

    audio_cb_calls++;
#if UNDERFLOW_BRIEF_PRINT
    {
        static int64_t last_print_us = 0;
        static uint32_t last_uf = 0;
        int64_t now_us = esp_timer_get_time();
        if ((now_us - last_print_us) >= 1000000) {
            uint32_t uf = audio_cb_underflows;
            if (uf != last_uf) {
                // Example: I (123456) UF: 1234
                ESP_LOGI(UF_TAG, "%lu", (unsigned long)uf);
                last_uf = uf;
            }
            last_print_us = now_us;
        }
    }
#endif

    return len;
}

static void i2s_pcm_rx_init(void)
{
    // FPGA is I2S clock master, ESP32 receives as slave.
    i2s_chan_config_t chan_cfg = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_0, I2S_ROLE_SLAVE);
    chan_cfg.dma_desc_num = 8;
    chan_cfg.dma_frame_num = CHUNK_SAMPLES;

    ESP_ERROR_CHECK(i2s_new_channel(&chan_cfg, NULL, &i2s_rx_handle));

    // ESP-IDF slot default config macros expand to `{ ... }` initializers.
    // Wrap them as compound literals so they can be assigned.
    i2s_std_slot_config_t slot_cfg;
    if (I2S_USE_MSB_FORMAT) {
        slot_cfg = (i2s_std_slot_config_t)I2S_STD_MSB_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_STEREO);
    } else {
        slot_cfg = (i2s_std_slot_config_t)I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_STEREO);
    }

    slot_cfg.slot_bit_width = I2S_RX_SLOT_BITS_32 ? I2S_SLOT_BIT_WIDTH_32BIT : I2S_SLOT_BIT_WIDTH_16BIT;

    i2s_std_config_t i2s_rx_cfg = {
        .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(SAMPLE_RATE),
        .slot_cfg = slot_cfg,
        .gpio_cfg = {
            .mclk = I2S_GPIO_UNUSED,
            .bclk = I2S_BCLK_GPIO,
            .ws = I2S_WS_GPIO,
            .dout = I2S_GPIO_UNUSED,
            .din = I2S_DIN_GPIO,
            .invert_flags = {
                .mclk_inv = false,
                .bclk_inv = I2S_BCLK_INVERT,
                .ws_inv = I2S_WS_INVERT,
            },
        },
    };

    ESP_ERROR_CHECK(i2s_channel_init_std_mode(i2s_rx_handle, &i2s_rx_cfg));
    ESP_ERROR_CHECK(i2s_channel_enable(i2s_rx_handle));
    
    // Configure GPIO 13 (LED) as output to mirror I2S DIN
    gpio_config_t io_conf = {
        .pin_bit_mask = (1ULL << GPIO_NUM_13),
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = 0,
        .pull_down_en = 0,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&io_conf));
    gpio_set_level(GPIO_NUM_13, 1);  // Set LED on by default for testing
}

static void i2s_pcm_rx_task(void *arg)
{
    int16_t stereo[CHUNK_SAMPLES * 2];
    int16_t stereo_raw_16[CHUNK_SAMPLES * 2];
    int32_t stereo_raw_32[CHUNK_SAMPLES * 2];
    size_t bytes_read = 0;
    uint32_t block_count = 0;
    uint32_t dropped_chunks = 0;
    uint32_t timeout_count = 0;
    uint32_t read_errors = 0;

    while (1) {
        // Only queue audio while an A2DP stream is active.
        if (!a2dp_streaming) {
            vTaskDelay(pdMS_TO_TICKS(20));
            continue;
        }

        void *rx_buf = I2S_RX_SLOT_BITS_32 ? (void *)stereo_raw_32 : (void *)stereo_raw_16;
        size_t rx_buf_bytes = I2S_RX_SLOT_BITS_32 ? sizeof(stereo_raw_32) : sizeof(stereo_raw_16);
        esp_err_t err = i2s_channel_read(i2s_rx_handle, rx_buf, rx_buf_bytes, &bytes_read, pdMS_TO_TICKS(1000));
        if (err != ESP_OK) {
            timeout_count++;
            read_errors++;
            if ((timeout_count % 50) == 0) {
                ESP_LOGW(TAG, "[I2S] Timeout #%u: %s (total errors: %u)", timeout_count, esp_err_to_name(err), read_errors);
            }
            continue;
        }

        // Mirror I2S DIN pin to LED
        gpio_set_level(GPIO_NUM_13, gpio_get_level(I2S_DIN_GPIO));

        if (bytes_read == 0) {
            ESP_LOGW(TAG, "[I2S] Got 0 bytes from I2S");
            continue;
        }

        bool do_log = (I2S_LOG_EVERY_N_BLOCKS > 0) && ((block_count % (uint32_t)I2S_LOG_EVERY_N_BLOCKS) == 0U);
        if (do_log) {
            int samples_to_log = I2S_RX_SLOT_BITS_32 ? (int)(bytes_read / sizeof(int32_t)) : (int)(bytes_read / sizeof(int16_t));
            if (samples_to_log > 16) {
                samples_to_log = 16;
            }
            if (I2S_RX_SLOT_BITS_32) {
                int pairs_to_log = samples_to_log / 2;
                for (int p = 0; p < pairs_to_log; p++) {
                    int idxL = 2 * p;
                    int idxR = 2 * p + 1;
                    ESP_LOGI(TAG, "raw32 L[%d]=%ld/0x%08lx  R[%d]=%ld/0x%08lx",
                             p,
                             (long)stereo_raw_32[idxL], (unsigned long)stereo_raw_32[idxL],
                             p,
                             (long)stereo_raw_32[idxR], (unsigned long)stereo_raw_32[idxR]);
                }
            } else {
                int pairs_to_log = samples_to_log / 2;
                for (int p = 0; p < pairs_to_log; p++) {
                    int idxL = 2 * p;
                    int idxR = 2 * p + 1;
                    ESP_LOGI(TAG, "raw16 L[%d]=%d/0x%04x  R[%d]=%d/0x%04x",
                             p,
                             stereo_raw_16[idxL], (uint16_t)stereo_raw_16[idxL],
                             p,
                             stereo_raw_16[idxR], (uint16_t)stereo_raw_16[idxR]);
                }
            }
        }

        // Convert whatever we received into interleaved signed 16-bit stereo PCM for A2DP.
        // If the RX uses 32-bit slots, audio is often in the upper bits (common on many I2S peripherals).
        if (I2S_RX_SLOT_BITS_32) {
            int sample_pairs = (int)(bytes_read / (sizeof(int32_t) * 2));
            if (sample_pairs > CHUNK_SAMPLES) {
                sample_pairs = CHUNK_SAMPLES;
            }
            for (int i = 0; i < sample_pairs * 2; i++) {
                int32_t v = stereo_raw_32[i];
                if (I2S_RX_SHIFT_RIGHT > 0) {
                    v >>= I2S_RX_SHIFT_RIGHT;
                }
                stereo[i] = (int16_t)(v >> 16);
            }
            bytes_read = (size_t)(sample_pairs * 2 * sizeof(int16_t));
        } else {
            int samples = (int)(bytes_read / sizeof(int16_t));
            if (samples > (CHUNK_SAMPLES * 2)) {
                samples = CHUNK_SAMPLES * 2;
            }
            memcpy(stereo, stereo_raw_16, (size_t)samples * sizeof(int16_t));
            bytes_read = (size_t)samples * sizeof(int16_t);
        }

        // Apply output gain before enqueuing to Bluetooth.
        apply_gain(stereo, (int)(bytes_read / sizeof(int16_t)));

        // Log the exact 16-bit PCM words that will be sent to A2DP.
        // This is the ground truth to compare against "what the FPGA sent".
        if (do_log) {
            int samples_to_log = (int)(bytes_read / sizeof(int16_t));
            if (samples_to_log > 16) {
                samples_to_log = 16;
            }
            int pairs_to_log = samples_to_log / 2;
            for (int p = 0; p < pairs_to_log; p++) {
                int idxL = 2 * p;
                int idxR = 2 * p + 1;
                ESP_LOGI(TAG, "pcm16 L[%d]=%d/0x%04x  R[%d]=%d/0x%04x",
                         p,
                         stereo[idxL], (uint16_t)stereo[idxL],
                         p,
                         stereo[idxR], (uint16_t)stereo[idxR]);
            }
        }

        size_t out_bytes = bytes_read;
        if (out_bytes > 0) {
            if (xRingbufferSend(audio_rb, stereo, out_bytes, pdMS_TO_TICKS(100)) != pdTRUE) {
                dropped_chunks++;
                if ((dropped_chunks % 10U) == 0U) {
                    ESP_LOGW(TAG, "Audio ring buffer full, dropped_chunks=%u, last_drop=%u bytes",
                             (unsigned)dropped_chunks, (unsigned)out_bytes);
                }
            }
        }

        block_count++;
        if ((block_count % 100U) == 0U) {
            size_t free_bytes = xRingbufferGetCurFreeSize(audio_rb);
            ESP_LOGI(TAG, "[I2S] RX blocks=%u, read_bytes=%u, ringbuf_free=%u, errors=%u", 
                     (unsigned)block_count, (unsigned)bytes_read, (unsigned)free_bytes, (unsigned)read_errors);
        }
    }
}

static void test_tone_task(void *arg)
{
    int16_t stereo[CHUNK_SAMPLES * 2];
    uint32_t block_count = 0;
    uint32_t dropped_chunks = 0;
    float phase = 0.0f;
    const float two_pi = 2.0f * 3.14159265358979323846f;
    const float phase_step = two_pi * (TEST_TONE_FREQ_HZ / (float)SAMPLE_RATE);
    const float amp = TEST_TONE_AMPLITUDE * 32767.0f;

    while (1) {
        if (!a2dp_streaming) {
            vTaskDelay(pdMS_TO_TICKS(20));
            continue;
        }

        for (int i = 0; i < CHUNK_SAMPLES; i++) {
            int16_t sample = (int16_t)(sinf(phase) * amp);
            stereo[2 * i] = sample;
            stereo[2 * i + 1] = sample;

            phase += phase_step;
            if (phase >= two_pi) {
                phase -= two_pi;
            }
        }

        apply_gain(stereo, CHUNK_SAMPLES * 2);

        if (xRingbufferSend(audio_rb, stereo, CHUNK_BYTES, pdMS_TO_TICKS(100)) != pdTRUE) {
            dropped_chunks++;
            if ((dropped_chunks % 10U) == 0U) {
                ESP_LOGW(TAG, "Tone ring buffer full, dropped_chunks=%u, last_drop=%u bytes",
                         (unsigned)dropped_chunks, (unsigned)CHUNK_BYTES);
            }
        }

        block_count++;
        if ((block_count % 200U) == 0U) {
            size_t free_bytes = xRingbufferGetCurFreeSize(audio_rb);
            ESP_LOGI(TAG, "Tone blocks=%u, ringbuf_free=%u", (unsigned)block_count, (unsigned)free_bytes);
        }
    }
}

static void csv_data_task(void *arg)
{
    int16_t stereo[CHUNK_SAMPLES * 2];
    uint32_t sample_index = 0;
    uint32_t block_count = 0;
    uint32_t dropped_chunks = 0;

    ESP_LOGI(TAG, "CSV data task started, total samples: %d", csv_audio_samples_count);

    while (1) {
        if (!a2dp_streaming) {
            vTaskDelay(pdMS_TO_TICKS(20));
            continue;
        }

        // Fill stereo buffer from CSV data, looping if we reach the end
        for (int i = 0; i < CHUNK_SAMPLES; i++) {
            int16_t mono_sample = csv_audio_samples[sample_index % csv_audio_samples_count];
            stereo[2 * i] = mono_sample;
            stereo[2 * i + 1] = mono_sample;
            sample_index++;
        }

        apply_gain(stereo, CHUNK_SAMPLES * 2);

        if (xRingbufferSend(audio_rb, stereo, CHUNK_BYTES, pdMS_TO_TICKS(100)) != pdTRUE) {
            dropped_chunks++;
            if ((dropped_chunks % 10U) == 0U) {
                ESP_LOGW(TAG, "CSV ring buffer full, dropped_chunks=%u, last_drop=%u bytes",
                         (unsigned)dropped_chunks, (unsigned)CHUNK_BYTES);
            }
        }

        block_count++;
        if ((block_count % 200U) == 0U) {
            size_t free_bytes = xRingbufferGetCurFreeSize(audio_rb);
            ESP_LOGI(TAG, "CSV blocks=%u, ringbuf_free=%u, sample_idx=%u", 
                     (unsigned)block_count, (unsigned)free_bytes, (unsigned)sample_index);
        }
    }
}

static void a2dp_cb(esp_a2d_cb_event_t event, esp_a2d_cb_param_t *param)
{
    if (event == ESP_A2D_CONNECTION_STATE_EVT) {
        switch (param->conn_stat.state) {
        case ESP_A2D_CONNECTION_STATE_CONNECTED:
            ESP_LOGI(TAG, "A2DP connected, requesting stream start");
            ESP_ERROR_CHECK(esp_a2d_media_ctrl(ESP_A2D_MEDIA_CTRL_START));
            break;
        case ESP_A2D_CONNECTION_STATE_DISCONNECTED:
            a2dp_streaming = false;
            already_connecting = false;
            vRingbufferReset(audio_rb);
            ESP_LOGW(TAG, "A2DP disconnected, restarting discovery");
            ESP_ERROR_CHECK(esp_bt_gap_start_discovery(ESP_BT_INQ_MODE_GENERAL_INQUIRY, 10, 0));
            break;
        default:
            break;
        }
    }

    if (event == ESP_A2D_AUDIO_STATE_EVT) {
        if (param->audio_stat.state == ESP_A2D_AUDIO_STATE_STARTED) {
            a2dp_streaming = true;
            ESP_LOGI(TAG, "A2DP audio started");
        } else {
            a2dp_streaming = false;
            vRingbufferReset(audio_rb);
            ESP_LOGI(TAG, "A2DP audio stopped/suspended");
        }
    }
}

static void gap_cb(esp_bt_gap_cb_event_t event, esp_bt_gap_cb_param_t *param)
{
    if (event == ESP_BT_GAP_DISC_RES_EVT && !already_connecting) {
        uint8_t *name = NULL;
        uint8_t len = 0;

        // Find device name
        for (int i = 0; i < param->disc_res.num_prop; i++) {
            if (param->disc_res.prop[i].type == ESP_BT_GAP_DEV_PROP_EIR) {
                name = esp_bt_gap_resolve_eir_data(
                    (uint8_t *)param->disc_res.prop[i].val,
                    ESP_BT_EIR_TYPE_CMPL_LOCAL_NAME,
                    &len
                );
                break;
            }
        }

        if (!name) {
            return;
        }

        if (strlen(TARGET_NAME) == len && strncmp((char *)name, TARGET_NAME, len) == 0) {
            already_connecting = true;
            esp_bt_gap_cancel_discovery();
            esp_a2d_source_connect(param->disc_res.bda);
        }
    }

    // Restart discovery if it stopped and not connected
    if (event == ESP_BT_GAP_DISC_STATE_CHANGED_EVT) {
        if (param->disc_st_chg.state == ESP_BT_GAP_DISCOVERY_STOPPED && !already_connecting) {
            ESP_LOGI(TAG, "Discovery stopped, restarting...");
            esp_bt_gap_start_discovery(ESP_BT_INQ_MODE_GENERAL_INQUIRY, 10, 0);
        }
    }
}

void bluetooth_stack_init(void)
{
    // Bluetooth initialization stuff (I think), boilerplate from esp-idf examples
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);

    // Initialize the Bluetooth controller with default settings (follow menuconfig stuff)
    esp_bt_controller_config_t bt_cfg = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_bt_controller_init(&bt_cfg));
    ESP_ERROR_CHECK(esp_bt_controller_enable(ESP_BT_MODE_CLASSIC_BT));
    ESP_ERROR_CHECK(esp_bluedroid_init());
    ESP_ERROR_CHECK(esp_bluedroid_enable());

    // called when classic bluetooth events happen
    // find the target device and connect to it when found
    ESP_ERROR_CHECK(esp_bt_gap_register_callback(gap_cb)); 

    // called when a2dp events happen
    // start audio when connected
    ESP_ERROR_CHECK(esp_a2d_register_callback(a2dp_cb)); 

    // initialize A2DP source role (we send audio files not receive)
    ESP_ERROR_CHECK(esp_a2d_source_init());

     // called when audio data is needed, pulls from buffer
    ESP_ERROR_CHECK(esp_a2d_source_register_data_callback(audio_data_cb));

    // start discovery (event-driven, not in a loop)
    ESP_ERROR_CHECK(esp_bt_gap_start_discovery(ESP_BT_INQ_MODE_GENERAL_INQUIRY, 10, 0));
}

void app_main(void)
{
    // Disable all ESP-IDF logging to avoid starving real-time audio tasks.
    esp_log_level_set("*", ESP_LOG_NONE);
    // Re-enable only the underflow counter log.
    esp_log_level_set(UF_TAG, ESP_LOG_INFO);

    const char *audio_src_names[] = {"FPGA I2S PCM", "Test Tone", "CSV Hardware Data"};
    ESP_LOGI(TAG, "=====================================");
    ESP_LOGI(TAG, "Audio source: %s", audio_src_names[AUDIO_SOURCE]);
    ESP_LOGI(TAG, "Sample rate: %d Hz", SAMPLE_RATE);
    
    if (AUDIO_SOURCE == AUDIO_SRC_TEST_TONE) {
        ESP_LOGI(TAG, "Test tone frequency: %.1f Hz", TEST_TONE_FREQ_HZ);
    } else if (AUDIO_SOURCE == AUDIO_SRC_CSV_DATA) {
        ESP_LOGI(TAG, "CSV data: %d samples, duration ~%.2f seconds", 
                 csv_audio_samples_count, csv_audio_samples_count / 44100.0f);
    } else {
        ESP_LOGI(TAG, "I2S pins BCLK=%d WS=%d DIN=%d", I2S_BCLK_GPIO, I2S_WS_GPIO, I2S_DIN_GPIO);
        ESP_LOGI(TAG, "I2S mode: SLAVE, STEREO, data=16b, fmt=%s, slot=%db, bclk_inv=%d ws_inv=%d shift=%d",
                 I2S_USE_MSB_FORMAT ? "MSB" : "Philips",
                 I2S_RX_SLOT_BITS_32 ? 32 : 16,
                 (int)I2S_BCLK_INVERT,
                 (int)I2S_WS_INVERT,
                 (int)I2S_RX_SHIFT_RIGHT);
    }
    ESP_LOGI(TAG, "=====================================");

    // make ring buffer
    audio_rb = xRingbufferCreate(RINGBUF_SIZE, RINGBUF_TYPE_BYTEBUF);
    if (!audio_rb) {
        ESP_LOGE(TAG, "Failed to create ring buffer");
        return;
    }

    if (AUDIO_SOURCE == AUDIO_SRC_FPGA_I2S_PCM) {
        // Initialize standard I2S RX on I2S0 and collect PCM from FPGA stream.
        i2s_pcm_rx_init();

        // Feed Bluetooth ring buffer from I2S PCM RX.
        xTaskCreate(i2s_pcm_rx_task, "i2s_pcm_rx_task", 4096, NULL, 6, NULL);
    } else if (AUDIO_SOURCE == AUDIO_SRC_CSV_DATA) {
        // Feed Bluetooth ring buffer from embedded CSV hardware output data.
        xTaskCreate(csv_data_task, "csv_data_task", 4096, NULL, 6, NULL);
    } else {
        // Feed Bluetooth ring buffer from generated sine tone.
        xTaskCreate(test_tone_task, "tone_task", 4096, NULL, 6, NULL);
    }

    // initialize bluetooth
    bluetooth_stack_init();
}