/*
 * lumen-splash: show one picture full screen until killed (SIGTERM/SIGINT).
 *
 * Replaces Project Eris' sdl_display in Lumen's boot payload. It runs on Sony's
 * Weston 1.11 with the console's own SDL 2.0.4 (Wayland video driver), right after
 * the Sony UI has been stopped, and stays up until Lumen's boot.sh swaps the
 * compositor (boot.sh kills processes named "sdl_display": the payload starts this
 * binary through a symlink with that name).
 *
 *   lumen-splash <image> [<fallback image>...]
 *
 * PNG/JPG through the console's SDL2_image (dlopen, so nothing extra is linked);
 * BMP through SDL itself when SDL2_image is missing. The picture is scaled to the
 * output keeping its aspect ratio, on black. Only SDL 2.0.0 API is used: it is
 * built against Debian stretch's SDL 2.0.5 headers and runs on the console's 2.0.4.
 */
#include <SDL2/SDL.h>
#include <dlfcn.h>
#include <signal.h>
#include <stdio.h>

static volatile sig_atomic_t quit;
static void on_signal(int s) { (void)s; quit = 1; }

typedef SDL_Surface *(*img_load_fn)(const char *);

static SDL_Surface *load(const char *path)
{
    static img_load_fn img_load;
    static int tried;
    if (!tried) {
        void *h = dlopen("libSDL2_image-2.0.so.0", RTLD_NOW | RTLD_LOCAL);
        if (h) img_load = (img_load_fn)dlsym(h, "IMG_Load");
        tried = 1;
    }
    SDL_Surface *s = img_load ? img_load(path) : NULL;
    if (!s) s = SDL_LoadBMP(path);
    return s;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <image> [<fallback>...]\n", argv[0]);
        return 2;
    }
    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);
    signal(SIGHUP, on_signal);

    if (!getenv("SDL_VIDEODRIVER")) setenv("SDL_VIDEODRIVER", "wayland", 1);
    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        fprintf(stderr, "lumen-splash: SDL_Init: %s\n", SDL_GetError());
        return 1;
    }
    SDL_Surface *img = NULL;
    for (int i = 1; i < argc && !img; i++) {
        img = load(argv[i]);
        if (img) fprintf(stderr, "lumen-splash: %s (%dx%d)\n", argv[i], img->w, img->h);
    }
    if (!img) fprintf(stderr, "lumen-splash: no image loaded, black screen\n");

    SDL_Window *win = SDL_CreateWindow("lumen-splash", SDL_WINDOWPOS_UNDEFINED,
                                       SDL_WINDOWPOS_UNDEFINED, 1280, 720,
                                       SDL_WINDOW_FULLSCREEN_DESKTOP | SDL_WINDOW_BORDERLESS);
    if (!win) {
        fprintf(stderr, "lumen-splash: SDL_CreateWindow: %s\n", SDL_GetError());
        SDL_Quit();
        return 1;
    }
    SDL_Renderer *r = SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED);
    if (!r) r = SDL_CreateRenderer(win, -1, SDL_RENDERER_SOFTWARE);
    if (!r) {
        fprintf(stderr, "lumen-splash: SDL_CreateRenderer: %s\n", SDL_GetError());
        SDL_DestroyWindow(win);
        SDL_Quit();
        return 1;
    }
    SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "linear");
    SDL_Texture *tex = img ? SDL_CreateTextureFromSurface(r, img) : NULL;

    while (!quit) {
        int ow = 1280, oh = 720;
        SDL_GetRendererOutputSize(r, &ow, &oh);
        SDL_SetRenderDrawColor(r, 0, 0, 0, 255);
        SDL_RenderClear(r);
        if (tex) {
            /* fit, keep aspect */
            SDL_Rect dst;
            if ((long)ow * img->h > (long)oh * img->w) {
                dst.h = oh; dst.w = (int)((long)img->w * oh / img->h);
            } else {
                dst.w = ow; dst.h = (int)((long)img->h * ow / img->w);
            }
            dst.x = (ow - dst.w) / 2;
            dst.y = (oh - dst.h) / 2;
            SDL_RenderCopy(r, tex, NULL, &dst);
        }
        SDL_RenderPresent(r);
        /* redraw now and then (output size can change); sleep in between */
        SDL_Event e;
        Uint32 until = SDL_GetTicks() + 500;
        while (!quit && !SDL_TICKS_PASSED(SDL_GetTicks(), until)) {
            while (SDL_PollEvent(&e))
                if (e.type == SDL_QUIT) quit = 1;
            SDL_Delay(50);
        }
    }
    if (tex) SDL_DestroyTexture(tex);
    if (img) SDL_FreeSurface(img);
    SDL_DestroyRenderer(r);
    SDL_DestroyWindow(win);
    SDL_Quit();
    return 0;
}
