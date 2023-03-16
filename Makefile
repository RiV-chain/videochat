build-web:
	flutter build webs

build-web-rhtml:
	flutter build web --web-renderer html --release

build-apk:
	flutter build apk

run-svr:
	dart run

run-ui:
	flutter run -d chrome
