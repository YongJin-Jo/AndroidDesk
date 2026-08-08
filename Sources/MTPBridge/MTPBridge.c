#include "MTPBridge.h"

#include "../CLibMTP/shim.h"

#include <dirent.h>
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

typedef struct {
    uint32_t storage_id;
    uint32_t folder_id;
    int is_root;
} ADMTPFolderLocation;

typedef struct {
    ADMTPProgressCallback callback;
    void *context;
} ADMTPProgressContext;

typedef struct ADMTPIndexedItem {
    uint32_t object_id;
    uint32_t parent_id;
    uint32_t storage_id;
    uint64_t size;
    int64_t modification_time;
    int is_directory;
    char *name;
    char *kind;
    struct ADMTPIndexedItem *next;
} ADMTPIndexedItem;

struct ADMTPConnection {
    LIBMTP_mtpdevice_t *device;
    ADMTPIndexedItem *index;
    int index_loaded;
};

static pthread_once_t ad_mtp_init_once = PTHREAD_ONCE_INIT;

static void ad_mtp_initialize(void) {
    LIBMTP_Init();
}

static void ad_mtp_set_error(char **error_message, const char *message) {
    if (error_message == NULL) {
        return;
    }
    free(*error_message);
    *error_message = strdup(message != NULL && message[0] != '\0'
                            ? message
                            : "MTP 작업에 실패했습니다.");
}

static void ad_mtp_set_device_error(LIBMTP_mtpdevice_t *device,
                                    char **error_message,
                                    const char *fallback) {
    LIBMTP_error_t *error = device == NULL ? NULL : LIBMTP_Get_Errorstack(device);
    if (error != NULL && error->error_text != NULL && error->error_text[0] != '\0') {
        ad_mtp_set_error(error_message, error->error_text);
    } else {
        ad_mtp_set_error(error_message, fallback);
    }
    if (device != NULL) {
        LIBMTP_Clear_Errorstack(device);
    }
}

static LIBMTP_mtpdevice_t *ad_mtp_open_device(char **error_message) {
    pthread_once(&ad_mtp_init_once, ad_mtp_initialize);
    LIBMTP_mtpdevice_t *device = LIBMTP_Get_First_Device();
    if (device == NULL) {
        ad_mtp_set_error(
            error_message,
            "MTP 기기를 찾지 못했습니다. 휴대폰 잠금을 해제하고 USB 연결 모드를 ‘파일 전송 / Android Auto’로 변경한 뒤 다시 시도하세요."
        );
    }
    return device;
}

static void ad_mtp_destroy_file_list(LIBMTP_file_t *file) {
    while (file != NULL) {
        LIBMTP_file_t *next = file->next;
        LIBMTP_destroy_file_t(file);
        file = next;
    }
}

static void ad_mtp_clear_index(ADMTPConnection *connection) {
    if (connection == NULL) {
        return;
    }
    ADMTPIndexedItem *item = connection->index;
    while (item != NULL) {
        ADMTPIndexedItem *next = item->next;
        free(item->name);
        free(item->kind);
        free(item);
        item = next;
    }
    connection->index = NULL;
    connection->index_loaded = 0;
}

static LIBMTP_mtpdevice_t *ad_mtp_connection_device(
    ADMTPConnection *connection, char **error_message
) {
    if (connection == NULL || connection->device == NULL) {
        ad_mtp_set_error(error_message, "MTP 연결이 열려 있지 않습니다.");
        return NULL;
    }
    return connection->device;
}

static int ad_mtp_report_progress(uint64_t sent, uint64_t total,
                                  void const * const data) {
    const ADMTPProgressContext *progress = data;
    if (progress == NULL || progress->callback == NULL) {
        return 0;
    }
    return progress->callback(sent, total, progress->context);
}

static int ad_mtp_transfer_cancelled(const ADMTPProgressContext *progress,
                                     char **error_message) {
    if (progress == NULL || progress->callback == NULL ||
        progress->callback(0, 0, progress->context) == 0) {
        return 0;
    }
    ad_mtp_set_error(error_message, "전송이 취소되었습니다.");
    return 1;
}

/*
 * libmtp documents 0xffffffff as the root parent identifier. Some Android
 * devices reject that value with PTP error 0x02ff and accept 0 instead.
 */
static LIBMTP_file_t *ad_mtp_get_files_and_folders(LIBMTP_mtpdevice_t *device,
                                                    uint32_t storage_id,
                                                    uint32_t parent_id) {
    LIBMTP_file_t *files = LIBMTP_Get_Files_And_Folders(
        device, storage_id, parent_id
    );
    if (files != NULL || parent_id != LIBMTP_FILES_AND_FOLDERS_ROOT) {
        return files;
    }

    LIBMTP_Clear_Errorstack(device);
    return LIBMTP_Get_Files_And_Folders(device, storage_id, 0);
}

