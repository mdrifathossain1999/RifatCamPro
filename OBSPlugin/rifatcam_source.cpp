#include "rifatcam_source.h"

#include <obs-module.h>

#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

#include <algorithm>
#include <cstring>
#include <sstream>

#ifdef _WIN32
static void platform_sock_init() {
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
}
static void platform_sock_cleanup() { WSACleanup(); }
static void close_socket_fd(socket_t s) {
    if (s != RIFATCAM_SOCK_INVALID)
        closesocket(s);
}
static int last_sock_error() { return WSAGetLastError(); }
static bool is_would_block(int e) {
    return e == WSAEWOULDBLOCK || e == WSAETIMEDOUT;
}
static constexpr int SOCK_ERR_CONN_REFUSED = WSAECONNREFUSED;
#else
static void platform_sock_init() {}
static void platform_sock_cleanup() {}
static void close_socket_fd(socket_t s) {
    if (s >= 0)
        close(s);
}
static int last_sock_error() { return errno; }
static bool is_would_block(int e) {
    return e == EAGAIN || e == EWOULDBLOCK;
}
static constexpr int SOCK_ERR_CONN_REFUSED = ECONNREFUSED;
#endif

static constexpr size_t RECV_BUF_INITIAL = 256 * 1024;
static constexpr size_t RECV_BUF_MAX = 8 * 1024 * 1024;
static constexpr int CONNECT_TIMEOUT_MS = 8000;
static constexpr int RECV_TIMEOUT_MS = 15000;

RifatCamSource::RifatCamSource(obs_source_t *source) : m_source(source) {
    m_recv_buf.resize(RECV_BUF_INITIAL);
    m_recv_used = 0;
    platform_sock_init();
}

RifatCamSource::~RifatCamSource() {
    stop();
    platform_sock_cleanup();
}

void RifatCamSource::load_settings(obs_data_t *settings) {
    if (!settings) {
        m_ip_address = "192.168.1.100";
        m_port = 4747;
        m_password.clear();
        m_stream_path = "/video";
        m_target_fps = 30;
        m_auto_reconnect = true;
        m_reconnect_delay_ms = 5000;
        m_frame_interval = 1.0f / 30.0f;
        return;
    }

    const char *ip = obs_data_get_string(settings, "ip_address");
    m_ip_address = (ip && ip[0]) ? ip : "192.168.1.100";

    m_port = static_cast<int>(obs_data_get_int(settings, "port"));
    if (m_port < 1 || m_port > 65535)
        m_port = 4747;

    const char *pwd = obs_data_get_string(settings, "password");
    m_password = pwd ? pwd : "";

    const char *path = obs_data_get_string(settings, "stream_path");
    m_stream_path = (path && path[0]) ? path : "/video";

    m_target_fps = static_cast<int>(obs_data_get_int(settings, "target_fps"));
    if (m_target_fps < 1)
        m_target_fps = 30;
    if (m_target_fps > 120)
        m_target_fps = 120;
    m_frame_interval = 1.0f / static_cast<float>(m_target_fps);

    m_auto_reconnect = obs_data_get_bool(settings, "auto_reconnect");

    m_reconnect_delay_ms =
        static_cast<int>(obs_data_get_int(settings, "reconnect_delay")) * 1000;
    if (m_reconnect_delay_ms < 1000)
        m_reconnect_delay_ms = 1000;
    if (m_reconnect_delay_ms > 60000)
        m_reconnect_delay_ms = 60000;
}

const char *RifatCamSource::get_name(void *) {
    return "RifatCam Pro";
}

void *RifatCamSource::create(obs_data_t *settings, obs_source_t *source) {
    auto *self = new RifatCamSource(source);
    self->load_settings(settings);
    self->start();
    return self;
}

void RifatCamSource::destroy(void *data) {
    delete static_cast<RifatCamSource *>(data);
}

