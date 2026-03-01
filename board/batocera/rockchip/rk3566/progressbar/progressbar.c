/*
 * Simple framebuffer progress bar for RK3566 boot.
 *
 * Draws a progress bar at the bottom of the screen over the existing
 * U-Boot splash. Shows current boot step text above the bar.
 * Monitors /tmp/status.txt written by rcS to track init script progress.
 * Exits when the last script starts.
 *
 * No SDL dependency — writes directly to the Linux framebuffer.
 * Accounts for yoffset (triple-buffered framebuffers).
 * Uses a built-in 8x8 bitmap font for text rendering.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <linux/fb.h>

#define STATUS_PATH    "/tmp/status.txt"
#define LOG_PATH       "/tmp/progressbar.log"
#define BAR_HEIGHT     4
#define BAR_MARGIN     32   /* pixels from bottom */
#define BAR_SIDE       100  /* pixels from left/right edges */
#define TEXT_MARGIN    4    /* pixels between text bg and bar */
#define FONT_SCALE     2    /* draw each font pixel as 2x2 */
#define CHAR_H         (8 * FONT_SCALE)
#define TEXT_PAD_X     4    /* horizontal padding inside text bg */
#define TEXT_PAD_Y     2    /* vertical padding inside text bg */
#define BAR_BG_COLOR   0xFF222222
#define BAR_FG_COLOR   0xFFDDDDDD
#define TEXT_COLOR     0xFFFFFFFF  /* white */
#define TEXT_BG_COLOR  0xFF222222  /* same as bar bg for subtle look */
#define ANIM_INTERVAL  30000  /* microseconds between animation frames */

static uint32_t *fbmem;
static int fb_width, fb_height, fb_stride, fb_yoff;
static FILE *logfp;
static uint32_t *text_bg_save;  /* saved pixels behind text area */
static int text_save_x, text_save_y, text_save_w, text_save_h;

/* Check if the splash image has been drawn by sampling the center of the
 * screen — an area we never touch, so non-black pixels mean fbv ran. */
static int splash_is_visible(void)
{
    int cx = fb_width / 2;
    int cy = fb_height / 2;
    uint32_t c = fbmem[(cy + fb_yoff) * fb_stride + cx];
    return (c & 0x00FFFFFF) != 0;
}

/* Save the framebuffer region behind the text area */
static void save_text_bg(int x, int y, int w, int h)
{
    text_save_x = x; text_save_y = y;
    text_save_w = w; text_save_h = h;
    text_bg_save = malloc(w * h * sizeof(uint32_t));
    if (!text_bg_save) return;
    for (int row = 0; row < h && (y + row) < fb_height; row++) {
        int abs_y = y + row + fb_yoff;
        for (int col = 0; col < w && (x + col) < fb_width; col++)
            text_bg_save[row * w + col] = fbmem[abs_y * fb_stride + x + col];
    }
}

/* Restore the saved framebuffer region */
static void restore_text_bg(void)
{
    if (!text_bg_save) return;
    for (int row = 0; row < text_save_h && (text_save_y + row) < fb_height; row++) {
        int abs_y = text_save_y + row + fb_yoff;
        for (int col = 0; col < text_save_w && (text_save_x + col) < fb_width; col++)
            fbmem[abs_y * fb_stride + text_save_x + col] = text_bg_save[row * text_save_w + col];
    }
}

static void logmsg(const char *fmt, ...)
{
    if (!logfp) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(logfp, fmt, ap);
    va_end(ap);
    fflush(logfp);
}

/*
 * Minimal 8x8 bitmap font covering ASCII 32-126.
 * Each character is 8 bytes, one byte per row, MSB = leftmost pixel.
 */