static LIBMTP_folder_t *ad_mtp_get_folder_tree(LIBMTP_mtpdevice_t *device,
                                                uint32_t storage_id,
                                                char **error_message) {
    LIBMTP_folder_t *folders = LIBMTP_Get_Folder_List_For_Storage(
        device, storage_id
    );
    if (folders == NULL && LIBMTP_Get_Errorstack(device) != NULL) {
        ad_mtp_set_device_error(device, error_message,
                                "MTP 폴더 구조를 읽지 못했습니다.");
    }
    return folders;
}

static LIBMTP_folder_t *ad_mtp_find_folder(LIBMTP_folder_t *folders,
                                            const char *name) {
    for (LIBMTP_folder_t *folder = folders; folder != NULL;
         folder = folder->sibling) {
        if (folder->name != NULL && strcmp(folder->name, name) == 0) {
            return folder;
        }
    }
    return NULL;
}

static uint32_t ad_mtp_primary_storage(LIBMTP_mtpdevice_t *device,
                                       char **error_message) {
    if (LIBMTP_Get_Storage(device, LIBMTP_STORAGE_SORTBY_NOTSORTED) != 0 ||
        device->storage == NULL) {
        ad_mtp_set_device_error(device, error_message,
                                "Android 저장소 정보를 읽지 못했습니다.");
        return 0;
    }
    return device->storage->id;
}

static int ad_mtp_find_child_folder(LIBMTP_mtpdevice_t *device,
                                    uint32_t storage_id,
                                    uint32_t parent_id,
                                    const char *name,
                                    uint32_t *folder_id) {
    LIBMTP_file_t *files = ad_mtp_get_files_and_folders(
        device, storage_id, parent_id
    );
    LIBMTP_file_t *current = files;
    int found = 0;
    while (current != NULL) {
        if (current->filetype == LIBMTP_FILETYPE_FOLDER &&
            current->filename != NULL &&
            strcmp(current->filename, name) == 0) {
            *folder_id = current->item_id;
            found = 1;
            break;
        }
        current = current->next;
    }
    ad_mtp_destroy_file_list(files);
    LIBMTP_Clear_Errorstack(device);
    return found;
}

static int ad_mtp_resolve_folder(LIBMTP_mtpdevice_t *device,
                                 const char *path,
                                 ADMTPFolderLocation *location,
                                 char **error_message) {
    uint32_t storage_id = ad_mtp_primary_storage(device, error_message);
    if (storage_id == 0) {
        return -1;
    }

    uint32_t folder_id = LIBMTP_FILES_AND_FOLDERS_ROOT;
    char *copy = strdup(path == NULL ? "" : path);
    if (copy == NULL) {
        ad_mtp_set_error(error_message, "MTP 경로 처리 중 메모리가 부족합니다.");
        return -1;
    }

    char *save_pointer = NULL;
    char *component = strtok_r(copy, "/", &save_pointer);
    if (component == NULL) {
        free(copy);
        location->storage_id = storage_id;
        location->folder_id = folder_id;
        location->is_root = 1;
        return 0;
    }

    LIBMTP_folder_t *folders = ad_mtp_get_folder_tree(device, storage_id,
                                                       error_message);
    if (folders == NULL) {
        free(copy);
        return -1;
    }
    LIBMTP_folder_t *current_level = folders;
    while (component != NULL) {
        if (component[0] != '\0' && strcmp(component, ".") != 0) {
            if (strcmp(component, "..") == 0) {
                LIBMTP_destroy_folder_t(folders);
                free(copy);
                ad_mtp_set_error(error_message, "MTP 경로에는 '..'을 사용할 수 없습니다.");
                return -1;
            }
            LIBMTP_folder_t *folder = ad_mtp_find_folder(current_level, component);
            if (folder == NULL) {
                char message[1024];
                snprintf(message, sizeof(message),
                         "MTP 폴더를 찾지 못했습니다: %s", component);
                LIBMTP_destroy_folder_t(folders);
                free(copy);
                ad_mtp_set_error(error_message, message);
                return -1;
            }
            folder_id = folder->folder_id;
            current_level = folder->child;
        }
        component = strtok_r(NULL, "/", &save_pointer);
    }

    LIBMTP_destroy_folder_t(folders);
    free(copy);
    location->storage_id = storage_id;
    location->folder_id = folder_id;
    location->is_root = 0;
    return 0;
}