uint32_t RifatCamSource::get_width(void *data) {
    auto *self = static_cast<RifatCamSource *>(data);
    std::lock_guard<std::mutex> lock(self->m_frame_mutex);
    if (self->m_tex_w > 0)
        return self->m_tex_w;
    return self->m_pending_width > 0 ? self->m_pending_width : 1920;
}

uint32_t RifatCamSource::get_height(void *data) {
    auto *self = static_cast<RifatCamSource *>(data);
    std::lock_guard<std::mutex> lock(self->m_frame_mutex);
    if (self->m_tex_h > 0)
        return self->m_tex_h;
    return self->m_pending_height > 0 ? self->m_pending_height : 1080;
}

void RifatCamSource::video_render(void *data, gs_effect_t *) {
    auto *self = static_cast<RifatCamSource *>(data);
    if (!self->m_texture)
        return;
    obs_source_draw(self->m_texture, 0, 0, 0, 0, false);
}

void RifatCamSource::video_tick(void *data, float) {
    auto *self = static_cast<RifatCamSource *>(data);
    std::lock_guard<std::mutex> lock(self->m_frame_mutex);

    if (!self->m_frame_ready)
        return;
    if (self->m_pending_width == 0 || self->m_pending_height == 0)
        return;

    if (self->m_texture) {
        if (self->m_tex_w != self->m_pending_width ||
            self->m_tex_h != self->m_pending_height) {
            gs_texture_destroy(self->m_texture);
            self->m_texture = nullptr;
        }
    }

    if (!self->m_texture) {
        self->m_texture = gs_texture_create(
            self->m_pending_width, self->m_pending_height, GS_BGRA, 1,
            nullptr, GS_DYNAMIC);
        self->m_tex_w = self->m_pending_width;
        self->m_tex_h = self->m_pending_height;
    }

    if (self->m_texture && !self->m_pending_pixels.empty()) {
        gs_texture_set_image(self->m_texture, self->m_pending_pixels.data(),
                             self->m_pending_width * 4, false);
    }

    self->m_frame_ready = false;
}

void RifatCamSource::update(void *data, obs_data_t *settings) {
    auto *self = static_cast<RifatCamSource *>(data);

    std::string old_ip = self->m_ip_address;
    int old_port = self->m_port;
    std::string old_pwd = self->m_password;
    std::string old_path = self->m_stream_path;

    self->load_settings(settings);

    bool conn_changed = self->m_ip_address != old_ip ||
                         self->m_port != old_port ||
                         self->m_password != old_pwd ||
                         self->m_stream_path != old_path;

    if (conn_changed && self->m_running) {
        self->stop();
        self->start();
    }
}

obs_properties_t *RifatCamSource::get_properties(void *) {
    obs_properties_t *props = obs_properties_create();

    obs_properties_add_text(props, "ip_address", "iPhone IP Address",
                            OBS_TEXT_DEFAULT);
    obs_properties_add_int(props, "port", "Port", 1, 65535, 1);
    obs_properties_add_text(props, "password", "Password", OBS_TEXT_PASSWORD);
    obs_properties_add_text(props, "stream_path", "Stream Path",
                            OBS_TEXT_DEFAULT);

    obs_properties_t *fps_list = obs_properties_add_list(
        props, "target_fps", "Target FPS", OBS_COMBO_TYPE_LIST,
        OBS_COMBO_FORMAT_INT);
    obs_properties_list_add_int(fps_list, "15", 15);
    obs_properties_list_add_int(fps_list, "24", 24);
    obs_properties_list_add_int(fps_list, "30", 30);
    obs_properties_list_add_int(fps_list, "60", 60);

    obs_properties_add_bool(props, "auto_reconnect", "Auto Reconnect");
    obs_properties_add_int(props, "reconnect_delay",
                           "Reconnect Delay (seconds)", 1, 60, 1);

    return props;
}

void RifatCamSource::start() {
    if (m_running)
        return;

    m_running = true;
    m_stop_requested = false;
    m_capture_thread = std::thread(&RifatCamSource::capture_thread_func, this);
    blog(LOG_INFO, "[RifatCam Pro] Capture started for %s:%d",
         m_ip_address.c_str(), m_port);
}

