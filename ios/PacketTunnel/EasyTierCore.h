#ifndef EASYTIER_PRO_CORE_H
#define EASYTIER_PRO_CORE_H
#include <stdbool.h>
#include <stdint.h>

// The C ABI comes from the pinned easytier-ffi inside libeasytier_ios.a.
// Callback strings are borrowed and must be copied before returning.
typedef void (*EasyTierConfigCallback)(const char *event, void *context);
int start_config_server_client(const char *url, const char *hostname,
                               const char *machine_id, bool secure_mode,
                               EasyTierConfigCallback callback, void *context);
int stop_config_server_client(void);
int is_config_server_client_connected(void);
int set_tun_fd(const char *instance_name, int fd);
int retain_network_instance(const char **instance_names, uintptr_t length);
void get_error_msg(const char **message);
void free_string(const char *value);
char *easytier_ios_collect_network_infos(int max_length);
char *easytier_ios_call_json_rpc(const char *service_name, const char *method_name,
                                const char *payload_json);
char *easytier_ios_tun_state(const char *instance_name);
char *easytier_ios_last_error(void);
void easytier_ios_free_string(char *value);
int easytier_ios_configure_diagnostic_logging(const char *directory, int enabled);
int easytier_ios_flush_diagnostic_logging(void);
#endif
