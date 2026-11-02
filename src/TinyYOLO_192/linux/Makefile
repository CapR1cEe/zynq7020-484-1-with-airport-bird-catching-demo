obj-m += tinyyolo_dma.o
KDIR ?= /lib/modules/$(shell uname -r)/build
RUNTIME_OPT ?= -O3
TARGET_FLAGS ?=
.PHONY: all clean runtime userspace
all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules
clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
runtime:
	$(CC) -std=c11 -D_POSIX_C_SOURCE=200809L -DTINYYOLO_LINUX $(RUNTIME_OPT) $(TARGET_FLAGS) -ffp-contract=off -fno-strict-aliasing -Wall -Wextra -Werror ../software/source/integrated_network.c -o tinyyolo_linux -lm
userspace: runtime camera_stream camera_capture libtinyyolo_tracker.so
camera_stream: camera_stream.c
	$(CC) -std=c11 -D_POSIX_C_SOURCE=200809L -O3 $(TARGET_FLAGS) -Wall -Wextra -Werror $< -o $@
camera_capture: camera_capture.c
	$(CC) -std=c11 -D_POSIX_C_SOURCE=200809L -O3 $(TARGET_FLAGS) -Wall -Wextra -Werror $< -o $@
libtinyyolo_tracker.so: tracker_core.c
	$(CC) -std=c11 -O3 $(TARGET_FLAGS) -Wall -Wextra -Werror -fPIC -shared $< -o $@ -lm