ADMTPConnection *ad_mtp_connect(char **display_name, char **serial_number,
                                char **error_message) {
    if (display_name != NULL) *display_name = NULL;
    if (serial_number != NULL) *serial_number = NULL;
    if (error_message != NULL) *error_message = NULL;

    LIBMTP_mtpdevice_t *device = ad_mtp_open_device(error_message);
    if (device == NULL) {
        return NULL;
    }

    ADMTPConnection *connection = calloc(1, sizeof(ADMTPConnection));
    if (connection == NULL) {
        LIBMTP_Release_Device(device);
        ad_mtp_set_error(error_message, "MTP 연결 정보를 만들지 못했습니다.");
        return NULL;
    }
    connection->device = device;

    char *friendly_name = LIBMTP_Get_Friendlyname(device);
    char *model_name = LIBMTP_Get_Modelname(device);
    char *manufacturer = LIBMTP_Get_Manufacturername(device);
    char *serial = LIBMTP_Get_Serialnumber(device);

    const char *name = friendly_name != NULL && friendly_name[0] != '\0'
                       ? friendly_name
                       : (model_name != NULL && model_name[0] != '\0'
                          ? model_name
                          : "Android MTP 기기");
    if (display_name != NULL) {
        if (manufacturer != NULL && manufacturer[0] != '\0' &&
            strstr(name, manufacturer) == NULL) {
            size_t length = strlen(manufacturer) + strlen(name) + 2;
            *display_name = malloc(length);
            if (*display_name != NULL) {
                snprintf(*display_name, length, "%s %s", manufacturer, name);
            }
        } else {
            *display_name = strdup(name);
        }
    }
    if (serial_number != NULL) {
        *serial_number = strdup(serial == NULL ? "" : serial);
    }

    free(friendly_name);
    free(model_name);
    free(manufacturer);
    free(serial);

    if ((display_name != NULL && *display_name == NULL) ||
        (serial_number != NULL && *serial_number == NULL)) {
        ad_mtp_disconnect(connection);
        ad_mtp_set_error(error_message, "MTP 기기 정보 처리 중 메모리가 부족합니다.");
        return NULL;
    }
    return connection;
}

void ad_mtp_disconnect(ADMTPConnection *connection) {
    if (connection == NULL) {
        return;
    }
    ad_mtp_clear_index(connection);
    if (connection->device != NULL) {
        LIBMTP_Release_Device(connection->device);
        connection->device = NULL;
    }
    free(connection);
}

void ad_mtp_invalidate_index(ADMTPConnection *connection) {
    ad_mtp_clear_index(connection);
}

static int ad_mtp_make_items_from_file_list(LIBMTP_file_t *files,
                                             ADMTPItem **items, size_t *count,
                                             char **error_message) {
    size_t item_count = 0;
    for (LIBMTP_file_t *current = files; current != NULL; current = current->next) {
        item_count++;
    }
    ADMTPItem *result = item_count == 0 ? NULL : calloc(item_count, sizeof(ADMTPItem));
    if (item_count > 0 && result == NULL) {
        ad_mtp_destroy_file_list(files);
        ad_mtp_set_error(error_message, "MTP 목록 처리 중 메모리가 부족합니다.");
        return -1;
    }

    size_t index = 0;
    for (LIBMTP_file_t *current = files; current != NULL; current = current->next) {
        result[index].object_id = current->item_id;
        result[index].storage_id = current->storage_id;
        result[index].size = current->filesize;
        result[index].modification_time = (int64_t) current->modificationdate;
        result[index].is_directory = current->filetype == LIBMTP_FILETYPE_FOLDER;
        result[index].name = strdup(current->filename == NULL ? "이름 없음" : current->filename);
        const char *kind = result[index].is_directory
            ? "폴더"
            : LIBMTP_Get_Filetype_Description(current->filetype);
        result[index].kind = strdup(kind == NULL || kind[0] == '\0' ? "파일" : kind);
        if (result[index].name == NULL || result[index].kind == NULL) {
            ad_mtp_free_items(result, item_count);
            ad_mtp_destroy_file_list(files);
            ad_mtp_set_error(error_message, "MTP 목록 처리 중 메모리가 부족합니다.");
            return -1;
        }
        index++;
    }

    ad_mtp_destroy_file_list(files);
    *items = result;
    *count = item_count;
    return 0;
}

static int ad_mtp_index_item_matches(const ADMTPIndexedItem *item,
                                     uint32_t parent_id, int is_root) {
    if (is_root) {
        return item->parent_id == LIBMTP_FILES_AND_FOLDERS_ROOT ||
               item->parent_id == 0;
    }
    return item->parent_id == parent_id;
}

static int ad_mtp_copy_index_items(ADMTPIndexedItem *indexed_items,
                                   uint32_t parent_id, int is_root,
                                   ADMTPItem **items, size_t *count,
                                   char **error_message) {
    size_t item_count = 0;
    for (ADMTPIndexedItem *current = indexed_items;
         current != NULL; current = current->next) {
        if (ad_mtp_index_item_matches(current, parent_id, is_root)) {
            item_count++;
        }
    }

    ADMTPItem *result = item_count == 0 ? NULL : calloc(item_count, sizeof(ADMTPItem));
    if (item_count > 0 && result == NULL) {
        ad_mtp_set_error(error_message, "MTP 인덱스 처리 중 메모리가 부족합니다.");
        return -1;
    }

    size_t index = 0;
    for (ADMTPIndexedItem *current = indexed_items;
         current != NULL; current = current->next) {
        if (!ad_mtp_index_item_matches(current, parent_id, is_root)) {
            continue;
        }
        result[index].object_id = current->object_id;
        result[index].storage_id = current->storage_id;
        result[index].size = current->size;
        result[index].modification_time = current->modification_time;
        result[index].is_directory = current->is_directory;
        result[index].name = strdup(current->name);
        result[index].kind = strdup(current->kind);
        if (result[index].name == NULL || result[index].kind == NULL) {
            ad_mtp_free_items(result, item_count);
            ad_mtp_set_error(error_message, "MTP 인덱스 처리 중 메모리가 부족합니다.");
            return -1;
        }
        index++;
    }

    *items = result;
    *count = item_count;
    return 0;
}

