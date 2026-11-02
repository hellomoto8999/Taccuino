.PHONY: build debug run clean icon

build:
	./scripts/build-app.sh release

debug:
	./scripts/build-app.sh debug

run: build
	open dist/Taccuino.app

clean:
	rm -rf .build dist

icon:
	./scripts/make-icon.sh