static const unsigned char font8x8[][8] = {
    [' '-32]  = {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00},
    ['!'-32]  = {0x18,0x18,0x18,0x18,0x18,0x00,0x18,0x00},
    ['"'-32]  = {0x6C,0x6C,0x24,0x00,0x00,0x00,0x00,0x00},
    ['#'-32]  = {0x6C,0xFE,0x6C,0x6C,0xFE,0x6C,0x00,0x00},
    ['$'-32]  = {0x18,0x7E,0x58,0x7E,0x1A,0x7E,0x18,0x00},
    ['%'-32]  = {0x62,0x64,0x08,0x10,0x26,0x46,0x00,0x00},
    ['&'-32]  = {0x38,0x44,0x38,0x3A,0x44,0x3A,0x00,0x00},
    ['\''-32] = {0x18,0x18,0x08,0x00,0x00,0x00,0x00,0x00},
    ['('-32]  = {0x0C,0x18,0x30,0x30,0x30,0x18,0x0C,0x00},
    [')'-32]  = {0x30,0x18,0x0C,0x0C,0x0C,0x18,0x30,0x00},
    ['*'-32]  = {0x00,0x66,0x3C,0xFF,0x3C,0x66,0x00,0x00},
    ['+'-32]  = {0x00,0x18,0x18,0x7E,0x18,0x18,0x00,0x00},
    [','-32]  = {0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x08},
    ['-'-32]  = {0x00,0x00,0x00,0x7E,0x00,0x00,0x00,0x00},
    ['.'-32]  = {0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x00},
    ['/'-32]  = {0x02,0x04,0x08,0x10,0x20,0x40,0x00,0x00},
    ['0'-32]  = {0x3C,0x46,0x4A,0x52,0x62,0x3C,0x00,0x00},
    ['1'-32]  = {0x18,0x38,0x18,0x18,0x18,0x3C,0x00,0x00},
    ['2'-32]  = {0x3C,0x42,0x02,0x3C,0x40,0x7E,0x00,0x00},
    ['3'-32]  = {0x3C,0x42,0x0C,0x02,0x42,0x3C,0x00,0x00},
    ['4'-32]  = {0x08,0x18,0x28,0x48,0x7E,0x08,0x00,0x00},
    ['5'-32]  = {0x7E,0x40,0x7C,0x02,0x42,0x3C,0x00,0x00},
    ['6'-32]  = {0x3C,0x40,0x7C,0x42,0x42,0x3C,0x00,0x00},
    ['7'-32]  = {0x7E,0x02,0x04,0x08,0x10,0x10,0x00,0x00},
    ['8'-32]  = {0x3C,0x42,0x3C,0x42,0x42,0x3C,0x00,0x00},
    ['9'-32]  = {0x3C,0x42,0x42,0x3E,0x02,0x3C,0x00,0x00},
    [':'-32]  = {0x00,0x18,0x18,0x00,0x18,0x18,0x00,0x00},
    [';'-32]  = {0x00,0x18,0x18,0x00,0x18,0x18,0x08,0x00},
    ['<'-32]  = {0x06,0x18,0x60,0x60,0x18,0x06,0x00,0x00},
    ['='-32]  = {0x00,0x00,0x7E,0x00,0x7E,0x00,0x00,0x00},
    ['>'-32]  = {0x60,0x18,0x06,0x06,0x18,0x60,0x00,0x00},
    ['?'-32]  = {0x3C,0x42,0x04,0x08,0x00,0x08,0x00,0x00},
    ['@'-32]  = {0x3C,0x42,0x5E,0x56,0x5E,0x40,0x3C,0x00},
    ['A'-32]  = {0x18,0x24,0x42,0x7E,0x42,0x42,0x00,0x00},
    ['B'-32]  = {0x7C,0x42,0x7C,0x42,0x42,0x7C,0x00,0x00},
    ['C'-32]  = {0x3C,0x42,0x40,0x40,0x42,0x3C,0x00,0x00},
    ['D'-32]  = {0x78,0x44,0x42,0x42,0x44,0x78,0x00,0x00},
    ['E'-32]  = {0x7E,0x40,0x7C,0x40,0x40,0x7E,0x00,0x00},
    ['F'-32]  = {0x7E,0x40,0x7C,0x40,0x40,0x40,0x00,0x00},
    ['G'-32]  = {0x3C,0x42,0x40,0x4E,0x42,0x3C,0x00,0x00},
    ['H'-32]  = {0x42,0x42,0x7E,0x42,0x42,0x42,0x00,0x00},
    ['I'-32]  = {0x3C,0x18,0x18,0x18,0x18,0x3C,0x00,0x00},
    ['J'-32]  = {0x1E,0x06,0x06,0x06,0x46,0x3C,0x00,0x00},
    ['K'-32]  = {0x44,0x48,0x70,0x48,0x44,0x42,0x00,0x00},
    ['L'-32]  = {0x40,0x40,0x40,0x40,0x40,0x7E,0x00,0x00},
    ['M'-32]  = {0x42,0x66,0x5A,0x42,0x42,0x42,0x00,0x00},
    ['N'-32]  = {0x42,0x62,0x52,0x4A,0x46,0x42,0x00,0x00},
    ['O'-32]  = {0x3C,0x42,0x42,0x42,0x42,0x3C,0x00,0x00},
    ['P'-32]  = {0x7C,0x42,0x42,0x7C,0x40,0x40,0x00,0x00},
    ['Q'-32]  = {0x3C,0x42,0x42,0x4A,0x44,0x3A,0x00,0x00},
    ['R'-32]  = {0x7C,0x42,0x42,0x7C,0x44,0x42,0x00,0x00},
    ['S'-32]  = {0x3C,0x40,0x3C,0x02,0x42,0x3C,0x00,0x00},
    ['T'-32]  = {0x7E,0x18,0x18,0x18,0x18,0x18,0x00,0x00},
    ['U'-32]  = {0x42,0x42,0x42,0x42,0x42,0x3C,0x00,0x00},
    ['V'-32]  = {0x42,0x42,0x42,0x24,0x24,0x18,0x00,0x00},
    ['W'-32]  = {0x42,0x42,0x42,0x5A,0x66,0x42,0x00,0x00},
    ['X'-32]  = {0x42,0x24,0x18,0x18,0x24,0x42,0x00,0x00},
    ['Y'-32]  = {0x42,0x42,0x24,0x18,0x18,0x18,0x00,0x00},
    ['Z'-32]  = {0x7E,0x04,0x08,0x10,0x20,0x7E,0x00,0x00},
    ['['-32]  = {0x3C,0x30,0x30,0x30,0x30,0x3C,0x00,0x00},
    ['\\'-32] = {0x40,0x20,0x10,0x08,0x04,0x02,0x00,0x00},
    [']'-32]  = {0x3C,0x0C,0x0C,0x0C,0x0C,0x3C,0x00,0x00},
    ['^'-32]  = {0x10,0x28,0x44,0x00,0x00,0x00,0x00,0x00},
    ['_'-32]  = {0x00,0x00,0x00,0x00,0x00,0x7E,0x00,0x00},
    ['`'-32]  = {0x30,0x18,0x0C,0x00,0x00,0x00,0x00,0x00},
    ['a'-32]  = {0x00,0x3C,0x02,0x3E,0x42,0x3E,0x00,0x00},
    ['b'-32]  = {0x40,0x40,0x7C,0x42,0x42,0x7C,0x00,0x00},
    ['c'-32]  = {0x00,0x3C,0x42,0x40,0x42,0x3C,0x00,0x00},
    ['d'-32]  = {0x02,0x02,0x3E,0x42,0x42,0x3E,0x00,0x00},
    ['e'-32]  = {0x00,0x3C,0x42,0x7E,0x40,0x3C,0x00,0x00},
    ['f'-32]  = {0x0E,0x10,0x3C,0x10,0x10,0x10,0x00,0x00},
    ['g'-32]  = {0x00,0x3E,0x42,0x3E,0x02,0x3C,0x00,0x00},
    ['h'-32]  = {0x40,0x40,0x7C,0x42,0x42,0x42,0x00,0x00},
    ['i'-32]  = {0x18,0x00,0x38,0x18,0x18,0x3C,0x00,0x00},
    ['j'-32]  = {0x04,0x00,0x04,0x04,0x04,0x44,0x38,0x00},
    ['k'-32]  = {0x40,0x44,0x48,0x70,0x48,0x44,0x00,0x00},
    ['l'-32]  = {0x38,0x18,0x18,0x18,0x18,0x3C,0x00,0x00},
    ['m'-32]  = {0x00,0x44,0x6A,0x52,0x42,0x42,0x00,0x00},
    ['n'-32]  = {0x00,0x7C,0x42,0x42,0x42,0x42,0x00,0x00},
    ['o'-32]  = {0x00,0x3C,0x42,0x42,0x42,0x3C,0x00,0x00},
    ['p'-32]  = {0x00,0x7C,0x42,0x7C,0x40,0x40,0x00,0x00},
    ['q'-32]  = {0x00,0x3E,0x42,0x3E,0x02,0x02,0x00,0x00},
    ['r'-32]  = {0x00,0x5C,0x62,0x40,0x40,0x40,0x00,0x00},
    ['s'-32]  = {0x00,0x3E,0x40,0x3C,0x02,0x7C,0x00,0x00},
    ['t'-32]  = {0x10,0x3C,0x10,0x10,0x12,0x0C,0x00,0x00},
    ['u'-32]  = {0x00,0x42,0x42,0x42,0x46,0x3A,0x00,0x00},
    ['v'-32]  = {0x00,0x42,0x42,0x24,0x24,0x18,0x00,0x00},
    ['w'-32]  = {0x00,0x42,0x42,0x52,0x6A,0x44,0x00,0x00},
    ['x'-32]  = {0x00,0x42,0x24,0x18,0x24,0x42,0x00,0x00},
    ['y'-32]  = {0x00,0x42,0x42,0x3E,0x02,0x3C,0x00,0x00},
    ['z'-32]  = {0x00,0x7E,0x04,0x18,0x20,0x7E,0x00,0x00},
    ['{'-32]  = {0x0C,0x18,0x30,0x18,0x18,0x0C,0x00,0x00},
    ['|'-32]  = {0x18,0x18,0x18,0x18,0x18,0x18,0x00,0x00},
    ['}'-32]  = {0x30,0x18,0x0C,0x18,0x18,0x30,0x00,0x00},
    ['~'-32]  = {0x00,0x32,0x4C,0x00,0x00,0x00,0x00,0x00},
};

