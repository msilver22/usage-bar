APP        := dist/UsageBar.app
INSTALL_DIR ?= /Applications

.PHONY: all build test install uninstall clean

all: build

build:
	bash scripts/build-app.sh

test:
	bash scripts/test.sh

install: build
	rm -rf "$(INSTALL_DIR)/UsageBar.app"
	cp -R "$(APP)" "$(INSTALL_DIR)/"
	@echo "Installed $(INSTALL_DIR)/UsageBar.app"

uninstall:
	rm -rf "$(INSTALL_DIR)/UsageBar.app"

clean:
	rm -rf .build dist
