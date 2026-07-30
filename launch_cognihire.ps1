# Launches the CogniHire face service (if not already running) and the app.

$venvPython = "C:\claude\cognihire\service\.venv\Scripts\python.exe"
$serviceDir = "C:\claude\cognihire\service"
$appExe = "C:\claude\cognihire\build\windows\x64\runner\Debug\cognihire.exe"

$portInUse = Get-NetTCPConnection -LocalPort 8000 -ErrorAction SilentlyContinue
if (-not $portInUse) {
    Start-Process -FilePath $venvPython `
        -ArgumentList "-m uvicorn main:app --port 8000" `
        -WorkingDirectory $serviceDir `
        -WindowStyle Hidden
    Start-Sleep -Seconds 5
}

Start-Process -FilePath $appExe -WorkingDirectory (Split-Path $appExe)
