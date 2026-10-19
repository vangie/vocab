.PHONY: app debug test smoke run clean

app:            ## Build build/Vocab.app (release)
	scripts/bundle.sh release

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
