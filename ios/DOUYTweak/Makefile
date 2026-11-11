#
#  兜鱼复刻版 · iOS 注入插件
#
#  在 macOS（GitHub Actions 的 macos-14 runner 也可）直接编译出 arm64 的 dylib，
#  不需要 Theos：只用 Xcode 自带的 clang + iPhoneOS SDK。
#
#  用法：
#      make            # 编译 + ad-hoc 签名
#      make clean
#      make info       # 打印产物 Mach-O 信息（验证用）
#

TARGET      := DOUY.dylib
BUILD_DIR   := build
SRC         := $(wildcard src/*.mm)
OBJ         := $(patsubst src/%.mm,$(BUILD_DIR)/%.o,$(SRC))

SDK         := $(shell xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
CXX         := xcrun --sdk iphoneos clang++

ARCH        := -arch arm64
MIN_IOS     := -miphoneos-version-min=14.0
FLAGS       := $(ARCH) $(MIN_IOS) -isysroot $(SDK) \
               -std=gnu++17 -fobjc-arc -fblocks -fvisibility=hidden -O2 -g0 \
               -Wall -Wno-unused-parameter -Wno-deprecated-declarations \
               -Wno-nullability-completeness -DNDEBUG
INCLUDES    := -Isrc

FRAMEWORKS  := -framework Foundation -framework UIKit -framework AVFoundation \
               -framework CoreMedia -framework CoreVideo -framework VideoToolbox \
               -framework AudioToolbox -framework CoreImage -framework CoreGraphics \
               -framework UniformTypeIdentifiers

LDFLAGS     := -dynamiclib -install_name @executable_path/Frameworks/$(TARGET) -dead_strip

ifeq ($(SDK),)
$(error 找不到 iPhoneOS SDK：请在 macOS 上执行，或用 GitHub Actions 的 macos runner)
endif

.PHONY: all clean info

all: $(TARGET)

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/%.o: src/%.mm | $(BUILD_DIR)
	$(CXX) $(FLAGS) $(INCLUDES) -c $< -o $@

$(TARGET): $(OBJ)
	$(CXX) $(FLAGS) $(LDFLAGS) $(OBJ) $(FRAMEWORKS) -o $@
	@echo "==> built $(TARGET) ($(shell wc -c < $(TARGET) | tr -d ' ') bytes)"
	codesign --force --sign - --timestamp=none $@ && echo "==> ad-hoc signed" || echo "!! codesign 失败（注入器通常会自己重签）"

info: $(TARGET)
	@file $(TARGET)
	@otool -hv $(TARGET)
	@otool -L $(TARGET)
	@echo "--- load command（注入时需要一条 LC_LOAD_DYLIB）---"
	@otool -l $(TARGET) | grep -A2 LC_LOAD_DYLIB | head -20

clean:
	@rm -rf $(BUILD_DIR) $(TARGET)