/* Draw a filled rectangle. Coordinates are screen-relative (yoffset added internally). */
static void draw_rect(int x, int y, int w, int h, uint32_t color)
{
    for (int row = y; row < y + h && row < fb_height; row++) {
        int abs_y = row + fb_yoff;
        for (int col = x; col < x + w && col < fb_width; col++)
            fbmem[abs_y * fb_stride + col] = color;
    }
}

static void draw_char(int x, int y, char c, uint32_t color, int scale)
{
    if (c < 32 || c > 126) c = ' ';
    const unsigned char *glyph = font8x8[c - 32];
    for (int row = 0; row < 8; row++) {
        unsigned char bits = glyph[row];
        for (int col = 0; col < 8; col++) {
            if (bits & (0x80 >> col)) {
                for (int sy = 0; sy < scale; sy++)
                    for (int sx = 0; sx < scale; sx++) {
                        int px = x + col * scale + sx;
                        int py = y + row * scale + sy;
                        if (px >= 0 && px < fb_width && py >= 0 && py < fb_height) {
                            int abs_y = py + fb_yoff;
                            fbmem[abs_y * fb_stride + px] = color;
                        }
                    }
            }
        }
    }
}

static void draw_text(int x, int y, const char *text, uint32_t color, int scale)
{
    for (int i = 0; text[i]; i++)
        draw_char(x + i * 8 * scale, y, text[i], color, scale);
}

