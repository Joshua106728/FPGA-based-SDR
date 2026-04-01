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

#define SAMPLE_RATE 44100
#define TONE_FREQ 440.0f
#define TONE_AMPLITUDE 8000.0f

#define CHANNELS 2
#define BYTES_PER_SAMPLE 2
#define FRAME_SIZE (CHANNELS * BYTES_PER_SAMPLE)

#define CHUNK_SAMPLES 256
#define CHUNK_BYTES (CHUNK_SAMPLES * FRAME_SIZE)
#define RINGBUF_SIZE (8 * 1024)

static const char *TAG = "BT_AUDIO";
static const char *TARGET_NAME = "WH-1000XM3";

static bool already_connecting = false;
static RingbufHandle_t audio_rb = NULL;
static float phase = 0.0f;

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

static void tone_task(void *arg)
{
    int16_t samples[CHUNK_SAMPLES * 2]; //cause stereo

    while (1) {
        for (int i = 0; i < CHUNK_SAMPLES; i++) {
            int16_t v = (int16_t)(sinf(phase) * TONE_AMPLITUDE);

            samples[2 * i] = v;
            samples[2 * i + 1] = v;

            phase += 2.0f * (float)M_PI * TONE_FREQ / SAMPLE_RATE;
            if (phase >= 2.0f * (float)M_PI) {
                phase -= 2.0f * (float)M_PI;
            }
        }

        // push to ring buffer, block if full
        xRingbufferSend(audio_rb, samples, sizeof(samples), portMAX_DELAY);
    }
}

static void a2dp_cb(esp_a2d_cb_event_t event, esp_a2d_cb_param_t *param)
{
    if (event == ESP_A2D_CONNECTION_STATE_EVT) {
        if (param->conn_stat.state == ESP_A2D_CONNECTION_STATE_CONNECTED) {
            ESP_LOGI(TAG, "Connected, starting audio...");
            esp_a2d_media_ctrl(ESP_A2D_MEDIA_CTRL_START);
        }
    }
}

static void gap_cb(esp_bt_gap_cb_event_t event, esp_bt_gap_cb_param_t *param)
{
    if (event != ESP_BT_GAP_DISC_RES_EVT || already_connecting) {
        return;
    }

    uint8_t *name = NULL;
    uint8_t len = 0;

    // Find devices name we can replace all this with just a MAC addr if we want to use a set speaker
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

    // start discovery
    ESP_ERROR_CHECK(esp_bt_gap_start_discovery(ESP_BT_INQ_MODE_GENERAL_INQUIRY, 10, 0));
}

void app_main(void)
{
    // make ring buffer
    audio_rb = xRingbufferCreate(RINGBUF_SIZE, RINGBUF_TYPE_BYTEBUF);
    if (!audio_rb) {
        ESP_LOGE(TAG, "Failed to create ring buffer");
        return;
    }

    // fill the buffer with stuff, to be replaced with FPGA generated data *****
    xTaskCreate(tone_task, "tone_task", 4096, NULL, 5, NULL);

    // initialize bluetooth
    bluetooth_stack_init();
}