static int ad_mtp_add_index_item(ADMTPConnection *connection,
                                 uint32_t object_id, uint32_t parent_id,
                                 uint32_t storage_id, uint64_t size,
                                 int64_t modification_time, int is_directory,
                                 const char *name, const char *kind,
                                 char **error_message) {
    ADMTPIndexedItem *item = calloc(1, sizeof(ADMTPIndexedItem));
    if (item == NULL) {
        ad_mtp_set_error(error_message, "MTP 인덱스 처리 중 메모리가 부족합니다.");
        return -1;
    }
    item->name = strdup(name == NULL ? "이름 없음" : name);
    item->kind = strdup(kind == NULL || kind[0] == '\0'
        ? (is_directory ? "폴더" : "파일")
        : kind);
    if (item->name == NULL || item->kind == NULL) {
        free(item->name);
        free(item->kind);
        free(item);
        ad_mtp_set_error(error_message, "MTP 인덱스 처리 중 메모리가 부족합니다.");
        return -1;
    }
    item->object_id = object_id;
    item->parent_id = parent_id;
    item->storage_id = storage_id;
    item->size = size;
    item->modification_time = modification_time;
    item->is_directory = is_directory;
    item->next = connection->index;
    connection->index = item;
    return 0;
}

static void ad_mtp_update_indexed_folder_metadata(
    ADMTPConnection *connection,
    const LIBMTP_file_t *folder
) {
    for (ADMTPIndexedItem *item = connection->index;
         item != NULL; item = item->next) {
        if (item->object_id == folder->item_id &&
            (folder->storage_id == 0 || item->storage_id == folder->storage_id)) {
            item->modification_time = (int64_t) folder->modificationdate;
            return;
        }
    }
}

static int ad_mtp_add_folder_tree_to_index(ADMTPConnection *connection,
                                            LIBMTP_folder_t *folders,
                                            uint32_t parent_id,
                                            uint32_t storage_id,
                                            char **error_message) {
    for (LIBMTP_folder_t *folder = folders; folder != NULL;
         folder = folder->sibling) {
        uint32_t folder_storage_id = folder->storage_id == 0
            ? storage_id
            : folder->storage_id;
        if (ad_mtp_add_index_item(
                connection, folder->folder_id, parent_id, folder_storage_id,
                0, 0, 1, folder->name, "폴더", error_message
            ) != 0) {
            return -1;
        }
        if (folder->child != NULL &&
            ad_mtp_add_folder_tree_to_index(
                connection, folder->child, folder->folder_id,
                folder_storage_id, error_message
            ) != 0) {
            return -1;
        }
    }
    return 0;
}

static int ad_mtp_load_index(ADMTPConnection *connection,
                             char **error_message) {
    LIBMTP_mtpdevice_t *device = ad_mtp_connection_device(connection, error_message);
    if (device == NULL) {
        return -1;
    }

    ad_mtp_clear_index(connection);
    LIBMTP_Clear_Errorstack(device);
    if (LIBMTP_Get_Storage(device, LIBMTP_STORAGE_SORTBY_NOTSORTED) != 0 ||
        device->storage == NULL) {
        ad_mtp_set_device_error(device, error_message,
                                "Android 저장소 정보를 읽지 못했습니다.");
        return -1;
    }

    for (LIBMTP_devicestorage_t *storage = device->storage;
         storage != NULL; storage = storage->next) {
        LIBMTP_Clear_Errorstack(device);
        LIBMTP_folder_t *folders = LIBMTP_Get_Folder_List_For_Storage(
            device, storage->id
        );
        if (folders == NULL && LIBMTP_Get_Errorstack(device) != NULL) {
            ad_mtp_set_device_error(device, error_message,
                                    "MTP 폴더 인덱스를 읽지 못했습니다.");
            ad_mtp_clear_index(connection);
            return -1;
        }
        int folder_result = ad_mtp_add_folder_tree_to_index(
            connection, folders, LIBMTP_FILES_AND_FOLDERS_ROOT,
            storage->id, error_message
        );
        LIBMTP_destroy_folder_t(folders);
        if (folder_result != 0) {
            ad_mtp_clear_index(connection);
            return -1;
        }
    }

    LIBMTP_Clear_Errorstack(device);
    LIBMTP_file_t *files = LIBMTP_Get_Filelisting(device);
    if (files == NULL && LIBMTP_Get_Errorstack(device) != NULL) {
        ad_mtp_set_device_error(device, error_message,
                                "MTP 전체 파일 인덱스를 읽지 못했습니다.");
        ad_mtp_clear_index(connection);
        return -1;
    }

    int file_result = 0;
    for (LIBMTP_file_t *file = files; file != NULL; file = file->next) {
        if (file->filetype == LIBMTP_FILETYPE_FOLDER) {
            ad_mtp_update_indexed_folder_metadata(connection, file);
            continue;
        }
        if (ad_mtp_add_index_item(
                connection, file->item_id, file->parent_id, file->storage_id,
                file->filesize, (int64_t) file->modificationdate, 0,
                file->filename,
                LIBMTP_Get_Filetype_Description(file->filetype), error_message
            ) != 0) {
            file_result = -1;
            break;
        }
    }
    ad_mtp_destroy_file_list(files);
    if (file_result != 0) {
        ad_mtp_clear_index(connection);
        return -1;
    }
    connection->index_loaded = 1;
    return 0;
}

