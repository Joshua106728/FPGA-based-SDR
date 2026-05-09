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
#define AUDIO_SOURCE AUDIO_SRC_CSV_DATA

#define TEST_TONE_FREQ_HZ 1000.0f
#define TEST_TONE_AMPLITUDE 0.20f

// Audio gain for CSV data amplification
#define AUDIO_GAIN 4.0f

// Standard I2S RX GPIOs: FPGA drives BCLK/WS/DIN into ESP32.
#define I2S_BCLK_GPIO GPIO_NUM_26
#define I2S_WS_GPIO GPIO_NUM_25
#define I2S_DIN_GPIO GPIO_NUM_34
#define I2S_BCLK_INVERT false
#define I2S_WS_INVERT false

#define I2S_USE_MSB_FORMAT false
#define I2S_RX_SLOT_BITS_32 false
#define I2S_RX_SHIFT_RIGHT 0

static const char *TAG = "BT_AUDIO";
static const char *TARGET_NAME = "Tribit XSound Go";

static bool already_connecting = false;
static volatile bool a2dp_streaming = false;
static RingbufHandle_t audio_rb = NULL;
static i2s_chan_handle_t i2s_rx_handle = NULL;
static TickType_t last_tx_log_tick = 0;

static int32_t audio_data_cb(uint8_t *data, int32_t len)
{
    memset(data, 0, len);

    size_t item_size;
    uint8_t *item = (uint8_t *)xRingbufferReceiveUpTo(audio_rb, &item_size, 0, len);

    if (item) {
        size_t bytes_to_copy = item_size < (size_t)len ? item_size : (size_t)len;

        TickType_t now = xTaskGetTickCount();
        if (last_tx_log_tick == 0 || now - last_tx_log_tick >= pdMS_TO_TICKS(1000)) {
            int frames = (int)(bytes_to_copy / (sizeof(int16_t) * 2));
            if (frames > 16) {
                frames = 16;
            }

            int16_t *stereo = (int16_t *)item;
            ESP_LOGI(TAG, "[BT TX] First %d stereo frames sent to Bluetooth (L/R):", frames);
            for (int i = 0; i < frames; i++) {
                int left = stereo[2 * i];
                int right = stereo[2 * i + 1];
                ESP_LOGI(TAG, "  [%02d] L=%6d R=%6d", i, left, right);
            }

            last_tx_log_tick = now;
        }

        memcpy(data, item, bytes_to_copy);
        vRingbufferReturnItem(audio_rb, item);
    }

    return len;
}

// Apply gain with saturation to prevent clipping
static inline int16_t apply_gain(int16_t sample) {
    int32_t amplified = (int32_t)(sample * AUDIO_GAIN);
    // Clamp to int16_t range [-32768, 32767]
    if (amplified > 32767) {
        return 32767;
    } else if (amplified < -32768) {
        return -32768;
    }
    return (int16_t)amplified;
}

static void i2s_pcm_rx_init(void)
{
    i2s_chan_config_t chan_cfg = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_0, I2S_ROLE_SLAVE);
    chan_cfg.dma_desc_num = 8;
    chan_cfg.dma_frame_num = CHUNK_SAMPLES;

    ESP_ERROR_CHECK(i2s_new_channel(&chan_cfg, NULL, &i2s_rx_handle));

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

    gpio_config_t io_conf = {
        .pin_bit_mask = (1ULL << GPIO_NUM_13),
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = 0,
        .pull_down_en = 0,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&io_conf));
    gpio_set_level(GPIO_NUM_13, 1);
}

static void i2s_pcm_rx_task(void *arg)
{
    int16_t stereo[CHUNK_SAMPLES * 2];
    int16_t stereo_raw_16[CHUNK_SAMPLES * 2];
    int32_t stereo_raw_32[CHUNK_SAMPLES * 2];
    size_t bytes_read = 0;
    TickType_t last_log_tick = xTaskGetTickCount();

    while (1) {
        if (!a2dp_streaming) {
            vTaskDelay(pdMS_TO_TICKS(20));
            continue;
        }

        void *rx_buf = I2S_RX_SLOT_BITS_32 ? (void *)stereo_raw_32 : (void *)stereo_raw_16;
        size_t rx_buf_bytes = I2S_RX_SLOT_BITS_32 ? sizeof(stereo_raw_32) : sizeof(stereo_raw_16);
        esp_err_t err = i2s_channel_read(i2s_rx_handle, rx_buf, rx_buf_bytes, &bytes_read, pdMS_TO_TICKS(1000));
        if (err != ESP_OK || bytes_read == 0) {
            continue;
        }

        gpio_set_level(GPIO_NUM_13, gpio_get_level(I2S_DIN_GPIO));

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

        if (bytes_read > 0) {
            (void)xRingbufferSend(audio_rb, stereo, bytes_read, pdMS_TO_TICKS(100));

            TickType_t now = xTaskGetTickCount();
            if (now - last_log_tick >= pdMS_TO_TICKS(1000)) {
                int frames = (int)(bytes_read / (sizeof(int16_t) * 2));
                if (frames > 16) {
                    frames = 16;
                }

                ESP_LOGI(TAG, "[I2S RX] First %d stereo frames (L/R):", frames);
                for (int i = 0; i < frames; i++) {
                    int left = stereo[2 * i];
                    int right = stereo[2 * i + 1];
                    ESP_LOGI(TAG, "  [%02d] L=%6d R=%6d", i, left, right);
                }

                last_log_tick = now;
            }
        }
    }
}