void RifatCamSource::stop() {
    if (!m_running)
        return;

    m_stop_requested = true;
    m_running = false;
    close_socket();

    if (m_capture_thread.joinable())
        m_capture_thread.join();

    {
        std::lock_guard<std::mutex> lock(m_frame_mutex);
        if (m_texture) {
            gs_texture_destroy(m_texture);
            m_texture = nullptr;
        }
        m_tex_w = 0;
        m_tex_h = 0;
        m_frame_ready = false;
        m_pending_pixels.clear();
        m_pending_width = 0;
        m_pending_height = 0;
    }

    m_http_headers_parsed = false;
    m_recv_used = 0;

    blog(LOG_INFO, "[RifatCam Pro] Capture stopped");
}

bool RifatCamSource::connect_to_server() {
    close_socket();

    m_socket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (m_socket == RIFATCAM_SOCK_INVALID) {
        blog(LOG_ERROR, "[RifatCam Pro] socket() failed: %d",
             last_sock_error());
        return false;
    }

#ifdef _WIN32
    DWORD recv_ms = static_cast<DWORD>(RECV_TIMEOUT_MS);
    DWORD send_ms = static_cast<DWORD>(CONNECT_TIMEOUT_MS);
#else
    struct timeval recv_tv {};
    recv_tv.tv_sec = RECV_TIMEOUT_MS / 1000;
    recv_tv.tv_usec = (RECV_TIMEOUT_MS % 1000) * 1000;
    struct timeval send_tv {};
    send_tv.tv_sec = CONNECT_TIMEOUT_MS / 1000;
    send_tv.tv_usec = (CONNECT_TIMEOUT_MS % 1000) * 1000;
#endif

#ifdef _WIN32
    setsockopt(m_socket, SOL_SOCKET, SO_RCVTIMEO,
               reinterpret_cast<const char *>(&recv_ms), sizeof(recv_ms));
    setsockopt(m_socket, SOL_SOCKET, SO_SNDTIMEO,
               reinterpret_cast<const char *>(&send_ms), sizeof(send_ms));
#else
    setsockopt(m_socket, SOL_SOCKET, SO_RCVTIMEO, &recv_tv, sizeof(recv_tv));
    setsockopt(m_socket, SOL_SOCKET, SO_SNDTIMEO, &send_tv, sizeof(send_tv));
#endif

    int flag = 1;
    setsockopt(m_socket, IPPROTO_TCP, TCP_NODELAY,
               reinterpret_cast<const char *>(&flag), sizeof(flag));

    struct addrinfo hints {};
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;

    std::string port_str = std::to_string(m_port);
    struct addrinfo *res = nullptr;
    int rc = getaddrinfo(m_ip_address.c_str(), port_str.c_str(), &hints, &res);
    if (rc != 0 || !res) {
        blog(LOG_ERROR, "[RifatCam Pro] getaddrinfo failed for %s",
             m_ip_address.c_str());
        close_socket();
        return false;
    }

    rc = ::connect(m_socket, res->ai_addr, static_cast<int>(res->ai_addrlen));
    freeaddrinfo(res);

    if (rc != 0) {
        int err = last_sock_error();
        blog(LOG_WARNING, "[RifatCam Pro] connect() failed: %d", err);
        close_socket();
        return false;
    }

    m_connected = true;
    m_recv_used = 0;
    m_http_headers_parsed = false;
    blog(LOG_INFO, "[RifatCam Pro] TCP connected to %s:%d",
         m_ip_address.c_str(), m_port);
    return true;
}

void RifatCamSource::close_socket() {
    if (m_socket != RIFATCAM_SOCK_INVALID) {
        close_socket_fd(m_socket);
        m_socket = RIFATCAM_SOCK_INVALID;
    }
    m_connected = false;
}