int ad_mtp_refresh_index(ADMTPConnection *connection,
                         ADMTPItem **root_items, size_t *root_count,
                         char **error_message) {
    if (root_items == NULL || root_count == NULL) {
        ad_mtp_set_error(error_message, "MTP 인덱스 결과를 저장할 공간이 없습니다.");
        return -1;
    }
    *root_items = NULL;
    *root_count = 0;
    if (error_message != NULL) *error_message = NULL;

    if (ad_mtp_load_index(connection, error_message) != 0) {
        return -1;
    }
    return ad_mtp_copy_index_items(
        connection->index, LIBMTP_FILES_AND_FOLDERS_ROOT, 1,
        root_items, root_count, error_message
    );
}

int ad_mtp_list(ADMTPConnection *connection, const char *remote_path,
                ADMTPItem **items, size_t *count,
                char **error_message) {
    if (items == NULL || count == NULL) {
        ad_mtp_set_error(error_message, "MTP 목록 결과를 저장할 공간이 없습니다.");
        return -1;
    }
    *items = NULL;
    *count = 0;
    if (error_message != NULL) *error_message = NULL;

    LIBMTP_mtpdevice_t *device = ad_mtp_connection_device(connection, error_message);
    if (device == NULL) {
        return -1;
    }

    ADMTPFolderLocation location;
    if (ad_mtp_resolve_folder(device, remote_path, &location, error_message) != 0) {
        return -1;
    }

    if (location.is_root) {
        if (connection->index_loaded) {
            return ad_mtp_copy_index_items(
                connection->index, LIBMTP_FILES_AND_FOLDERS_ROOT, 1,
                items, count, error_message
            );
        }

        LIBMTP_folder_t *folders = ad_mtp_get_folder_tree(
            device, location.storage_id, error_message
        );
        if (folders == NULL && error_message != NULL && *error_message != NULL) {
            return -1;
        }

        size_t item_count = 0;
        for (LIBMTP_folder_t *folder = folders; folder != NULL;
             folder = folder->sibling) {
            item_count++;
        }
        ADMTPItem *result = item_count == 0 ? NULL : calloc(item_count, sizeof(ADMTPItem));
        if (item_count > 0 && result == NULL) {
            LIBMTP_destroy_folder_t(folders);
            ad_mtp_set_error(error_message, "MTP 목록 처리 중 메모리가 부족합니다.");
            return -1;
        }

        size_t index = 0;
        for (LIBMTP_folder_t *folder = folders; folder != NULL;
             folder = folder->sibling) {
            result[index].object_id = folder->folder_id;
            result[index].storage_id = folder->storage_id;
            result[index].is_directory = 1;
            result[index].name = strdup(folder->name == NULL ? "이름 없음" : folder->name);
            if (result[index].name == NULL) {
                ad_mtp_free_items(result, item_count);
                LIBMTP_destroy_folder_t(folders);
                ad_mtp_set_error(error_message, "MTP 목록 처리 중 메모리가 부족합니다.");
                return -1;
            }
            index++;
        }

        LIBMTP_destroy_folder_t(folders);
        *items = result;
        *count = item_count;
        return 0;
    }

    if (connection->index_loaded) {
        return ad_mtp_copy_index_items(
            connection->index, location.folder_id, 0,
            items, count, error_message
        );
    }

    LIBMTP_file_t *files = ad_mtp_get_files_and_folders(
        device, location.storage_id, location.folder_id
    );
    if (files == NULL && LIBMTP_Get_Errorstack(device) != NULL) {
        ad_mtp_set_device_error(device, error_message,
                                "MTP 폴더 목록을 읽지 못했습니다.");
        return -1;
    }

    int result = ad_mtp_make_items_from_file_list(files, items, count, error_message);
    return result;
}

