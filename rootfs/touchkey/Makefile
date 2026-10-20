# Cross-compile the touchkey remapper for the phone (aarch64 Debian).
CC      = aarch64-linux-gnu-gcc
STRIP   = aarch64-linux-gnu-strip
CFLAGS  ?= -static -O2 -Wall
TARGET  := touchkey-remap

all: $(TARGET)

$(TARGET): touchkey-remap.c
	$(CC) $(CFLAGS) -o $@ $<
	$(STRIP) $@

clean:
	rm -f $(TARGET)

.PHONY: all clean
