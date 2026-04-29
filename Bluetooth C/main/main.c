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

#define SAMPLE_RATE 44100

#define CHANNELS 2
#define BYTES_PER_SAMPLE 2
#define FRAME_SIZE (CHANNELS * BYTES_PER_SAMPLE)

#define CHUNK_SAMPLES 256
#define CHUNK_BYTES (CHUNK_SAMPLES * FRAME_SIZE)
#define RINGBUF_SIZE (32 * 1024)

#define AUDIO_SRC_FPGA_I2S_PCM 0
#define AUDIO_SRC_TEST_TONE 1
#define AUDIO_SOURCE AUDIO_SRC_FPGA_I2S_PCM

#define TEST_TONE_FREQ_HZ 1000.0f
#define TEST_TONE_AMPLITUDE 0.20f

// Standard I2S RX GPIOs: FPGA drives BCLK/WS/DIN into ESP32.
#define I2S_BCLK_GPIO GPIO_NUM_26
#define I2S_WS_GPIO GPIO_NUM_25
#define I2S_DIN_GPIO GPIO_NUM_33

static const char *TAG = "BT_AUDIO";
static const char *TARGET_NAME = "Tribit XSound Go";

static bool already_connecting = false;
static volatile bool a2dp_streaming = false;
static RingbufHandle_t audio_rb = NULL;
static i2s_chan_handle_t i2s_rx_handle = NULL;

static int32_t audio_data_cb(uint8_t *data, int32_t len)
{
    memset(data, 0, len); //incase its empty so silence

    size_t item_size;
    // get audio data from ring buffer, block if empty
    uint8_t *item = (uint8_t *)xRingbufferReceiveUpTo(audio_rb, &item_size, 0, len);

    if (item) {
        memcpy(data, item, item_size);
        vRingbufferReturnItem(audio_rb, item);
    }

    return len;
}

static void i2s_pcm_rx_init(void)
{
    // FPGA is I2S clock master, ESP32 receives as slave.
    i2s_chan_config_t chan_cfg = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_0, I2S_ROLE_SLAVE);
    chan_cfg.dma_desc_num = 8;
    chan_cfg.dma_frame_num = CHUNK_SAMPLES;

    ESP_ERROR_CHECK(i2s_new_channel(&chan_cfg, NULL, &i2s_rx_handle));

    i2s_std_config_t i2s_rx_cfg = {
        .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(SAMPLE_RATE),
        .slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_MONO),
        .gpio_cfg = {
            .mclk = I2S_GPIO_UNUSED,
            .bclk = I2S_BCLK_GPIO,
            .ws = I2S_WS_GPIO,
            .dout = I2S_GPIO_UNUSED,
            .din = I2S_DIN_GPIO,
            .invert_flags = {
                .mclk_inv = false,
                .bclk_inv = false,
                .ws_inv = false,
            },
        },
    };

    ESP_ERROR_CHECK(i2s_channel_init_std_mode(i2s_rx_handle, &i2s_rx_cfg));
    ESP_ERROR_CHECK(i2s_channel_enable(i2s_rx_handle));
}

static void i2s_pcm_rx_task(void *arg)
{
    int16_t mono[CHUNK_SAMPLES];
    int16_t stereo[CHUNK_SAMPLES * 2];
    size_t bytes_read = 0;
    uint32_t block_count = 0;
    uint32_t dropped_chunks = 0;

    while (1) {
        // Only queue audio while an A2DP stream is active.
        if (!a2dp_streaming) {
            vTaskDelay(pdMS_TO_TICKS(20));
            continue;
        }

        esp_err_t err = i2s_channel_read(i2s_rx_handle, mono, sizeof(mono), &bytes_read, pdMS_TO_TICKS(1000));
        if (err != ESP_OK) {
            ESP_LOGW(TAG, "i2s_channel_read timeout/error: %s", esp_err_to_name(err));
            continue;
        }

        int pcm_samples = bytes_read / (int)sizeof(int16_t);
        for (int i = 0; i < pcm_samples; i++) {
            // Bluetooth sink expects stereo PCM. Duplicate mono sample to L/R.
            stereo[2 * i] = mono[i];
            stereo[2 * i + 1] = mono[i];
        }

        size_t out_bytes = (size_t)pcm_samples * FRAME_SIZE;
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
        if ((block_count % 200U) == 0U) {
            size_t free_bytes = xRingbufferGetCurFreeSize(audio_rb);
            ESP_LOGI(TAG, "I2S RX blocks=%u, ringbuf_free=%u", (unsigned)block_count, (unsigned)free_bytes);
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

        printf("%.*s: %02x:%02x:%02x:%02x:%02x:%02x\n",
            len, name,
            param->disc_res.bda[0], param->disc_res.bda[1], param->disc_res.bda[2],
            param->disc_res.bda[3], param->disc_res.bda[4], param->disc_res.bda[5]);

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
    ESP_LOGI(TAG, "Audio source: %s", AUDIO_SOURCE == AUDIO_SRC_TEST_TONE ? "test tone" : "FPGA I2S PCM");
    if (AUDIO_SOURCE == AUDIO_SRC_TEST_TONE) {
        ESP_LOGI(TAG, "Test tone frequency: %.1f Hz", TEST_TONE_FREQ_HZ);
    } else {
        ESP_LOGI(TAG, "I2S pins BCLK=%d WS=%d DIN=%d", I2S_BCLK_GPIO, I2S_WS_GPIO, I2S_DIN_GPIO);
    }

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
    } else {
        // Feed Bluetooth ring buffer from generated sine tone.
        xTaskCreate(test_tone_task, "tone_task", 4096, NULL, 6, NULL);
    }

    // initialize bluetooth
    bluetooth_stack_init();
}