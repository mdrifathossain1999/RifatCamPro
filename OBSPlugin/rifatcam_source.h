#pragma once

#include <obs.h>
#include <obs-module.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "ws2_32.lib")
using socket_t = SOCKET;
static constexpr socket_t RIFATCAM_SOCK_INVALID = INVALID_SOCKET;
#else
#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>
using socket_t = int;
static constexpr socket_t RIFATCAM_SOCK_INVALID = -1;
#endif

class RifatCamSource {
public:
    explicit RifatCamSource(obs_source_t *source);
    ~RifatCamSource();

    RifatCamSource(const RifatCamSource &) = delete;
    RifatCamSource &operator=(const RifatCamSource &) = delete;

    static const char *get_name(void *type_data);
    static void *create(obs_data_t *settings, obs_source_t *source);
    static void destroy(void *data);
    static uint32_t get_width(void *data);
    static uint32_t get_height(void *data);
    static void video_render(void *data, gs_effect_t *effect);
    static void video_tick(void *data, float seconds);
    static void update(void *data, obs_data_t *settings);
    static obs_properties_t *get_properties(void *data);

    void start();
    void stop();
    void load_settings(obs_data_t *settings);

private:
    bool connect_to_server();
    void close_socket();
    bool send_http_request();
    bool fill_buffer();
    bool parse_and_skip_http_headers();
    bool extract_next_jpeg(std::vector<uint8_t> &out_jpeg);
    bool decode_and_store_frame(const uint8_t *data, size_t size);
    void capture_thread_func();

    obs_source_t *m_source = nullptr;

    std::string m_ip_address;
    int m_port = 4747;
    std::string m_password;
    std::string m_stream_path = "/video";
    int m_target_fps = 30;
    bool m_auto_reconnect = true;
    int m_reconnect_delay_ms = 5000;

    std::atomic<bool> m_running{false};
    std::atomic<bool> m_stop_requested{false};
    std::atomic<bool> m_connected{false};

    socket_t m_socket = RIFATCAM_SOCK_INVALID;
    bool m_http_headers_parsed = false;

    std::thread m_capture_thread;

    std::mutex m_frame_mutex;
    std::vector<uint8_t> m_pending_pixels;
    uint32_t m_pending_width = 0;
    uint32_t m_pending_height = 0;
    bool m_frame_ready = false;

    gs_texture_t *m_texture = nullptr;
    uint32_t m_tex_w = 0;
    uint32_t m_tex_h = 0;

    std::vector<uint8_t> m_recv_buf;
    size_t m_recv_used = 0;

    float m_frame_interval = 1.0f / 30.0f;
    std::chrono::steady_clock::time_point m_last_frame_time;
};