static void test_tone_task(void *arg)
{
    int16_t stereo[CHUNK_SAMPLES * 2];
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

        (void)xRingbufferSend(audio_rb, stereo, CHUNK_BYTES, pdMS_TO_TICKS(100));
    }
}

static void csv_data_task(void *arg)
{
    int16_t stereo[CHUNK_SAMPLES * 2];
    uint32_t sample_index = 0;

    while (1) {
        if (!a2dp_streaming) {
            vTaskDelay(pdMS_TO_TICKS(20));
            continue;
        }

        for (int i = 0; i < CHUNK_SAMPLES; i++) {
            int16_t mono_sample = csv_audio_samples[sample_index % csv_audio_samples_count];
            int16_t amplified = apply_gain(mono_sample);
            stereo[2 * i] = amplified;
            stereo[2 * i + 1] = amplified;
            sample_index++;
        }

        (void)xRingbufferSend(audio_rb, stereo, CHUNK_BYTES, pdMS_TO_TICKS(100));
    }
}

static void a2dp_cb(esp_a2d_cb_event_t event, esp_a2d_cb_param_t *param)
{
    if (event == ESP_A2D_CONNECTION_STATE_EVT) {
        switch (param->conn_stat.state) {
        case ESP_A2D_CONNECTION_STATE_CONNECTED:
            ESP_ERROR_CHECK(esp_a2d_media_ctrl(ESP_A2D_MEDIA_CTRL_START));
            break;
        case ESP_A2D_CONNECTION_STATE_DISCONNECTED:
            a2dp_streaming = false;
            already_connecting = false;
            vRingbufferReset(audio_rb);
            ESP_ERROR_CHECK(esp_bt_gap_start_discovery(ESP_BT_INQ_MODE_GENERAL_INQUIRY, 10, 0));
            break;
        default:
            break;
        }
    }

    if (event == ESP_A2D_AUDIO_STATE_EVT) {
        if (param->audio_stat.state == ESP_A2D_AUDIO_STATE_STARTED) {
            a2dp_streaming = true;
        } else {
            a2dp_streaming = false;
            vRingbufferReset(audio_rb);
        }
    }
}

static void gap_cb(esp_bt_gap_cb_event_t event, esp_bt_gap_cb_param_t *param)
{
    if (event == ESP_BT_GAP_DISC_RES_EVT && !already_connecting) {
        uint8_t *name = NULL;
        uint8_t len = 0;

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

    if (event == ESP_BT_GAP_DISC_STATE_CHANGED_EVT) {
        if (param->disc_st_chg.state == ESP_BT_GAP_DISCOVERY_STOPPED && !already_connecting) {
            esp_bt_gap_start_discovery(ESP_BT_INQ_MODE_GENERAL_INQUIRY, 10, 0);
        }
    }
}

void bluetooth_stack_init(void)
{
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);

    esp_bt_controller_config_t bt_cfg = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_bt_controller_init(&bt_cfg));
    ESP_ERROR_CHECK(esp_bt_controller_enable(ESP_BT_MODE_CLASSIC_BT));
    ESP_ERROR_CHECK(esp_bluedroid_init());
    ESP_ERROR_CHECK(esp_bluedroid_enable());

    ESP_ERROR_CHECK(esp_bt_gap_register_callback(gap_cb));
    ESP_ERROR_CHECK(esp_a2d_register_callback(a2dp_cb));
    ESP_ERROR_CHECK(esp_a2d_source_init());
    ESP_ERROR_CHECK(esp_a2d_source_register_data_callback(audio_data_cb));

    ESP_ERROR_CHECK(esp_bt_gap_start_discovery(ESP_BT_INQ_MODE_GENERAL_INQUIRY, 10, 0));
}

void app_main(void)
{
    audio_rb = xRingbufferCreate(RINGBUF_SIZE, RINGBUF_TYPE_BYTEBUF);
    if (!audio_rb) {
        ESP_LOGE(TAG, "Failed to create ring buffer");
        return;
    }

    if (AUDIO_SOURCE == AUDIO_SRC_FPGA_I2S_PCM) {
        i2s_pcm_rx_init();
        xTaskCreate(i2s_pcm_rx_task, "i2s_pcm_rx_task", 4096, NULL, 6, NULL);
    } else if (AUDIO_SOURCE == AUDIO_SRC_CSV_DATA) {
        xTaskCreate(csv_data_task, "csv_data_task", 4096, NULL, 6, NULL);
    } else {
        xTaskCreate(test_tone_task, "tone_task", 4096, NULL, 6, NULL);
    }

    bluetooth_stack_init();
}
