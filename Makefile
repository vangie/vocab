.PHONY: app app-dev debug test smoke run clean install

app:            ## Build build/Vocab.app (release)
	scripts/bundle.sh release

app-dev:        ## Release build with dev test hooks (vocab-smoke setquery)
	VOCAB_DEV_HOOKS=1 scripts/bundle.sh release

debug:
	scripts/bundle.sh debug

test:
	swift test

smoke:          ## Look up, render and play audio without a GUI session
	swift build --product vocab-smoke
	.build/debug/vocab-smoke lookup appal
	.build/debug/vocab-smoke lookup atlantic
	.build/debug/vocab-smoke play appal
	.build/debug/vocab-smoke click appal
	mkdir -p build/shots
	.build/debug/vocab-smoke render appal build/shots/appal.png
	.build/debug/vocab-smoke render appal build/shots/appal-dark.png dark

run: app
	open build/Vocab.app

clean:
	rm -rf .build build

INSTALL_DIR ?= /Applications
LSREGISTER = /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

install: app    ## Build release and install to $(INSTALL_DIR)/Vocab.app (data in ~/Library/Application Support/Vocab is untouched)
	@# Keep bundle.sh's signature (local "Vocab Local Signing" identity when set up, so the
	@# Accessibility grant survives reinstalls); fall back to ad-hoc only if it doesn't verify.
	codesign --verify --deep --strict build/Vocab.app 2>/dev/null || codesign --force --deep -s - build/Vocab.app
	-osascript -e 'tell application id "io.github.vangie.vocab" to quit' >/dev/null 2>&1
	@for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Vocab >/dev/null || break; sleep 0.5; done
	-pkill -x Vocab
	rm -rf "$(INSTALL_DIR)/.Vocab.app.new"
	ditto build/Vocab.app "$(INSTALL_DIR)/.Vocab.app.new"
	rm -rf "$(INSTALL_DIR)/Vocab.app"
	mv "$(INSTALL_DIR)/.Vocab.app.new" "$(INSTALL_DIR)/Vocab.app"
	-xattr -dr com.apple.quarantine "$(INSTALL_DIR)/Vocab.app"
	$(LSREGISTER) -f "$(INSTALL_DIR)/Vocab.app"
	open "$(INSTALL_DIR)/Vocab.app"
	@echo "Installed $(INSTALL_DIR)/Vocab.app"