bool RifatCamSource::send_http_request() {
    std::ostringstream req;
    req << "GET " << m_stream_path << " HTTP/1.1\r\n";
    req << "Host: " << m_ip_address << ":" << m_port << "\r\n";
    req << "Connection: keep-alive\r\n";
    req << "Accept: multipart/x-mixed-replace, image/jpeg, */*\r\n";
    if (!m_password.empty()) {
        req << "X-RifatCam-Password: " << m_password << "\r\n";
    }
    req << "\r\n";

    std::string raw = req.str();
    const char *ptr = raw.c_str();
    size_t remaining = raw.size();

    while (remaining > 0) {
        int sent = static_cast<int>(
            send(m_socket, ptr, static_cast<int>(remaining), 0));
        if (sent <= 0) {
            blog(LOG_ERROR, "[RifatCam Pro] send() failed: %d",
                 last_sock_error());
            return false;
        }
        ptr += sent;
        remaining -= static_cast<size_t>(sent);
    }

    blog(LOG_INFO, "[RifatCam Pro] HTTP request sent");
    return true;
}

bool RifatCamSource::fill_buffer() {
    if (m_socket == RIFATCAM_SOCK_INVALID)
        return false;

    if (m_recv_used >= m_recv_buf.size()) {
        if (m_recv_buf.size() >= RECV_BUF_MAX) {
            blog(LOG_WARNING,
                 "[RifatCam Pro] Receive buffer full, resetting");
            m_recv_used = 0;
            return false;
        }
        m_recv_buf.resize(std::min(m_recv_buf.size() * 2, RECV_BUF_MAX));
    }

    size_t space = m_recv_buf.size() - m_recv_used;
    int got = static_cast<int>(
        recv(m_socket, reinterpret_cast<char *>(m_recv_buf.data() + m_recv_used),
             static_cast<int>(space), 0));

    if (got <= 0) {
        int err = last_sock_error();
        if (got == 0) {
            blog(LOG_WARNING, "[RifatCam Pro] Server closed connection");
        } else if (!is_would_block(err)) {
            blog(LOG_WARNING, "[RifatCam Pro] recv() error: %d", err);
        }
        return false;
    }

    m_recv_used += static_cast<size_t>(got);
    return true;
}

bool RifatCamSource::parse_and_skip_http_headers() {
    const char *buf = reinterpret_cast<const char *>(m_recv_buf.data());
    for (size_t i = 0; i + 3 < m_recv_used; i++) {
        if (buf[i] == '\r' && buf[i + 1] == '\n' && buf[i + 2] == '\r' &&
            buf[i + 3] == '\n') {

            size_t hdr_end = i + 4;

            std::string hdr(buf, hdr_end);
            blog(LOG_INFO, "[RifatCam Pro] Response:\n%s", hdr.c_str());

            size_t tail = m_recv_used - hdr_end;
            if (tail > 0) {
                memmove(m_recv_buf.data(), m_recv_buf.data() + hdr_end, tail);
            }
            m_recv_used = tail;
            m_http_headers_parsed = true;
            return true;
        }
    }
    return false;
}

bool RifatCamSource::extract_next_jpeg(std::vector<uint8_t> &out_jpeg) {
    size_t soi = 0;
    bool found_soi = false;

    for (size_t i = 0; i + 1 < m_recv_used; i++) {
        if (m_recv_buf[i] == 0xFF && m_recv_buf[i + 1] == 0xD8) {
            soi = i;
            found_soi = true;
            break;
        }
    }

    if (!found_soi)
        return false;

    for (size_t i = soi + 2; i + 1 < m_recv_used; i++) {
        if (m_recv_buf[i] == 0xFF && m_recv_buf[i + 1] == 0xD9) {
            size_t eoi_end = i + 2;
            out_jpeg.assign(m_recv_buf.begin() + soi,
                            m_recv_buf.begin() + eoi_end);

            size_t tail = m_recv_used - eoi_end;
            if (tail > 0) {
                memmove(m_recv_buf.data(), m_recv_buf.data() + eoi_end, tail);
            }
            m_recv_used = tail;
            return true;
        }
    }

    if (soi > 0) {
        m_recv_used -= soi;
        memmove(m_recv_buf.data(), m_recv_buf.data() + soi, m_recv_used);
    }

    return false;
}

