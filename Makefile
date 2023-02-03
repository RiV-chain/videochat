run-windows:
	cmd.exe -/c flutter.bat run

build-web:
	flutter build web --web-renderer html --release
	