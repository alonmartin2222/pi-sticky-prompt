SHELL := /bin/bash
APP_DIR := PiStickyPrompt
DEST    := $(CURDIR)

.PHONY: app debug release run install clean

app: release

release:
	cd $(APP_DIR) && ./make-app.sh release $(DEST)

debug:
	cd $(APP_DIR) && ./make-app.sh debug $(DEST)

run: release
	open $(DEST)/PiStickyPrompt.app

install: release
	@mkdir -p $(HOME)/Applications
	@rm -rf $(HOME)/Applications/PiStickyPrompt.app
	cp -R $(DEST)/PiStickyPrompt.app $(HOME)/Applications/
	@echo "installed to $(HOME)/Applications/PiStickyPrompt.app"

clean:
	cd $(APP_DIR) && swift package clean
	rm -rf $(DEST)/PiStickyPrompt.app
