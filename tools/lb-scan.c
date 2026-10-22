/*
 * lb-scan: one Color+Infrared scan from the OpticFilm 8200i GL128 backend, written as two files:
 * the 16-bit RGB frame (PPM) and its 16-bit infrared plane (PGM). scanimage can't do this: it
 * aborts on the second frame. Progress goes to stderr as "Progress: NN.N%" like scanimage.
 *
 *   lb-scan <device> <dpi> <exposure> <out.ppm> <out-ir.pgm>
 */
#include <sane/sane.h>
#include <sane/saneopts.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int set_opt(SANE_Handle h, const char *name, const char *sval, double nval) {
    SANE_Int n = 0;
    sane_control_option(h, 0, SANE_ACTION_GET_VALUE, &n, NULL);
    for (int i = 1; i < n; i++) {
        const SANE_Option_Descriptor *d = sane_get_option_descriptor(h, i);
        if (!d || !d->name || strcmp(d->name, name) != 0) continue;
        SANE_Status st;
        if (d->type == SANE_TYPE_STRING) st = sane_control_option(h, i, SANE_ACTION_SET_VALUE, (void *)sval, NULL);
        else if (d->type == SANE_TYPE_FIXED) { SANE_Fixed v = SANE_FIX(nval); st = sane_control_option(h, i, SANE_ACTION_SET_VALUE, &v, NULL); }
        else { SANE_Int v = (SANE_Int)nval; st = sane_control_option(h, i, SANE_ACTION_SET_VALUE, &v, NULL); }
        if (st != SANE_STATUS_GOOD) { fprintf(stderr, "option %s: %s\n", name, sane_strstatus(st)); return -1; }
        return 0;
    }
    fprintf(stderr, "no option %s\n", name);
    return -1;
}

static int read_frame(SANE_Handle h, const char *path, int frame_no, int frames) {
    SANE_Status st = sane_start(h);
    if (st != SANE_STATUS_GOOD) { fprintf(stderr, "start: %s\n", sane_strstatus(st)); return -1; }
    SANE_Parameters p;
    sane_get_parameters(h, &p);
    fprintf(stderr, "frame %d: format %d last_frame %d %dx%d depth %d\n", frame_no, p.format, p.last_frame, p.pixels_per_line, p.lines, p.depth);
    int ch = p.format == SANE_FRAME_RGB ? 3 : 1;
    FILE *f = fopen(path, "wb");
    if (!f) { perror(path); return -1; }
    fprintf(f, "P%d\n%d %d\n%d\n", ch == 3 ? 6 : 5, p.pixels_per_line, p.lines, p.depth == 16 ? 65535 : 255);
    long total = (long)p.bytes_per_line * p.lines, got = 0;
    unsigned char buf[1 << 16];
    SANE_Int len;
    double last = -1;
    while ((st = sane_read(h, buf, sizeof buf, &len)) == SANE_STATUS_GOOD) {
        if (p.depth == 16) {               /* SANE delivers host order; PNM wants big-endian */
            for (int i = 0; i + 1 < len; i += 2) { unsigned char t = buf[i]; buf[i] = buf[i + 1]; buf[i + 1] = t; }
        }
        fwrite(buf, 1, len, f);
        got += len;
        double pct = 100.0 * (frame_no + (double)got / (total > 0 ? total : 1)) / frames;
        if (pct - last >= 0.5) { fprintf(stderr, "Progress: %.1f%%\r", pct); fflush(stderr); last = pct; }
    }
    fclose(f);
    if (st != SANE_STATUS_EOF) { fprintf(stderr, "read: %s\n", sane_strstatus(st)); return -1; }
    return p.last_frame ? 1 : 0;
}

int main(int argc, char **argv) {
    if (argc != 6) { fprintf(stderr, "usage: lb-scan device dpi exposure out.ppm out-ir.pgm\n"); return 2; }
    SANE_Int ver; SANE_Handle h;
    sane_init(&ver, NULL);
    SANE_Status st = sane_open(argv[1], &h);
    if (st != SANE_STATUS_GOOD) { fprintf(stderr, "open: %s\n", sane_strstatus(st)); return 1; }
    if (set_opt(h, "mode", "Color+Infrared", 0) || set_opt(h, "depth", NULL, 16) ||
        set_opt(h, "resolution", NULL, atof(argv[2])) || set_opt(h, "exposure", NULL, atof(argv[3]))) { sane_close(h); return 1; }
    int r = read_frame(h, argv[4], 0, 2);
    if (r >= 0) {
        /* the backend hands out the IR plane on the next sane_start */
        int r2 = read_frame(h, argv[5], 1, 2);
        if (r2 < 0) { fprintf(stderr, "no infrared frame\n"); r = -1; } else r = 0;
    }
    sane_cancel(h); sane_close(h); sane_exit();
    fprintf(stderr, "Progress: 100.0%%\n");
    return r < 0 ? 1 : 0;
}
