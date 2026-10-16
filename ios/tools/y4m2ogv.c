/* Encodes a YUV4MPEG2 (4:2:0) stream from stdin into an Ogg Theora file,
 * video only. ffmpeg decodes the source into the pipe:
 *   ffmpeg -i in.mp4 -f yuv4mpegpipe -pix_fmt yuv420p - | y4m2ogv QUALITY out.ogv
 * QUALITY is libtheora's 0-63 scale. Godot plays the result natively. */
#include <ogg/ogg.h>
#include <theora/theoraenc.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int write_pages(ogg_stream_state* stream, FILE* out, int flush) {
    ogg_page page;
    while (flush ? ogg_stream_flush(stream, &page) : ogg_stream_pageout(stream, &page)) {
        if (fwrite(page.header, 1, page.header_len, out) != (size_t)page.header_len ||
            fwrite(page.body, 1, page.body_len, out) != (size_t)page.body_len)
            return -1;
    }
    return 0;
}

static int read_line(char* buffer, size_t size) {
    size_t n = 0;
    int c;
    while ((c = getchar()) != EOF && c != '\n')
        if (n + 1 < size) buffer[n++] = (char)c;
    buffer[n] = 0;
    return c == EOF && n == 0 ? -1 : 0;
}

int main(int argc, char** argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s QUALITY(0-63) out.ogv < in.y4m\n", argv[0]);
        return 2;
    }
    char header[512];
    if (read_line(header, sizeof header) || strncmp(header, "YUV4MPEG2 ", 10) != 0) {
        fprintf(stderr, "input is not YUV4MPEG2\n");
        return 1;
    }
    int width = 0, height = 0, fps_n = 30, fps_d = 1;
    for (char* token = strtok(header + 10, " "); token; token = strtok(NULL, " ")) {
        if (token[0] == 'W') width = atoi(token + 1);
        else if (token[0] == 'H') height = atoi(token + 1);
        else if (token[0] == 'F') sscanf(token + 1, "%d:%d", &fps_n, &fps_d);
        else if (token[0] == 'C' && strncmp(token + 1, "420", 3) != 0) {
            fprintf(stderr, "only 4:2:0 input is supported (got %s)\n", token);
            return 1;
        }
    }
    if (width <= 0 || height <= 0) return 1;
    th_info info;
    th_info_init(&info);
    info.frame_width = (width + 15) & ~15;
    info.frame_height = (height + 15) & ~15;
    info.pic_width = width;
    info.pic_height = height;
    info.pic_x = 0;
    info.pic_y = 0;
    info.fps_numerator = fps_n;
    info.fps_denominator = fps_d;
    info.aspect_numerator = 1;
    info.aspect_denominator = 1;
    info.colorspace = TH_CS_UNSPECIFIED;
    info.pixel_fmt = TH_PF_420;
    info.target_bitrate = 0;
    info.quality = atoi(argv[1]);
    info.keyframe_granule_shift = 6;  /* a keyframe at least every 64 frames, for seeking */
    th_enc_ctx* encoder = th_encode_alloc(&info);
    if (!encoder) { fprintf(stderr, "libtheora refused the parameters\n"); return 1; }
    /* Best speed level: the files are small, the machine's time is not. */
    int speed = 0;
    th_encode_ctl(encoder, TH_ENCCTL_GET_SPLEVEL_MAX, &speed, sizeof speed);
    FILE* out = fopen(argv[2], "wb");
    if (!out) { perror(argv[2]); return 1; }
    ogg_stream_state stream;
    ogg_stream_init(&stream, (int)(rand() & 0x7fffffff) | 1);
    th_comment comment;
    th_comment_init(&comment);
    ogg_packet packet;
    int first = 1;
    while (th_encode_flushheader(encoder, &comment, &packet) > 0) {
        ogg_stream_packetin(&stream, &packet);
        if (first) { write_pages(&stream, out, 1); first = 0; }  /* the identification header alone on page one */
    }
    write_pages(&stream, out, 1);
    const size_t luma = (size_t)info.frame_width * info.frame_height;
    const size_t chroma = luma / 4;
    unsigned char* planes = calloc(luma + 2 * chroma, 1);
    memset(planes + luma, 128, 2 * chroma);
    th_ycbcr_buffer image;
    image[0].width = info.frame_width; image[0].height = info.frame_height; image[0].stride = info.frame_width; image[0].data = planes;
    image[1].width = info.frame_width / 2; image[1].height = info.frame_height / 2; image[1].stride = info.frame_width / 2; image[1].data = planes + luma;
    image[2].width = info.frame_width / 2; image[2].height = info.frame_height / 2; image[2].stride = info.frame_width / 2; image[2].data = planes + luma + chroma;
    const int cw = (width + 1) / 2, ch = (height + 1) / 2;
    unsigned char* row = malloc((size_t)width);
    char frame_header[256];
    long frames = 0;
    int pending = 0;
    for (;;) {
        if (read_line(frame_header, sizeof frame_header)) break;
        if (strncmp(frame_header, "FRAME", 5) != 0) { fprintf(stderr, "bad frame header\n"); return 1; }
        int ok = 1;
        for (int y = 0; y < height && ok; ++y) ok = fread(planes + (size_t)y * info.frame_width, 1, (size_t)width, stdin) == (size_t)width;
        for (int p = 1; p <= 2 && ok; ++p)
            for (int y = 0; y < ch && ok; ++y) ok = fread(image[p].data + (size_t)y * image[p].stride, 1, (size_t)cw, stdin) == (size_t)cw;
        if (!ok) break;
        /* Hold one frame back so the last one can be marked as the end. */
        if (pending) {
            while (th_encode_packetout(encoder, 0, &packet) > 0) ogg_stream_packetin(&stream, &packet);
            if (write_pages(&stream, out, 0)) return 1;
        }
        if (th_encode_ycbcr_in(encoder, image)) { fprintf(stderr, "encode failed\n"); return 1; }
        pending = 1;
        ++frames;
    }
    while (th_encode_packetout(encoder, 1, &packet) > 0) ogg_stream_packetin(&stream, &packet);
    write_pages(&stream, out, 1);
    fclose(out);
    th_encode_free(encoder);
    ogg_stream_clear(&stream);
    free(row);
    free(planes);
    fprintf(stderr, "%ld frames %dx%d\n", frames, width, height);
    return frames ? 0 : 1;
}