int ad_mtp_list_children(ADMTPConnection *connection,
                         uint32_t storage_id, uint32_t folder_id,
                         ADMTPItem **items, size_t *count, char **error_message) {
    if (items == NULL || count == NULL) {
        ad_mtp_set_error(error_message, "MTP 목록 결과를 저장할 공간이 없습니다.");
        return -1;
    }
    *items = NULL;
    *count = 0;
    if (error_message != NULL) *error_message = NULL;

    LIBMTP_mtpdevice_t *device = ad_mtp_connection_device(connection, error_message);
    if (device == NULL) {
        return -1;
    }

    if (connection->index_loaded) {
        return ad_mtp_copy_index_items(
            connection->index, folder_id, 0,
            items, count, error_message
        );
    }

    LIBMTP_file_t *files = ad_mtp_get_files_and_folders(device, storage_id, folder_id);
    if (files == NULL && LIBMTP_Get_Errorstack(device) != NULL) {
        ad_mtp_set_device_error(device, error_message,
                                "MTP 폴더 목록을 읽지 못했습니다.");
        return -1;
    }

    if (files == NULL) {
        /*
         * Some Android MTP implementations return an empty successful response
         * for GetObjectHandles(parent). Fall back to the complete metadata list
         * only in that case, then keep the filtered result in Swift's cache.
         */
        if (ad_mtp_load_index(connection, error_message) != 0) {
            return -1;
        }
        return ad_mtp_copy_index_items(
            connection->index, folder_id, 0,
            items, count, error_message
        );
    }

    int result = ad_mtp_make_items_from_file_list(files, items, count, error_message);
    return result;
}

static int ad_mtp_send_path(LIBMTP_mtpdevice_t *device,
                            const char *local_path,
                            const char *target_name,
                            uint32_t storage_id,
                            uint32_t parent_id,
                            const ADMTPProgressContext *progress,
                            char **error_message) {
    if (ad_mtp_transfer_cancelled(progress, error_message)) {
        return -1;
    }
    struct stat info;
    if (stat(local_path, &info) != 0) {
        ad_mtp_set_error(error_message, strerror(errno));
        return -1;
    }

    const char *name = target_name;
    if (name == NULL || name[0] == '\0') {
        name = strrchr(local_path, '/');
        name = name == NULL ? local_path : name + 1;
    }
    if (name[0] == '\0') {
        ad_mtp_set_error(error_message, "전송할 항목 이름을 읽지 못했습니다.");
        return -1;
    }

    if (S_ISDIR(info.st_mode)) {
        uint32_t folder_id = 0;
        if (!ad_mtp_find_child_folder(device, storage_id, parent_id, name, &folder_id)) {
            char *mutable_name = strdup(name);
            if (mutable_name == NULL) {
                ad_mtp_set_error(error_message, "폴더 이름 처리 중 메모리가 부족합니다.");
                return -1;
            }
            folder_id = LIBMTP_Create_Folder(device, mutable_name, parent_id, storage_id);
            free(mutable_name);
            if (folder_id == 0) {
                ad_mtp_set_device_error(device, error_message,
                                        "Android에 MTP 폴더를 만들지 못했습니다.");
                return -1;
            }
        }

        DIR *directory = opendir(local_path);
        if (directory == NULL) {
            ad_mtp_set_error(error_message, strerror(errno));
            return -1;
        }
        struct dirent *entry;
        int result = 0;
        while ((entry = readdir(directory)) != NULL) {
            if (ad_mtp_transfer_cancelled(progress, error_message)) {
                result = -1;
                break;
            }
            if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
                continue;
            }
            size_t path_length = strlen(local_path) + strlen(entry->d_name) + 2;
            char *child_path = malloc(path_length);
            if (child_path == NULL) {
                ad_mtp_set_error(error_message, "로컬 경로 처리 중 메모리가 부족합니다.");
                result = -1;
                break;
            }
            snprintf(child_path, path_length, "%s/%s", local_path, entry->d_name);
            result = ad_mtp_send_path(device, child_path, NULL,
                                      storage_id, folder_id,
                                      progress, error_message);
            free(child_path);
            if (result != 0) {
                break;
            }
        }
        closedir(directory);
        return result;
    }

    if (!S_ISREG(info.st_mode)) {
        ad_mtp_set_error(error_message, "일반 파일과 폴더만 MTP로 전송할 수 있습니다.");
        return -1;
    }

    LIBMTP_file_t *file = LIBMTP_new_file_t();
    if (file == NULL) {
        ad_mtp_set_error(error_message, "MTP 파일 정보를 만들지 못했습니다.");
        return -1;
    }
    file->filesize = (uint64_t) info.st_size;
    file->filename = strdup(name);
    if (file->filename == NULL) {
        LIBMTP_destroy_file_t(file);
        ad_mtp_set_error(error_message, "파일 이름 처리 중 메모리가 부족합니다.");
        return -1;
    }
    file->filetype = LIBMTP_FILETYPE_UNKNOWN;
    file->parent_id = parent_id;
    file->storage_id = storage_id;

    int result = LIBMTP_Send_File_From_File(
        device, local_path, file, ad_mtp_report_progress, progress
    );
    LIBMTP_destroy_file_t(file);
    if (result != 0) {
        ad_mtp_set_device_error(device, error_message,
                                "파일을 Android로 전송하지 못했습니다.");
        return -1;
    }
    return 0;
}

