# LanguageTool macOS helper scripts

Minimal scripts to install Docker (macOS) and run a local LanguageTool server in Docker.

What you get

- `install-docker.sh` — installs or verifies Docker Desktop on macOS (Homebrew or DMG). Run once to set up Docker.
- `start-languagetool.sh` — pulls and runs the LanguageTool Docker image and exposes the API on `http://localhost:8081`.

Quick install (download files)

- Using curl:

```bash
curl -L -o install-docker.sh \
	https://raw.githubusercontent.com/elusivus/scripts/main/languagetool-server-local/macos/install-docker.sh
curl -L -o start-languagetool.sh \
	https://raw.githubusercontent.com/elusivus/scripts/main/languagetool-server-local/macos/start-languagetool.sh
```

- Using wget:

```bash
wget -O install-docker.sh \
	https://raw.githubusercontent.com/elusivus/scripts/main/languagetool-server-local/macos/install-docker.sh
wget -O start-languagetool.sh \
	https://raw.githubusercontent.com/elusivus/scripts/main/languagetool-server-local/macos/start-languagetool.sh
```

Make scripts executable

```bash
chmod +x install-docker.sh start-languagetool.sh
```

Install notes

- `install-docker.sh` is intended to be run once to install Docker Desktop and perform initial checks. It may prompt for your password when copying to `/Applications` or configuring the system. Re-running is safe but usually unnecessary after Docker is installed.

Usage — start LanguageTool server

- Start the server (creates or restarts the container):

```bash
./start-languagetool.sh
```

- Quick API checks:

```bash
curl 'http://localhost:8081/v2/languages'
curl -X POST 'http://localhost:8081/v2/check' -d 'language=en-US' -d 'text=This is a teste.'
```

- Common container control commands:

```bash
docker logs -f languagetool-server
docker stop languagetool-server
docker start languagetool-server
docker rm -f languagetool-server
```

Safety

- Always inspect scripts before running. Do not run untrusted scripts with elevated privileges.
