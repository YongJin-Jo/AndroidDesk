#ifndef MTPBRIDGE_H
#define MTPBRIDGE_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint32_t object_id;
    uint32_t storage_id;
    uint64_t size;
    int is_directory;
    char *name;
} ADMTPItem;

typedef int (*ADMTPProgressCallback)(uint64_t sent, uint64_t total, void *context);

int ad_mtp_device_info(char **display_name, char **serial_number, char **error_message);
int ad_mtp_list(const char *remote_path, ADMTPItem **items, size_t *count, char **error_message);
int ad_mtp_list_children(uint32_t storage_id, uint32_t folder_id,
                         ADMTPItem **items, size_t *count, char **error_message);
int ad_mtp_upload(const char *local_path, const char *remote_directory,
                  ADMTPProgressCallback progress_callback, void *progress_context,
                  char **error_message);
int ad_mtp_download(uint32_t object_id, uint32_t storage_id, int is_directory,
                    const char *destination_path,
                    ADMTPProgressCallback progress_callback, void *progress_context,
                    char **error_message);

void ad_mtp_free_items(ADMTPItem *items, size_t count);
void ad_mtp_free_string(char *value);

#endif