/* Map init script names to human-readable descriptions.
 * Returns NULL for scripts without a specific description. */
static const char *script_desc(const char *name)
{
    if (strstr(name, "populateshare"))     return "Populating user data...";
    if (strstr(name, "populate"))          return "Initializing system...";
    if (strstr(name, "udev"))              return "Detecting hardware...";
    if (strstr(name, "audioconfig"))       return "Configuring audio...";
    if (strstr(name, "audio"))             return "Configuring audio...";
    if (strstr(name, "modprobe"))          return "Loading drivers...";
    if (strstr(name, "network"))           return "Setting up network...";
    if (strstr(name, "share"))             return "Mounting storage...";
    if (strstr(name, "governor"))          return "Configuring CPU...";
    if (strstr(name, "powersave"))         return "Power management...";
    if (strstr(name, "connman"))           return "Starting network...";
    if (strstr(name, "bluetooth"))         return "Configuring bluetooth...";
    if (strstr(name, "brightness"))        return "Setting brightness...";
    if (strstr(name, "splash"))            return "Loading splash...";
    if (strstr(name, "dropbear"))          return "Starting SSH...";
    if (strstr(name, "ntp"))              return "Syncing clock...";
    if (strstr(name, "securepasswd"))      return "Securing system...";
    if (strstr(name, "system"))            return "Configuring system...";
    if (strstr(name, "emulationstation"))  return "Starting EmulationStation...";
    return NULL;  /* no specific description */
}

