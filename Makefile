run-windows:
	cmd.exe -/c flutter.bat run

build-web:
	flutter build web --web-renderer html --release

run-svr:
	cd signalsvr && dart run bin/signalsvr.dart

run-ui:
	flutter run -d chrome
