#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

typedef struct DTProgress DTProgress;
typedef struct DTModel DTModel;
typedef struct DTList DTList;

typedef struct {
    const uint8_t *name;
    uint64_t bytes;
    size_t name_len;
    uint32_t slot, child;
    uint8_t kind;
    bool partial;
} DTRow;

typedef struct { uint64_t bytes, entries, issues, boundaries; } DTSummary;
typedef struct { uint32_t folder, slot; } DTKey;
typedef struct DTScene DTScene;
typedef struct DTFrame DTFrame;
typedef struct DTSelection DTSelection;
typedef struct { double x, y, w, h; } DTRect;
typedef struct { DTRect rect; DTKey key; } DTLabel;
typedef uint32_t (*DTResolveKind)(const char *path, const uint8_t *suffix, size_t length, uint32_t finderType, uint8_t traits);
typedef struct { uint64_t bytes, files; uint32_t kind; } DTKindTotal;
typedef struct { uint32_t surface[129], top, bottom, seam; } DTGlassTint;
DTGlassTint dt_glass_tint(uint32_t rgb);
DTScene *dt_map_new(const DTModel *, uint32_t root, double aspect, DTResolveKind resolve);
const DTKindTotal *dt_map_kinds(const DTScene *, size_t *count);
uint32_t dt_map_kind(const DTScene *, DTKey key);
void dt_map_free(DTScene *);
size_t dt_map_count(const DTScene *);
size_t dt_map_memory(const DTScene *);
bool dt_map_bounds(const DTScene *, DTKey, DTRect *);
bool dt_map_hit(const DTScene *, double x, double y, DTKey *);
DTSelection *dt_map_selection(const DTScene *, DTRect area);
const DTKey *dt_selection_keys(const DTSelection *, size_t *count);
void dt_selection_free(DTSelection *);
DTFrame *dt_map_render(const DTScene *, DTRect viewport, uint32_t width, uint32_t height, double scale, const DTGlassTint *colors, size_t colorCount, bool shine);
const uint8_t *dt_frame_pixels(const DTFrame *);
const DTLabel *dt_frame_labels(const DTFrame *, size_t *count);
void dt_frame_free(DTFrame *);
DTList *dt_key_route(const DTModel *, uint32_t root, DTKey);

DTProgress *dt_progress_new(void);
void dt_progress_free(DTProgress *);
uint64_t dt_progress_count(const DTProgress *);
void dt_cancel(const DTProgress *);
DTModel *dt_scan(const char *, const DTProgress *, char **error);
DTModel *dt_refresh(const DTModel *, const DTKey *, size_t count, const DTProgress *, char **error);
DTModel *dt_refresh_paths(const DTModel *, const uint8_t *, size_t length, const DTProgress *, char **error);
DTList *dt_route(const DTModel *, const char *path);
void dt_model_free(DTModel *);
uint64_t dt_memory_bytes(const DTModel *);
DTSummary dt_summary(const DTModel *, uint32_t folder);
DTList *dt_list(const DTModel *, uint32_t folder, size_t limit);
const DTRow *dt_rows(const DTList *, size_t *count);
size_t dt_child_count(const DTModel *, uint32_t folder);
bool dt_child(const DTModel *, uint32_t folder, size_t index, DTRow *row);
bool dt_entry(const DTModel *, uint32_t folder, uint32_t slot, DTRow *row);
void dt_list_free(DTList *);
char *dt_path(const DTModel *, uint32_t folder, uint32_t slot);
void dt_string_free(char *);
typedef struct DTTrashPlan DTTrashPlan;
typedef struct { uint64_t bytes, files, folders; uint8_t scope, percent; } DTTrashImpact;
typedef struct { size_t moved, failed; DTKey first; } DTTrashResult;
DTTrashPlan *dt_trash_prepare(const DTModel *, const DTKey *, size_t count, DTTrashImpact *, char **error);
const DTKey *dt_trash_roots(const DTTrashPlan *, size_t *count);
bool dt_trash_perform(const DTModel *, DTTrashPlan *, bool acknowledged, DTTrashResult *, char **error);
void dt_trash_plan_free(DTTrashPlan *);
