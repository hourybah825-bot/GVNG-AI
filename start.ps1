$secureKey = Read-Host "Clé API OpenAI" -AsSecureString
$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
try {
  $env:OPENAI_API_KEY = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
} finally {
  [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

& (Join-Path $PSScriptRoot "server.ps1")
