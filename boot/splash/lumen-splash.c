/*
 * lumen-splash: show one picture full screen until killed (SIGTERM/SIGINT).
 *
 * Replaces Project Eris' sdl_display in Lumen's boot payload. It runs on Sony's
 * Weston 1.11 with the console's own SDL 2.0.4 (Wayland video driver), right after
 * the Sony UI has been stopped, and stays up until Lumen's boot.sh swaps the
 * compositor (boot.sh kills processes named "sdl_display": the payload starts this
 * binary through a symlink with that name).
 *
 *   lumen-splash [--text <png>]... <image> [<fallback image>...]
 *
 * --text: a line of text as a picture (white on transparent; the first one that loads is
 * used), drawn at the bottom right and followed by three square dots that light up one
 * after another: "Loading", and the proof that the console is alive. Lumen's own startup
 * splash draws the same text and dots in the same place (lumen src/main.c
 * splash_loading_draw; the pictures are lumen's assets/boot/loading-<lang>[-1080].png,
 * made by its tools/make-boot-text.py), so nothing jumps when Lumen takes over: keep the
 * LOADING_* numbers below equal to that file's.
 *
 * PNG/JPG through the console's SDL2_image (dlopen, so nothing extra is linked);
 * BMP through SDL itself when SDL2_image is missing. The picture is scaled to the
 * output keeping its aspect ratio, on black. The picture is Lumen's assets/splash.png:
 * the logo with its letters dark, which is also the first frame of Lumen's own splash. Only SDL 2.0.0 API is used: it is
 * built against Debian stretch's SDL 2.0.5 headers and runs on the console's 2.0.4.
 */
#include <SDL2/SDL.h>
#include <dlfcn.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>

/* layout px on a 1280x720 frame (the picture's rectangle on screen) */
#define LOADING_RIGHT   60     /* right margin of the last dot */
#define LOADING_TOP     650    /* top of the text picture */
#define LOADING_DOT     6      /* dot side, and the gap between dots */
#define LOADING_GAP     10     /* text to first dot */
#define LOADING_DOT_Y   14     /* dot top below LOADING_TOP: the dots sit on the baseline */
#define LOADING_STEP    350    /* ms per dot */

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
    SDL_Surface *img = NULL, *txt = NULL;
    int want_text = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--text")) {
            want_text = 1;
            if (++i < argc && !txt && (txt = load(argv[i])))
                fprintf(stderr, "lumen-splash: text %s (%dx%d)\n", argv[i], txt->w, txt->h);
            continue;
        }
        if (img) continue;
        img = load(argv[i]);
        if (img) fprintf(stderr, "lumen-splash: %s (%dx%d)\n", argv[i], img->w, img->h);
    }
    if (!img) fprintf(stderr, "lumen-splash: no image loaded, black screen\n");

    /* the window takes the output's size at 0,0: a compositor does that anyway for
     * FULLSCREEN_DESKTOP, a bare X server (the desktop simulator) does not */
    int ww = 1280, wh = 720;
    SDL_DisplayMode dm;
    if (SDL_GetDesktopDisplayMode(0, &dm) == 0 && dm.w > 0 && dm.h > 0) { ww = dm.w; wh = dm.h; }
    SDL_Window *win = SDL_CreateWindow("lumen-splash", 0, 0, ww, wh,
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
    SDL_Texture *ttex = txt ? SDL_CreateTextureFromSurface(r, txt) : NULL;
    if (ttex) {
        SDL_SetTextureBlendMode(ttex, SDL_BLENDMODE_BLEND);
        SDL_SetTextureColorMod(ttex, 214, 214, 224);
        SDL_SetTextureAlphaMod(ttex, 217);
    }
    SDL_SetRenderDrawBlendMode(r, SDL_BLENDMODE_BLEND);
    Uint32 t0 = SDL_GetTicks();

    while (!quit) {
        int ow = 1280, oh = 720;
        SDL_GetRendererOutputSize(r, &ow, &oh);
        SDL_SetRenderDrawColor(r, 0, 0, 0, 255);
        SDL_RenderClear(r);
        SDL_Rect dst = { 0, 0, ow, oh };
        if (tex) {
            /* fit, keep aspect */
            if ((long)ow * img->h > (long)oh * img->w) {
                dst.h = oh; dst.w = (int)((long)img->w * oh / img->h);
            } else {
                dst.w = ow; dst.h = (int)((long)img->h * ow / img->w);
            }
            dst.x = (ow - dst.w) / 2;
            dst.y = (oh - dst.h) / 2;
            SDL_RenderCopy(r, tex, NULL, &dst);
        }
        if (want_text) {
            /* the frame the layout is measured on: the picture's rectangle (or the whole
             * output without one); u = device px per layout px. The text picture was
             * rendered for the splash picture's own size. */
            SDL_Rect fr = dst;
            float u = fr.h / 720.0f, ts = tex ? fr.h / (float)img->h : u;
            int lit = (int)((SDL_GetTicks() - t0) / LOADING_STEP) % 4;   /* 0: none, then one more each step */
            int dot = (int)(LOADING_DOT * u + 0.5f);
            int x = fr.x + (int)((1280 - LOADING_RIGHT - 5 * LOADING_DOT) * u + 0.5f);
            if (ttex) {
                SDL_Rect td = { 0, fr.y + (int)(LOADING_TOP * u + 0.5f), (int)(txt->w * ts + 0.5f), (int)(txt->h * ts + 0.5f) };
                td.x = fr.x + (int)((1280 - LOADING_RIGHT - 5 * LOADING_DOT - LOADING_GAP) * u - txt->w * ts + 0.5f);
                SDL_RenderCopy(r, ttex, NULL, &td);
            }
            for (int i = 0; i < 3; i++) {
                SDL_Rect d = { x + (int)(i * 2 * LOADING_DOT * u + 0.5f), fr.y + (int)((LOADING_TOP + LOADING_DOT_Y) * u + 0.5f), dot, dot };
                SDL_SetRenderDrawColor(r, 214, 214, 224, i < lit ? 242 : 71);
                SDL_RenderFillRect(r, &d);
            }
        }
        SDL_RenderPresent(r);
        /* redraw at every dot step (and the output size can change); sleep in between */
        SDL_Event e;
        Uint32 until = SDL_GetTicks() + (want_text ? LOADING_STEP - (SDL_GetTicks() - t0) % LOADING_STEP : 500);
        while (!quit && !SDL_TICKS_PASSED(SDL_GetTicks(), until)) {
            while (SDL_PollEvent(&e))
                if (e.type == SDL_QUIT) quit = 1;
            SDL_Delay(50);
        }
    }
    if (ttex) SDL_DestroyTexture(ttex);
    if (tex) SDL_DestroyTexture(tex);
    if (txt) SDL_FreeSurface(txt);
    if (img) SDL_FreeSurface(img);
    SDL_DestroyRenderer(r);
    SDL_DestroyWindow(win);
    SDL_Quit();
    return 0;
}
