// Inline accessors that let Swift read LibRaw fields it cannot import directly:
// fixed arrays larger than Swift's import limit (cblack), 2-D arrays, and C strings.
#ifndef REDLAMP_LIBRAW_H
#define REDLAMP_LIBRAW_H

#include "libraw.h"

static inline unsigned rl_cblack(const libraw_data_t *d, int index) {
    return (index >= 0 && index < LIBRAW_CBLACK_SIZE) ? d->color.cblack[index] : 0;
}

static inline float rl_cam_mul(const libraw_data_t *d, int channel) { return d->color.cam_mul[channel & 3]; }
static inline float rl_pre_mul(const libraw_data_t *d, int channel) { return d->color.pre_mul[channel & 3]; }
static inline float rl_rgb_cam(const libraw_data_t *d, int row, int col) { return d->color.rgb_cam[row % 3][col & 3]; }
static inline float rl_cam_xyz(const libraw_data_t *d, int row, int col) { return d->color.cam_xyz[row & 3][col % 3]; }
static inline float rl_baseline_exposure(const libraw_data_t *d) { return d->color.dng_levels.baseline_exposure; }

// DNG ColorMatrix1/2 (XYZ -> camera) and their calibration illuminants (EXIF LightSource codes).
static inline int rl_dng_illuminant(const libraw_data_t *d, int index) { return d->color.dng_color[index & 1].illuminant; }
static inline float rl_dng_colormatrix(const libraw_data_t *d, int index, int row, int col) {
    return d->color.dng_color[index & 1].colormatrix[row & 3][col % 3];
}

static inline int rl_xtrans(const libraw_data_t *d, int row, int col) { return d->idata.xtrans[row % 6][col % 6]; }

static inline const char *rl_make(const libraw_data_t *d) { return d->idata.make; }
static inline const char *rl_model(const libraw_data_t *d) { return d->idata.model; }
static inline const char *rl_lens(const libraw_data_t *d) { return d->lens.Lens; }

#endif
