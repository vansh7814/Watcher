
FROM mcr.microsoft.com/powershell:latest

WORKDIR /app

COPY watcher.ps1 /app/watcher.ps1

CMD ["pwsh", "-NoLogo", "-File", "/app/watcher.ps1"]
