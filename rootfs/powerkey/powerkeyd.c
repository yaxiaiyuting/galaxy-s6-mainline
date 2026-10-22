// G9209 电源键守护程序 v3：按 DPMS 状态判断（安卓式）
//
// 逻辑：
//   屏幕亮 (DPMS=On)  → 锁屏 + 灭屏
//   屏幕灭 (DPMS=Off) → 唤醒（空密码时直接进桌面）
//
// v2 的 bug：用 ScreenSaver.GetActive（锁状态）判断，
// 但屏幕可能"灭着但没锁"（GNOME 的 DPMS 超时和锁屏是两条独立路径），
// 于是按键时误判成"未锁屏"→ 又调 Lock() → 屏幕保持黑 → 用户觉得没反应。
//
// v3 改成读 /sys/class/drm/card0-VGA-1/dpms，这是屏幕真实状态。
//
// 另外保留 v2 的设备自动重连（gpio-keys 被 rebind 后旧 fd 会失效）。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <dirent.h>
#include <linux/input.h>
#include <sys/ioctl.h>

#define KEY_POWER_CODE 116
#define MAX_READ_FAIL  5
#define DPMS_PATH "/sys/class/drm/card0-VGA-1/dpms"

static char g_path[128];

static int find_gpio_keys(char *path, size_t pathlen)
{
    DIR *d = opendir("/dev/input");
    struct dirent *de;
    int found = -1;
    if (!d) return -1;
    while ((de = readdir(d))) {
        if (strncmp(de->d_name, "event", 5) != 0) continue;
        char p[128], name[64] = "";
        int f;
        snprintf(p, sizeof(p), "/dev/input/%s", de->d_name);
        f = open(p, O_RDONLY | O_NONBLOCK);
        if (f < 0) continue;
        if (ioctl(f, EVIOCGNAME(sizeof(name)), name) < 0) { close(f); continue; }
        if (strcmp(name, "gpio-keys") == 0) {
            snprintf(path, pathlen, "%s", p);
            found = f;
            break;
        }
        close(f);
    }
    closedir(d);
    return found;
}

static int open_device(void)
{
    int fd = find_gpio_keys(g_path, sizeof(g_path));
    if (fd < 0) {
        fprintf(stderr, "powerkeyd: 找不到 gpio-keys\n");
        g_path[0] = '\0';
        return -1;
    }
    fprintf(stderr, "powerkeyd: 已打开 %s\n", g_path);
    return fd;
}

/* 屏幕是否处于关闭状态：读 DPMS */
static int screen_is_off(void)
{
    char buf[16] = {0};
    int fd = open(DPMS_PATH, O_RDONLY);
    if (fd < 0) return 0;                 /* 读不到就当亮着 */
    if (read(fd, buf, sizeof(buf) - 1) <= 0) { close(fd); return 0; }
    close(fd);
    return (strstr(buf, "Off") != NULL);
}

static void do_lock(void)
{
    fprintf(stderr, "powerkeyd: 锁屏+灭屏\n");
    system("gdbus call --session --dest org.gnome.ScreenSaver "
           "--object-path /org/gnome/ScreenSaver "
           "--method org.gnome.ScreenSaver.Lock >/dev/null 2>&1");
    system("loginctl lock-session 2>/dev/null");
}

static void do_wake(void)
{
    fprintf(stderr, "powerkeyd: 唤醒\n");
    /* 空密码 => 直接回桌面；如果设了密码，停在锁屏界面输密码 */
    system("gdbus call --session --dest org.gnome.ScreenSaver "
           "--object-path /org/gnome/ScreenSaver "
           "--method org.gnome.ScreenSaver.SetActive false >/dev/null 2>&1");
    system("loginctl unlock-session 2>/dev/null");
}

int main(void)
{
    int fd = open_device();
    if (fd < 0) { sleep(2); fd = open_device(); if (fd < 0) return 1; }

    struct input_event ev;
    int fails = 0;

    for (;;) {
        ssize_t n = read(fd, &ev, sizeof(ev));

        if (n == (ssize_t)sizeof(ev)) {
            fails = 0;
            if (ev.type != EV_KEY || ev.code != KEY_POWER_CODE || ev.value != 1)
                continue;
            /* 按 DPMS 真实状态判断 */
            if (screen_is_off()) do_wake();
            else                 do_lock();
            continue;
        }

        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            usleep(100000);
            fails = 0;
            continue;
        }

        fails++;
        if (fails >= MAX_READ_FAIL) {
            fprintf(stderr, "powerkeyd: 读失败 %d 次，重新扫描设备\n", fails);
            close(fd);
            sleep(1);
            fd = open_device();
            if (fd < 0) { sleep(3); continue; }
            fails = 0;
        } else {
            usleep(200000);
        }
    }
    return 0;
}
