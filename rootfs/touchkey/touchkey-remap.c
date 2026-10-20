// SPDX-License-Identifier: GPL-2.0
/*
 * G9209 touchkey remapper
 *
 * The Cypress CY8CMBR31x5 reports the capacitive BACK/RECENT keys as
 * KEY_BACK (158) and KEY_MENU (139).  Neither is useful to GNOME on
 * Wayland as-is, so grab the device and inject:
 *
 *   BACK   -> Alt+Left  (the conventional "go back" shortcut)
 *   RECENT -> Super     (GNOME overview / activity switch)
 *
 * Requires CONFIG_INPUT_UINPUT.  Runs as root, grabs the evdev node by
 * name so the raw KEY_BACK/KEY_MENU never reach applications.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define TOUCHKEY_NAME	"mbr-touchkey"
#define REMAP_NAME	"mbr-touchkey-remap"

static volatile sig_atomic_t stop;

static void on_signal(int sig)
{
	(void)sig;
	stop = 1;
}

static int open_touchkey(void)
{
	DIR *dir;
	struct dirent *de;
	int fd = -1;
	char path[300];
	char name[256];

	dir = opendir("/dev/input");
	if (!dir)
		return -1;

	while ((de = readdir(dir))) {
		if (strncmp(de->d_name, "event", 5))
			continue;
		snprintf(path, sizeof(path), "/dev/input/%s", de->d_name);
		fd = open(path, O_RDONLY | O_NONBLOCK);
		if (fd < 0)
			continue;
		memset(name, 0, sizeof(name));
		if (ioctl(fd, EVIOCGNAME(sizeof(name) - 1), name) >= 0 &&
		    !strcmp(name, TOUCHKEY_NAME)) {
			closedir(dir);
			return fd;
		}
		close(fd);
		fd = -1;
	}
	closedir(dir);
	return -1;
}

static int create_uinput(void)
{
	struct uinput_setup setup;
	int fd;

	fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
	if (fd < 0)
		return -1;

	ioctl(fd, UI_SET_EVBIT, EV_KEY);
	ioctl(fd, UI_SET_KEYBIT, KEY_LEFTALT);
	ioctl(fd, UI_SET_KEYBIT, KEY_LEFT);
	ioctl(fd, UI_SET_KEYBIT, KEY_LEFTMETA);

	memset(&setup, 0, sizeof(setup));
	snprintf(setup.name, UINPUT_MAX_NAME_SIZE, REMAP_NAME);
	setup.id.bustype = BUS_VIRTUAL;
	setup.id.vendor = 0x1;
	setup.id.product = 0x1;

	if (ioctl(fd, UI_DEV_SETUP, &setup) < 0 ||
	    ioctl(fd, UI_DEV_CREATE) < 0) {
		close(fd);
		return -1;
	}
	return fd;
}

static void emit(int fd, int type, int code, int value)
{
	struct input_event ev;

	memset(&ev, 0, sizeof(ev));
	ev.type = type;
	ev.code = code;
	ev.value = value;
	if (write(fd, &ev, sizeof(ev)) < 0)
		perror("write uinput");
}

static void syn(int fd)
{
	emit(fd, EV_SYN, SYN_REPORT, 0);
}

int main(void)
{
	struct sigaction sa;
	struct input_event ev;
	int input_fd, uinput_fd;

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_signal;
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);

	fprintf(stderr, "%s: waiting for %s\n", REMAP_NAME, TOUCHKEY_NAME);
	while (!stop && (input_fd = open_touchkey()) < 0)
		usleep(500000);
	if (stop)
		return 0;

	uinput_fd = create_uinput();
	if (uinput_fd < 0) {
		fprintf(stderr, "%s: cannot create uinput device: %s\n",
			REMAP_NAME, strerror(errno));
		close(input_fd);
		return 1;
	}

	if (ioctl(input_fd, EVIOCGRAB, 1) < 0) {
		fprintf(stderr, "%s: cannot grab touchkey: %s\n",
			REMAP_NAME, strerror(errno));
		close(uinput_fd);
		close(input_fd);
		return 1;
	}

	fprintf(stderr, "%s: grabbed touchkey, remapping BACK->Alt+Left, RECENT->Super\n",
		REMAP_NAME);
	usleep(100000);

	while (!stop) {
		ssize_t n = read(input_fd, &ev, sizeof(ev));

		if (n < 0) {
			if (errno == EAGAIN) {
				usleep(10000);
				continue;
			}
			if (errno == EINTR)
				continue;
			break;
		}
		if (n != sizeof(ev) || ev.type != EV_KEY)
			continue;

		if (ev.code == KEY_BACK) {
			if (ev.value == 1) {
				emit(uinput_fd, EV_KEY, KEY_LEFTALT, 1);
				emit(uinput_fd, EV_KEY, KEY_LEFT, 1);
				syn(uinput_fd);
			} else if (ev.value == 0) {
				emit(uinput_fd, EV_KEY, KEY_LEFT, 0);
				emit(uinput_fd, EV_KEY, KEY_LEFTALT, 0);
				syn(uinput_fd);
			}
		} else if (ev.code == KEY_MENU) {
			if (ev.value == 1) {
				emit(uinput_fd, EV_KEY, KEY_LEFTMETA, 1);
				syn(uinput_fd);
			} else if (ev.value == 0) {
				emit(uinput_fd, EV_KEY, KEY_LEFTMETA, 0);
				syn(uinput_fd);
			}
		}
	}

	ioctl(input_fd, EVIOCGRAB, 0);
	ioctl(uinput_fd, UI_DEV_DESTROY);
	close(uinput_fd);
	close(input_fd);
	return 0;
}