int ad_mtp_upload(ADMTPConnection *connection,
                  const char *local_path, const char *remote_name,
                  const char *remote_directory,
                  ADMTPProgressCallback progress_callback, void *progress_context,
                  char **error_message) {
    if (error_message != NULL) *error_message = NULL;
    LIBMTP_mtpdevice_t *device = ad_mtp_connection_device(connection, error_message);
    if (device == NULL) {
        return -1;
    }

    ADMTPFolderLocation location;
    if (ad_mtp_resolve_folder(device, remote_directory, &location,
                              error_message) != 0) {
        return -1;
    }
    ADMTPProgressContext progress = {
        .callback = progress_callback,
        .context = progress_context,
    };
    int result = ad_mtp_send_path(device, local_path, remote_name,
                                  location.storage_id,
                                  location.folder_id, &progress, error_message);
    ad_mtp_clear_index(connection);
    return result;
}

int ad_mtp_upload_to_folder(ADMTPConnection *connection,
                            const char *local_path, const char *remote_name,
                            uint32_t storage_id, uint32_t folder_id,
                            ADMTPProgressCallback progress_callback,
                            void *progress_context, char **error_message) {
    if (error_message != NULL) *error_message = NULL;
    LIBMTP_mtpdevice_t *device = ad_mtp_connection_device(connection, error_message);
    if (device == NULL) {
        return -1;
    }

    ADMTPProgressContext progress = {
        .callback = progress_callback,
        .context = progress_context,
    };
    int result = ad_mtp_send_path(device, local_path, remote_name,
                                  storage_id, folder_id,
                                  &progress, error_message);
    ad_mtp_clear_index(connection);
    return result;
}

static int ad_mtp_safe_name(const char *name) {
    return name != NULL && name[0] != '\0' &&
           strcmp(name, ".") != 0 && strcmp(name, "..") != 0 &&
           strchr(name, '/') == NULL;
}

static int ad_mtp_create_folder_at_location(
    ADMTPConnection *connection,
    LIBMTP_mtpdevice_t *device,
    uint32_t storage_id,
    uint32_t parent_id,
    const char *name,
    uint32_t *object_id,
    char **error_message
) {
    if (!ad_mtp_safe_name(name)) {
        ad_mtp_set_error(error_message,
                         "폴더 이름은 비어 있을 수 없으며 '/'를 포함할 수 없습니다.");
        return -1;
    }

    uint32_t existing_folder_id = 0;
    if (ad_mtp_find_child_folder(device, storage_id, parent_id, name,
                                 &existing_folder_id)) {
        ad_mtp_set_error(error_message, "같은 이름의 폴더가 이미 있습니다.");
        return -1;
    }

    char *mutable_name = strdup(name);
    if (mutable_name == NULL) {
        ad_mtp_set_error(error_message, "폴더 이름 처리 중 메모리가 부족합니다.");
        return -1;
    }
    LIBMTP_Clear_Errorstack(device);
    uint32_t folder_id = LIBMTP_Create_Folder(
        device, mutable_name, parent_id, storage_id
    );
    free(mutable_name);
    if (folder_id == 0) {
        ad_mtp_set_device_error(device, error_message,
                                "Android에 MTP 폴더를 만들지 못했습니다.");
        return -1;
    }

    if (object_id != NULL) {
        *object_id = folder_id;
    }
    ad_mtp_clear_index(connection);
    return 0;
}

int ad_mtp_create_folder(ADMTPConnection *connection,
                         const char *remote_directory, const char *name,
                         uint32_t *object_id, char **error_message) {
    if (error_message != NULL) *error_message = NULL;
    if (object_id != NULL) *object_id = 0;
    LIBMTP_mtpdevice_t *device = ad_mtp_connection_device(connection, error_message);
    if (device == NULL) {
        return -1;
    }

    ADMTPFolderLocation location;
    if (ad_mtp_resolve_folder(device, remote_directory, &location,
                              error_message) != 0) {
        return -1;
    }
    return ad_mtp_create_folder_at_location(
        connection, device, location.storage_id, location.folder_id,
        name, object_id, error_message
    );
}

int ad_mtp_create_folder_in_folder(ADMTPConnection *connection,
                                   uint32_t storage_id, uint32_t folder_id,
                                   const char *name, uint32_t *object_id,
                                   char **error_message) {
    if (error_message != NULL) *error_message = NULL;
    if (object_id != NULL) *object_id = 0;
    LIBMTP_mtpdevice_t *device = ad_mtp_connection_device(connection, error_message);
    if (device == NULL) {
        return -1;
    }
    return ad_mtp_create_folder_at_location(
        connection, device, storage_id, folder_id,
        name, object_id, error_message
    );
}

