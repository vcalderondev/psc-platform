/* The smallest libretro core that "runs a game": a black 320x240 frame per retro_run,
 * any .bin file as content. For retroarch/test/get-status.sh; never shipped. */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

struct retro_system_info { const char *library_name, *library_version, *valid_extensions; bool need_fullpath, block_extract; };
struct retro_game_geometry { unsigned base_width, base_height, max_width, max_height; float aspect_ratio; };
struct retro_system_timing { double fps, sample_rate; };
struct retro_system_av_info { struct retro_game_geometry geometry; struct retro_system_timing timing; };
typedef void (*video_refresh_t)(const void *, unsigned, unsigned, size_t);
typedef void (*input_poll_t)(void);

static uint16_t frame[320 * 240];
static video_refresh_t video_cb;
static input_poll_t poll_cb;

unsigned retro_api_version(void) { return 1; }
void retro_init(void) { }
void retro_deinit(void) { }
void retro_set_environment(void *cb) { (void)cb; }
void retro_set_video_refresh(video_refresh_t cb) { video_cb = cb; }
void retro_set_audio_sample(void *cb) { (void)cb; }
void retro_set_audio_sample_batch(void *cb) { (void)cb; }
void retro_set_input_poll(input_poll_t cb) { poll_cb = cb; }
void retro_set_input_state(void *cb) { (void)cb; }
void retro_set_controller_port_device(unsigned port, unsigned device) { (void)port; (void)device; }
void retro_get_system_info(struct retro_system_info *info)
{
   memset(info, 0, sizeof(*info));
   info->library_name = "PSC Test Core"; info->library_version = "1"; info->valid_extensions = "bin";
   info->need_fullpath = true;
}
void retro_get_system_av_info(struct retro_system_av_info *info)
{
   memset(info, 0, sizeof(*info));
   info->geometry.base_width = info->geometry.max_width = 320;
   info->geometry.base_height = info->geometry.max_height = 240;
   info->geometry.aspect_ratio = 4.0f / 3.0f;
   info->timing.fps = 60.0; info->timing.sample_rate = 48000.0;
}
void retro_reset(void) { }
void retro_run(void) { if (poll_cb) poll_cb(); if (video_cb) video_cb(frame, 320, 240, 320 * sizeof(frame[0])); }
size_t retro_serialize_size(void) { return 0; }
bool retro_serialize(void *data, size_t size) { (void)data; (void)size; return false; }
bool retro_unserialize(const void *data, size_t size) { (void)data; (void)size; return false; }
void retro_cheat_reset(void) { }
void retro_cheat_set(unsigned index, bool enabled, const char *code) { (void)index; (void)enabled; (void)code; }
bool retro_load_game(const void *game) { (void)game; return true; }
bool retro_load_game_special(unsigned type, const void *info, size_t num) { (void)type; (void)info; (void)num; return false; }
void retro_unload_game(void) { }
unsigned retro_get_region(void) { return 0; }
void *retro_get_memory_data(unsigned id) { (void)id; return NULL; }
size_t retro_get_memory_size(unsigned id) { (void)id; return 0; }
