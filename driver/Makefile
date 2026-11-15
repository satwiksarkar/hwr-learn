# HWR-LEARN Native Driver Makefile
# Supports Windows (MinGW/MSVC), Linux (GCC/Clang), and Android NDK

CC ?= gcc
CFLAGS ?= -O3 -Wall -Wextra -std=c99
LDFLAGS ?=

UNAME_S := $(shell uname -s 2>/dev/null || echo Windows)

ifeq ($(OS),Windows_NT)
    TARGET_LIB = hwr_driver.dll
    TARGET_EXE = hwr_driver.exe
    SHARED_FLAGS = -shared -DHWR_BUILD_DLL
else ifeq ($(UNAME_S),Darwin)
    TARGET_LIB = libhwr_driver.dylib
    TARGET_EXE = hwr_driver
    SHARED_FLAGS = -dynamiclib -fPIC
else
    TARGET_LIB = libhwr_driver.so
    TARGET_EXE = hwr_driver
    SHARED_FLAGS = -shared -fPIC
endif

all: $(TARGET_LIB) $(TARGET_EXE)

$(TARGET_LIB): hwr_driver.c hwr_driver.h hwr_data.h
	$(CC) $(CFLAGS) $(SHARED_FLAGS) -o $@ hwr_driver.c $(LDFLAGS)

$(TARGET_EXE): hwr_driver.c hwr_cli.c hwr_driver.h hwr_data.h
	$(CC) $(CFLAGS) -DHWR_STATIC -o $@ hwr_driver.c hwr_cli.c $(LDFLAGS)

test: $(TARGET_EXE)
	./$(TARGET_EXE) --test

clean:
	rm -f $(TARGET_LIB) $(TARGET_EXE) *.o *.dll *.so *.dylib *.exe

.PHONY: all test clean