int ad_mtp_rename_object(ADMTPConnection *connection,
                         uint32_t object_id, const char *name,
                         char **error_message) {
    if (error_message != NULL) *error_message = NULL;
    LIBMTP_mtpdevice_t *device = ad_mtp_connection_device(connection, error_message);
    if (device == NULL) {
        return -1;
    }
    if (!ad_mtp_safe_name(name)) {
        ad_mtp_set_error(error_message,
                         "이름은 비어 있을 수 없으며 '/'를 포함할 수 없습니다.");
        return -1;
    }

    char *mutable_name = strdup(name);
    if (mutable_name == NULL) {
        ad_mtp_set_error(error_message, "이름 처리 중 메모리가 부족합니다.");
        return -1;
    }
    LIBMTP_Clear_Errorstack(device);
    int result = LIBMTP_Set_Object_Filename(device, object_id, mutable_name);
    free(mutable_name);
    if (result != 0) {
        ad_mtp_set_device_error(device, error_message,
                                "Android 항목의 이름을 변경하지 못했습니다.");
        return -1;
    }
    ad_mtp_clear_index(connection);
    return 0;
}

int ad_mtp_delete_object(ADMTPConnection *connection,
                         uint32_t object_id, char **error_message) {
    if (error_message != NULL) *error_message = NULL;
    LIBMTP_mtpdevice_t *device = ad_mtp_connection_device(connection, error_message);
    if (device == NULL) {
        return -1;
    }

    LIBMTP_Clear_Errorstack(device);
    if (LIBMTP_Delete_Object(device, object_id) != 0) {
        ad_mtp_set_device_error(device, error_message,
                                "Android 항목을 삭제하지 못했습니다.");
        return -1;
    }
    ad_mtp_clear_index(connection);
    return 0;
}

static int ad_mtp_download_folder(LIBMTP_mtpdevice_t *device,
                                  uint32_t storage_id,
                                  uint32_t folder_id,
                                  const char *destination_path,
                                  const ADMTPProgressContext *progress,
                                  char **error_message) {
    if (ad_mtp_transfer_cancelled(progress, error_message)) {
        return -1;
    }
    if (mkdir(destination_path, 0755) != 0 && errno != EEXIST) {
        ad_mtp_set_error(error_message, strerror(errno));
        return -1;
    }

    LIBMTP_file_t *files = ad_mtp_get_files_and_folders(
        device, storage_id, folder_id
    );
    if (files == NULL && LIBMTP_Get_Errorstack(device) != NULL) {
        ad_mtp_set_device_error(device, error_message,
                                "MTP 폴더 내용을 읽지 못했습니다.");
        return -1;
    }

    int result = 0;
    for (LIBMTP_file_t *current = files; current != NULL; current = current->next) {
        if (ad_mtp_transfer_cancelled(progress, error_message)) {
            result = -1;
            break;
        }
        if (!ad_mtp_safe_name(current->filename)) {
            ad_mtp_set_error(error_message, "안전하지 않은 MTP 파일 이름을 발견했습니다.");
            result = -1;
            break;
        }
        size_t path_length = strlen(destination_path) + strlen(current->filename) + 2;
        char *child_path = malloc(path_length);
        if (child_path == NULL) {
            ad_mtp_set_error(error_message, "다운로드 경로 처리 중 메모리가 부족합니다.");
            result = -1;
            break;
        }
        snprintf(child_path, path_length, "%s/%s", destination_path,
                 current->filename);
        if (current->filetype == LIBMTP_FILETYPE_FOLDER) {
            result = ad_mtp_download_folder(device, current->storage_id,
                                            current->item_id, child_path,
                                            progress, error_message);
        } else if (LIBMTP_Get_File_To_File(device, current->item_id,
                                           child_path, ad_mtp_report_progress,
                                           progress) != 0) {
            ad_mtp_set_device_error(device, error_message,
                                    "MTP 파일을 Mac으로 다운로드하지 못했습니다.");
            result = -1;
        }
        free(child_path);
        if (result != 0) {
            break;
        }
    }
    ad_mtp_destroy_file_list(files);
    return result;
}

int ad_mtp_download(ADMTPConnection *connection,
                    uint32_t object_id, uint32_t storage_id, int is_directory,
                    const char *destination_path,
                    ADMTPProgressCallback progress_callback, void *progress_context,
                    char **error_message) {
    if (error_message != NULL) *error_message = NULL;
    LIBMTP_mtpdevice_t *device = ad_mtp_connection_device(connection, error_message);
    if (device == NULL) {
        return -1;
    }

    ADMTPProgressContext progress = {
        .callback = progress_callback,
        .context = progress_context,
    };
    int result;
    if (is_directory) {
        result = ad_mtp_download_folder(device, storage_id, object_id,
                                        destination_path, &progress, error_message);
    } else {
        result = LIBMTP_Get_File_To_File(device, object_id, destination_path,
                                         ad_mtp_report_progress, &progress);
        if (result != 0) {
            ad_mtp_set_device_error(device, error_message,
                                    "MTP 파일을 Mac으로 다운로드하지 못했습니다.");
            result = -1;
        }
    }
    return result;
}

void ad_mtp_free_items(ADMTPItem *items, size_t count) {
    if (items == NULL) {
        return;
    }
    for (size_t index = 0; index < count; index++) {
        free(items[index].name);
        free(items[index].kind);
    }
    free(items);
}

void ad_mtp_free_string(char *value) {
    free(value);
}
