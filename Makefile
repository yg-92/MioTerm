APP := MioTerm

.PHONY: all build app test run resolve clean

all: app

build:
	swift build -c release --arch arm64

app:
	./scripts/build-app.sh

test:
	swift test --filter MioTermTests

run: app
	open build/$(APP).app

resolve:
	swift package resolve

clean:
	@if [ -d build ]; then mv build "$${HOME}/.Trash/$(APP)-build-$$(date +%Y%m%d-%H%M%S)"; fi
