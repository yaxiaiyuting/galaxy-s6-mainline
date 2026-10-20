// G9209 电源键守护程序
//
// 背景：GNOME 的 gsd-media-keys 会注册一个
//   "handle-power-key" block inhibitor（systemd-inhibit --list 可见），
// 把电源键完全独占，导致 systemd-logind 的 HandlePowerKey=lock 永远
// 收不到事件 —— 按电源键毫无反应。
//
// 本程序直接读 /dev/input/event*（gpio-keys），按 Android 的逻辑：
//   - 未锁屏时按电源键 → loginctl lock-session（GNOME 锁屏 + DPMS off）
//   - 已锁屏时按电源键 → 唤醒（loginctl unlock-session 由 GNOME 处理）
//
// evdev 允许多个读者同时打开（gsd 没有 EVIOCGRAB），所以不冲突。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <dirent.h>
#include <linux/input.h>
#include <sys/wait.h>

#define KEY_POWER_CODE 116
#define LONG_PRESS_MS  3000

static int find_gpio_keys(void)
{
    DIR *d = opendir("/dev/input");
    struct dirent *de;
    int fd = -1;
    if (!d) return -1;
    while ((de = readdir(d))) {
        if (strncmp(de->d_name, "event", 5) != 0) continue;
        char path[128], name[64] = "";
        snprintf(path, sizeof(path), "/dev/input/%s", de->d_name);
        int f = open(path, O_RDONLY | O_NONBLOCK);
        if (f < 0) continue;
        if (ioctl(f, EVIOCGNAME(sizeof(name)), name) < 0) { close(f); continue; }
        if (strcmp(name, "gpio-keys") == 0) {
            fprintf(stderr, "powerkeyd: 找到 %s (%s)\n", path, name);
            fd = f;
            break;
        }
        close(f);
    }
    closedir(d);
    return fd;
}

static int is_locked(void)
{
    int st = system("loginctl show-session $(loginctl list-sessions --no-legend | awk '$3==\"0\"{print $1; exit}') -p LockedHint --value 2>/dev/null | grep -q yes");
    return st == 0;
}

static void do_lock(void)
{
    fprintf(stderr, "powerkeyd: 锁屏\n");
    system("loginctl lock-session 2>/dev/null");
    /* 立刻灭屏（lock-delay=0 时 GNOME 也会做，但保险起见） */
    system("gdbus call --session --dest org.gnome.ScreenSaver --object-path /org/gnome/ScreenSaver --method org.gnome.ScreenSaver.Lock 2>/dev/null");
}

static void do_unlock(void)
{
    fprintf(stderr, "powerkeyd: 唤醒\n");
    system("loginctl unlock-session 2>/dev/null");
    system("gdbus call --session --dest org.gnome.ScreenSaver --object-path /org/gnome/ScreenSaver --method org.gnome.ScreenSaver.SetActive false 2>/dev/null");
}

int main(void)
{
    int fd = find_gpio_keys();
    if (fd < 0) { fprintf(stderr, "powerkeyd: 找不到 gpio-keys\n"); return 1; }

    struct input_event ev;
    for (;;) {
        ssize_t n = read(fd, &ev, sizeof(ev));
        if (n != sizeof(ev)) {
            if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) { usleep(100000); continue; }
            usleep(200000);
            continue;
        }
        if (ev.type != EV_KEY) continue;
        if (ev.code != KEY_POWER_CODE) continue;
        if (ev.value != 1) continue;   /* 只处理按下 */

        if (is_locked()) do_unlock();
        else            do_lock();
    }
    return 0;
}
