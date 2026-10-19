// SPDX-License-Identifier: GPL-2.0-only
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

static int pmsg = -1;
static int kmsg = -1;
/* Leave room for protocol headers inside pmsgdump's 16 KiB tail. */
#define MAX_OUTPUT 12288U

static int write_all(int fd, const char *p, size_t n)
{
	while (n) {
		ssize_t c = write(fd, p, n);
		if (c < 0 && errno == EINTR) continue;
		if (c <= 0) return -1;
		p += c; n -= (size_t)c;
	}
	return 0;
}

static void report(const char *p, size_t n)
{
	if (pmsg >= 0 && write_all(pmsg, p, n)) {
		dprintf(2, "G9209 pmsg write failed: %s\n", strerror(errno));
		close(pmsg); pmsg = -1;
	}
	if (pmsg < 0 && kmsg >= 0 && write_all(kmsg, p, n)) { /* Best effort fallback. */ }
	if (write_all(1, p, n)) { /* Console loss must not discard pmsg. */ }
}

static unsigned hash(const char *p)
{
	unsigned h = 2166136261U;
	while (*p) { h ^= (unsigned char)*p++; h *= 16777619U; }
	return h;
}

static long long milliseconds(void)
{
	struct timespec t;
	if (clock_gettime(CLOCK_MONOTONIC, &t)) return -1;
	return (long long)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static void virtual_mount(const char *target, const char *type, unsigned long flags)
{
	mkdir(target, 0755);
	if (mount(type, target, type, flags, NULL) && errno != EBUSY)
		dprintf(2, "G9209 mount %s: %s\n", target, strerror(errno));
}

/*
 * DSH: write to the USB ACM console and wait for the gadget to drain it.
 * A plain close() can race with the USB host reading the last report, so
 * give the controller a short moment after tcdrain-style settling.
 */
static void tty_sync(int fd)
{
	/*
	 * Deliberately NOT tcdrain(): on the gadget side a drain with no
	 * attached host can block indefinitely, and we must never stall the
	 * PID 1 handover.  A short fixed delay is enough for the UDC to pick
	 * the descriptor up while the console is still readable.
	 */
	(void)fd;
	usleep(120 * 1000);
}

int main(int argc, char **argv)
{
	int fd, pipefd[2], status = 0, timed_out = 0, automatic = 0;
	int tty;
	int saved;
	char command[1024] = {0}, line[512], buffer[512];
	ssize_t n;
	size_t output = 0;
	pid_t child;
	struct utsname u;
	long long deadline;

	if (argc == 2 && !strcmp(argv[1], "--self-test")) {
		if (hash("hello") != 0x4f9f2cabU) return 1;
		puts("pmsg-init self-test PASS (no mounts or device access)");
		return 0;
	}
	if (argc != 1 || getpid() != 1) return 2;
	virtual_mount("/proc", "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC);
	virtual_mount("/sys", "sysfs", MS_NOSUID | MS_NODEV | MS_NOEXEC);
	virtual_mount("/dev", "devtmpfs", MS_NOSUID | MS_NOEXEC);
	virtual_mount("/dev/pts", "devpts", MS_NOSUID | MS_NOEXEC);
	virtual_mount("/tmp", "tmpfs", MS_NOSUID | MS_NODEV);
	fd = open("/dev/console", O_RDWR | O_CLOEXEC);
	if (fd >= 0) {
		for (int i = 0; i < 3; i++) dup2(fd, i);
		if (fd > 2) close(fd);
	}
	signal(SIGHUP, SIG_IGN);
	signal(SIGINT, SIG_IGN);
	pmsg = open("/dev/pmsg0", O_WRONLY | O_CLOEXEC);
	kmsg = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
	fd = open("/sys/firmware/devicetree/base/chosen/g9209,command", O_RDONLY | O_CLOEXEC);
	if (fd >= 0) {
		n = read(fd, command, sizeof(command) - 1);
		if (n > 0) automatic = command[0] != 0;
		close(fd);
	}
	uname(&u);
	n = snprintf(line, sizeof(line),
		     "G9209 REPORT BEGIN version=1 command_fnv=%08x bytes=%zu pmsg=%d kernel=%s machine=%s\n",
		     hash(command), strlen(command), pmsg >= 0, u.release, u.machine);
	report(line, (size_t)n);
	if (pipe2(pipefd, O_CLOEXEC)) goto idle;
	child = fork();
	if (child == 0) {
		char *args[] = {"sh", "/etc/rc", NULL};
		char *env[] = {"PATH=/bin:/sbin", "HOME=/", "TERM=linux", NULL};
		setsid();
		dup2(pipefd[1], 1); dup2(pipefd[1], 2);
		close(pipefd[0]); close(pipefd[1]);
		execve("/bin/sh", args, env);
		dprintf(2, "G9209 exec /bin/sh failed errno=%d: %s\n", errno, strerror(errno));
		_exit(127);
	}
	close(pipefd[1]);
	if (child < 0) { close(pipefd[0]); goto idle; }
	deadline = milliseconds() + 120000;
	for (;;) {
		struct pollfd p = {.fd = pipefd[0], .events = POLLIN};
		int r = poll(&p, 1, 250);
		if (r < 0 && errno != EINTR) break;
		if (r > 0 && (p.revents & (POLLIN | POLLHUP))) {
			n = read(pipefd[0], buffer, sizeof(buffer));
			if (n <= 0) break;
			if (output < MAX_OUTPUT) {
				size_t keep = (size_t)n < MAX_OUTPUT - output ? (size_t)n : MAX_OUTPUT - output;
				report(buffer, keep);
			}
			output += (size_t)n;
		}
		if (milliseconds() >= deadline) { timed_out = 1; break; }
	}
	close(pipefd[0]);
	if (timed_out) kill(-child, SIGKILL);
	for (;;) {
		pid_t reaped = waitpid(child, &status, WNOHANG);
		if (reaped == child || (reaped < 0 && errno != EINTR)) break;
		if (milliseconds() >= deadline && !timed_out) {
			timed_out = 1;
			kill(-child, SIGKILL);
		}
		usleep(10000);
	}
	/*
	 * DSH: PID1 handover.
	 *
	 * /etc/rc runs as a child of this process, so busybox switch_root's
	 * "getpid() != 1" guard makes it print usage and exit without ever
	 * switching root.  rc therefore writes the handover parameters and
	 * exits with status 88; this process -- which really is PID 1 -- then
	 * execs switch_root itself.
	 */
	if (WIFEXITED(status) && WEXITSTATUS(status) == 88) {
		char hbuf[512] = {0}, hroot[256] = "/mnt", hinit[256] = "/sbin/init";
		int hfd = open("/tmp/dsh-handover", O_RDONLY | O_CLOEXEC);
		if (hfd >= 0) {
			ssize_t hn = read(hfd, hbuf, sizeof(hbuf) - 1);
			close(hfd);
			if (hn > 0) {
				char *nl;
				hbuf[hn] = 0;
				nl = strchr(hbuf, '\n');
				if (nl) {
					*nl = 0;
					snprintf(hroot, sizeof(hroot), "%s", hbuf);
					snprintf(hinit, sizeof(hinit), "%s", nl + 1);
					nl = strchr(hinit, '\n');
					if (nl) *nl = 0;
				}
			}
		}
		/*
		 * Do not rely on report() here: this process opened /dev/console
		 * before the gadget ACM driver registered its printk console, so
		 * fd 1 still points at tty0 and is invisible over USB.  Write the
		 * handover banner straight to /dev/ttyGS0, which rc has already
		 * created through configfs.
		 */
		tty = open("/dev/ttyGS0", O_WRONLY | O_NOCTTY | O_CLOEXEC);
		if (tty >= 0) {
			dprintf(tty, "G9209 PID1 HANDOVER root=%s init=%s pid=%d\n",
				hroot, hinit, (int)getpid());
			tty_sync(tty);
			close(tty);
		}
		/*
		 * Second, independent carrier: printk goes straight through the
		 * ttyGS0 kernel console once the gadget has registered it and
		 * never touches the tty open/close/drain path.
		 */
		if (kmsg >= 0)
			dprintf(kmsg, "<6>G9209 PID1 HANDOVER root=%s init=%s\n",
				hroot, hinit);
		n = snprintf(line, sizeof(line),
			     "G9209 PID1 HANDOVER root=%s init=%s\n", hroot, hinit);
		report(line, (size_t)n);
		{
			char *hargs[] = {"switch_root", hroot, hinit, NULL};
			execv("/bin/switch_root", hargs);
		}
		/* Falling through would look exactly like a silent hang. */
		saved = errno;
		tty = open("/dev/ttyGS0", O_WRONLY | O_NOCTTY | O_CLOEXEC);
		if (tty >= 0) {
			dprintf(tty, "G9209 HANDOVER FAILED: %s\n", strerror(saved));
			tty_sync(tty);
			close(tty);
		}
		n = snprintf(line, sizeof(line),
			     "G9209 PID1 HANDOVER failed: %s\n", strerror(saved));
		report(line, (size_t)n);
		if (kmsg >= 0)
			dprintf(kmsg, "<3>G9209 HANDOVER FAILED: %s\n", strerror(saved));
		/* PID1 exit -> kernel panic -> panic=10 reboot -> ramoops corpse. */
		_exit(127);
	}

	n = snprintf(line, sizeof(line),
		     "\nG9209 REPORT END command_fnv=%08x status=%d timeout=%d output=%zu truncated=%d\n",
		     hash(command), status, timed_out, output, output > MAX_OUTPUT);
	report(line, (size_t)n);
	if (automatic) {
		const char done[] = "G9209 REBOOT after report; physical partitions were not mounted by init\n";
		report(done, sizeof(done) - 1);
		if (pmsg >= 0) close(pmsg);
		sync();
		reboot(RB_AUTOBOOT);
		dprintf(2, "G9209 reboot returned: %s\n", strerror(errno));
	}
idle:
	for (;;) {
		int s;
		while (waitpid(-1, &s, WNOHANG) > 0) {}
		pause();
	}
}
