/*
 * gbm-psc-compat: the libgbm entry points Weston 16 calls that the PlayStation
 * Classic's libgbm (Mesa 17.0 era, built with the PowerVR pvr_dri.so and tied to
 * the console's libEGL, so it cannot be replaced) does not export.
 *
 * Built as a static archive with -fvisibility=hidden and linked into
 * drm-backend.so and gl-renderer.so (through the build's gbm.pc), so these
 * definitions bind locally and never shadow a real libgbm symbol.
 *
 * The console's buffers are single-plane and have no format modifiers: the
 * per-plane getters answer for plane 0 with the old API, the modifier is
 * DRM_FORMAT_MOD_INVALID (Weston then uses plain drmModeAddFB2), and the
 * *_with_modifiers* constructors fail with ENOSYS so Weston's fallbacks to
 * gbm_bo_create() / gbm_surface_create() run.
 */
#include <errno.h>
#include <stdint.h>

#include <gbm.h>   /* Mesa >= 21.3 header, for the prototypes only */

#define PSC_DRM_FORMAT_MOD_INVALID ((1ULL << 56) - 1)

int
gbm_bo_get_plane_count(struct gbm_bo *bo)
{
	(void)bo;
	return 1;
}

uint32_t
gbm_bo_get_stride_for_plane(struct gbm_bo *bo, int plane)
{
	if (plane != 0) {
		errno = EINVAL;
		return 0;
	}
	return gbm_bo_get_stride(bo);
}

union gbm_bo_handle
gbm_bo_get_handle_for_plane(struct gbm_bo *bo, int plane)
{
	union gbm_bo_handle invalid;

	if (plane == 0)
		return gbm_bo_get_handle(bo);
	invalid.s64 = -1;
	errno = EINVAL;
	return invalid;
}

uint32_t
gbm_bo_get_offset(struct gbm_bo *bo, int plane)
{
	(void)bo;
	(void)plane;
	return 0;
}

int
gbm_bo_get_fd_for_plane(struct gbm_bo *bo, int plane)
{
	if (plane != 0) {
		errno = EINVAL;
		return -1;
	}
	return gbm_bo_get_fd(bo);
}

uint64_t
gbm_bo_get_modifier(struct gbm_bo *bo)
{
	(void)bo;
	return PSC_DRM_FORMAT_MOD_INVALID;
}

struct gbm_bo *
gbm_bo_create_with_modifiers(struct gbm_device *gbm,
			     uint32_t width, uint32_t height, uint32_t format,
			     const uint64_t *modifiers, const unsigned int count)
{
	(void)gbm; (void)width; (void)height; (void)format;
	(void)modifiers; (void)count;
	errno = ENOSYS;
	return NULL;
}

struct gbm_bo *
gbm_bo_create_with_modifiers2(struct gbm_device *gbm,
			      uint32_t width, uint32_t height, uint32_t format,
			      const uint64_t *modifiers, const unsigned int count,
			      uint32_t flags)
{
	(void)gbm; (void)width; (void)height; (void)format;
	(void)modifiers; (void)count; (void)flags;
	errno = ENOSYS;
	return NULL;
}

struct gbm_surface *
gbm_surface_create_with_modifiers(struct gbm_device *gbm,
				  uint32_t width, uint32_t height,
				  uint32_t format,
				  const uint64_t *modifiers,
				  const unsigned int count)
{
	(void)gbm; (void)width; (void)height; (void)format;
	(void)modifiers; (void)count;
	errno = ENOSYS;
	return NULL;
}
