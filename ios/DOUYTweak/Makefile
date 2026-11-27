TARGET    := Yuancam.dylib
BUILD_DIR := build
SRC       := $(wildcard src/*.mm)
OBJ       := $(patsubst src/%.mm,$(BUILD_DIR)/%.o,$(SRC))
SDK       := $(shell xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
CXX       := xcrun --sdk iphoneos clang++
FLAGS     := -arch arm64 -miphoneos-version-min=14.0 -isysroot $(SDK) \
             -std=gnu++17 -fobjc-arc -fblocks -fvisibility=hidden -O2 -g0 \
             -Wall -Wno-unused-parameter -DNDEBUG
INCLUDES  := -Isrc
FRAMEWORKS:= -framework Foundation -framework UIKit
LDFLAGS   := -dynamiclib -install_name @executable_path/Frameworks/$(TARGET) -dead_strip

ifeq ($(SDK),)
$(error 找不到 iPhoneOS SDK)
endif

all: $(TARGET)

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/%.o: src/%.mm | $(BUILD_DIR)
	$(CXX) $(FLAGS) $(INCLUDES) -c $< -o $@

$(TARGET): $(OBJ)
	$(CXX) $(FLAGS) $(LDFLAGS) $(OBJ) $(FRAMEWORKS) -o $@
	codesign --force --sign - --timestamp=none $@ || true
	@cp -f $(TARGET) DOUY.dylib
clean:
	@rm -rf $(BUILD_DIR) $(TARGET)