/*
 * Parse status line. Supports two formats:
 *   "N/TOTAL /etc/init.d/Sxxname"  (counter format from rcS)
 *   "/etc/init.d/Sxxname"          (legacy format)
 *
 * Returns target percentage (0-100), or -1 if unparseable.
 * Sets *desc_out to a human-readable description.
 */
static int parse_status(const char *line, const char **desc_out)
{
    int n, total;
    char path[256];

    /* Try counter format first: "N/TOTAL /path" */
    if (sscanf(line, "%d/%d %255s", &n, &total, path) == 3 && total > 0) {
        *desc_out = script_desc(path);
        return (n * 100) / total;
    }

    /* Legacy: just a path */
    *desc_out = script_desc(line);
    return -1;
}

int main(void)
{
    logfp = fopen(LOG_PATH, "w");
    logmsg("progressbar starting\n");

    int fb_fd = open("/dev/fb0", O_RDWR);
    if (fb_fd < 0) { logmsg("cannot open /dev/fb0\n"); return 1; }

    struct fb_var_screeninfo vinfo;
    if (ioctl(fb_fd, FBIOGET_VSCREENINFO, &vinfo) < 0) {
        logmsg("FBIOGET_VSCREENINFO failed\n");
        close(fb_fd);
        return 1;
    }

    struct fb_fix_screeninfo finfo;
    if (ioctl(fb_fd, FBIOGET_FSCREENINFO, &finfo) < 0) {
        logmsg("FBIOGET_FSCREENINFO failed\n");
        close(fb_fd);
        return 1;
    }

    fb_width  = vinfo.xres;
    fb_height = vinfo.yres;
    fb_stride = finfo.line_length / 4;
    fb_yoff   = vinfo.yoffset;

    logmsg("fb: %dx%d stride=%d yoffset=%d yres_virtual=%d bpp=%d\n",
           fb_width, fb_height, fb_stride, fb_yoff,
           vinfo.yres_virtual, vinfo.bits_per_pixel);

    size_t fb_size = finfo.line_length * vinfo.yres_virtual;
    fbmem = mmap(NULL, fb_size, PROT_READ | PROT_WRITE, MAP_SHARED, fb_fd, 0);
    if (fbmem == MAP_FAILED) {
        logmsg("mmap failed\n");
        close(fb_fd);
        return 1;
    }

    int bar_x = BAR_SIDE;
    int bar_y = fb_height - BAR_MARGIN;
    int bar_w = fb_width - 2 * BAR_SIDE;
    int text_bg_h = CHAR_H + 2 * TEXT_PAD_Y;
    int text_bg_y = bar_y - TEXT_MARGIN - text_bg_h;
    int text_x = bar_x + TEXT_PAD_X;
    int text_y = text_bg_y + TEXT_PAD_Y;

    logmsg("bar: x=%d y=%d w=%d h=%d\n", bar_x, bar_y, bar_w, BAR_HEIGHT);
    logmsg("text_bg: y=%d h=%d  text: x=%d y=%d\n", text_bg_y, text_bg_h, text_x, text_y);

    char line[256];
    int target_pct = 0;    /* where progress should be (from status updates) */
    int display_pct = 0;   /* what's currently displayed (animated) */
    char prev_desc[64] = "";
    int done = 0;
    int splash_ready = 0;  /* set once fbv has drawn the splash image */

    for (;;) {
        usleep(ANIM_INTERVAL);

        /* Wait for the splash image to be drawn by fbv before we
         * draw anything.  Once visible, save the clean splash pixels
         * behind the text area and draw the bar track. */
        if (!splash_ready) {
            if (splash_is_visible()) {
                save_text_bg(bar_x, text_bg_y, bar_w, text_bg_h);
                draw_rect(bar_x, bar_y, bar_w, BAR_HEIGHT, BAR_BG_COLOR);
                splash_ready = 1;
                logmsg("splash detected, saved text bg, drew bar\n");
            } else {
                continue;  /* nothing to do yet */
            }
        }

        /* Read status file */
        FILE *sf = fopen(STATUS_PATH, "r");
        if (sf) {
            if (fgets(line, sizeof(line), sf)) {
                char *nl = strchr(line, '\n');
                if (nl) *nl = '\0';

                /* Check for DONE — rcS finished all scripts */
                if (strcmp(line, "DONE") == 0) {
                    if (!done) {
                        target_pct = 100;
                        done = 1;
                        logmsg("DONE received, finishing\n");
                    }
                } else {
                    const char *desc;
                    int pct = parse_status(line, &desc);

                    if (pct >= 0 && pct > target_pct) {
                        target_pct = pct;
                        logmsg("status: pct=%d desc='%s' line='%s'\n", pct, desc, line);
                    }

                    /* Counter reached 100% — all scripts processed */
                    if (pct >= 100 && !done) {
                        done = 1;
                        logmsg("counter reached 100%%\n");
                    }

                    /* Update status text (skip if no specific description) */
                    if (desc != NULL && strcmp(desc, prev_desc) != 0) {
                        restore_text_bg();
                        draw_text(text_x, text_y, desc, TEXT_COLOR, FONT_SCALE);
                        logmsg("text: '%s'\n", desc);
                        strncpy(prev_desc, desc, sizeof(prev_desc) - 1);
                        prev_desc[sizeof(prev_desc) - 1] = '\0';
                    }
                }
            }
            fclose(sf);
        }

        /* Animate progress bar smoothly toward target */
        if (display_pct < target_pct) {
            display_pct++;
            int fill_w = (bar_w * display_pct) / 100;
            draw_rect(bar_x, bar_y, fill_w, BAR_HEIGHT, BAR_FG_COLOR);
        }

        /* Exit after reaching 100% */
        if (done && display_pct >= 100)
            break;
    }

    /* Clear framebuffer to black so stale boot screen doesn't show
     * when ES or an emulator briefly releases the display */
    draw_rect(0, 0, fb_width, fb_height, 0xFF000000);

    logmsg("exiting normally\n");
    if (logfp) fclose(logfp);
    munmap(fbmem, fb_size);
    close(fb_fd);
    return 0;
}
