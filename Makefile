.PHONY: all clean run

APP_NAME = Upcoming
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CONTENTS_DIR = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS_DIR)/MacOS
EXECUTABLE = $(MACOS_DIR)/$(APP_NAME)
SOURCE = src/Main.swift
INFO_PLIST = src/Info.plist

all: $(EXECUTABLE)

$(EXECUTABLE): $(SOURCE) $(INFO_PLIST)
	@echo "Building $(APP_NAME).app..."
	@mkdir -p $(MACOS_DIR)
	@swiftc $(SOURCE) -framework EventKit -o $(EXECUTABLE)
	@echo "Copying Info.plist..."
	@cp $(INFO_PLIST) $(CONTENTS_DIR)/Info.plist
	@echo "Build complete: $(APP_BUNDLE)"

clean:
	@echo "Cleaning build directory..."
	@rm -rf $(BUILD_DIR)

run: $(EXECUTABLE)
	@echo "Launching $(APP_NAME).app..."
	@open $(APP_BUNDLE)