bool RifatCamSource::decode_and_store_frame(const uint8_t *data, size_t size) {
    int w = 0, h = 0, comp = 0;
    unsigned char *px = stbi_load_from_memory(
        data, static_cast<int>(size), &w, &h, &comp, 4);

    if (!px || w <= 0 || h <= 0) {
        if (px)
            stbi_image_free(px);
        return false;
    }

    for (int i = 0; i < w * h * 4; i += 4) {
        unsigned char tmp = px[i];
        px[i] = px[i + 2];
        px[i + 2] = tmp;
    }

    {
        std::lock_guard<std::mutex> lock(m_frame_mutex);
        m_pending_pixels.assign(px, px + (static_cast<size_t>(w) * h * 4));
        m_pending_width = static_cast<uint32_t>(w);
        m_pending_height = static_cast<uint32_t>(h);
        m_frame_ready = true;
    }

    stbi_image_free(px);
    return true;
}

struct obs_source_info rifatcam_source_info = {
    .id = "rifatcam_source",
    .type = OBS_SOURCE_TYPE_INPUT,
    .output_flags = OBS_SOURCE_VIDEO,
    .get_name = RifatCamSource::get_name,
    .create = RifatCamSource::create,
    .destroy = RifatCamSource::destroy,
    .get_width = RifatCamSource::get_width,
    .get_height = RifatCamSource::get_height,
    .video_render = RifatCamSource::video_render,
    .video_tick = RifatCamSource::video_tick,
    .update = RifatCamSource::update,
    .get_properties = RifatCamSource::get_properties,
};

void RifatCamSource::capture_thread_func() {
    blog(LOG_INFO, "[RifatCam Pro] Thread running");

    while (m_running && !m_stop_requested) {
        if (!m_connected) {
            if (!connect_to_server()) {
                if (m_stop_requested)
                    break;
                if (m_auto_reconnect) {
                    int chunks = m_reconnect_delay_ms / 500;
                    for (int i = 0; i < chunks && !m_stop_requested; i++) {
                        std::this_thread::sleep_for(
                            std::chrono::milliseconds(500));
                    }
                    continue;
                }
                break;
            }

            if (!send_http_request()) {
                close_socket();
                if (m_stop_requested)
                    break;
                if (m_auto_reconnect) {
                    std::this_thread::sleep_for(
                        std::chrono::milliseconds(m_reconnect_delay_ms));
                    continue;
                }
                break;
            }
        }

        if (!fill_buffer()) {
            if (m_stop_requested)
                break;
            close_socket();
            if (m_auto_reconnect) {
                std::this_thread::sleep_for(
                    std::chrono::milliseconds(m_reconnect_delay_ms));
            }
            continue;
        }

        if (!m_http_headers_parsed) {
            if (!parse_and_skip_http_headers())
                continue;
        }

        std::vector<uint8_t> jpeg;
        if (extract_next_jpeg(jpeg)) {
            if (decode_and_store_frame(jpeg.data(), jpeg.size())) {
                auto now = std::chrono::steady_clock::now();
                float elapsed =
                    std::chrono::duration<float>(now - m_last_frame_time)
                        .count();

                if (elapsed < m_frame_interval) {
                    float remaining = m_frame_interval - elapsed;
                    auto sleep_ms =
                        std::chrono::milliseconds(
                            static_cast<int>(remaining * 1000.0f));
                    if (sleep_ms.count() > 0) {
                        std::this_thread::sleep_for(sleep_ms);
                    }
                }

                m_last_frame_time = std::chrono::steady_clock::now();
            }
        }
    }

    close_socket();
    blog(LOG_INFO, "[RifatCam Pro] Thread stopped");
}
