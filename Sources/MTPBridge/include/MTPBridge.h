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

typedef struct ADMTPConnection ADMTPConnection;
typedef int (*ADMTPProgressCallback)(uint64_t sent, uint64_t total, void *context);

ADMTPConnection *ad_mtp_connect(char **display_name, char **serial_number,
                                char **error_message);
void ad_mtp_disconnect(ADMTPConnection *connection);
void ad_mtp_invalidate_index(ADMTPConnection *connection);
int ad_mtp_refresh_index(ADMTPConnection *connection,
                         ADMTPItem **root_items, size_t *root_count,
                         char **error_message);
int ad_mtp_list(ADMTPConnection *connection, const char *remote_path,
                ADMTPItem **items, size_t *count, char **error_message);
int ad_mtp_list_children(ADMTPConnection *connection,
                         uint32_t storage_id, uint32_t folder_id,
                         ADMTPItem **items, size_t *count, char **error_message);
int ad_mtp_upload(ADMTPConnection *connection,
                  const char *local_path, const char *remote_directory,
                  ADMTPProgressCallback progress_callback, void *progress_context,
                  char **error_message);
int ad_mtp_upload_to_folder(ADMTPConnection *connection,
                            const char *local_path,
                            uint32_t storage_id, uint32_t folder_id,
                            ADMTPProgressCallback progress_callback,
                            void *progress_context, char **error_message);
int ad_mtp_download(ADMTPConnection *connection,
                    uint32_t object_id, uint32_t storage_id, int is_directory,
                    const char *destination_path,
                    ADMTPProgressCallback progress_callback, void *progress_context,
                    char **error_message);
int ad_mtp_create_folder(ADMTPConnection *connection,
                         const char *remote_directory, const char *name,
                         uint32_t *object_id, char **error_message);
int ad_mtp_create_folder_in_folder(ADMTPConnection *connection,
                                   uint32_t storage_id, uint32_t folder_id,
                                   const char *name, uint32_t *object_id,
                                   char **error_message);
int ad_mtp_rename_object(ADMTPConnection *connection,
                         uint32_t object_id, const char *name,
                         char **error_message);
int ad_mtp_delete_object(ADMTPConnection *connection,
                         uint32_t object_id, char **error_message);

void ad_mtp_free_items(ADMTPItem *items, size_t count);
void ad_mtp_free_string(char *value);

#endif
