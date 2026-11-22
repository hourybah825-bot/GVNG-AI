param(
  [int]$Port = 4173,
  [string]$Root = $PSScriptRoot
)

Add-Type -AssemblyName System.Net.Http

$Root = [System.IO.Path]::GetFullPath($Root)
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()

Write-Host "TASKORA AI disponible sur http://127.0.0.1:$Port/index.html"
Write-Host "Servir les fichiers depuis : $Root"

function Send-Json {
  param(
    [System.Net.HttpListenerResponse]$Response,
    [int]$StatusCode,
    [hashtable]$Data
  )

  $json = $Data | ConvertTo-Json -Compress
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  $Response.StatusCode = $StatusCode
  $Response.ContentType = "application/json; charset=utf-8"
  $Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $Response.Close()
}

function Send-File {
  param(
    [System.Net.HttpListenerContext]$Context,
    [string]$FilePath
  )

  if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
    $Context.Response.StatusCode = 404
    $Context.Response.Close()
    return
  }

  $extension = [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()
  $mimeTypes = @{
    ".html" = "text/html; charset=utf-8"
    ".css"  = "text/css; charset=utf-8"
    ".js"   = "text/javascript; charset=utf-8"
    ".json" = "application/json; charset=utf-8"
    ".svg"  = "image/svg+xml"
    ".png"  = "image/png"
    ".jpg"  = "image/jpeg"
    ".jpeg" = "image/jpeg"
    ".gif"  = "image/gif"
    ".ico"  = "image/x-icon"
  }
  $Context.Response.StatusCode = 200
  $Context.Response.ContentType = $mimeTypes[$extension]
  if (-not $Context.Response.ContentType) {
    $Context.Response.ContentType = "application/octet-stream"
  }

  $bytes = [System.IO.File]::ReadAllBytes($FilePath)
  $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $Context.Response.Close()
}

try {
  while ($listener.IsListening) {
    $context = $listener.GetContext()
    $request = $context.Request
    $response = $context.Response

    if ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -eq "/api/generate") {
      try {
        $reader = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
        $body = $reader.ReadToEnd()
        $reader.Dispose()
        $payload = $body | ConvertFrom-Json
        $prompt = [string]$payload.prompt

        if ([string]::IsNullOrWhiteSpace($prompt) -or $prompt.Length -gt 6000) {
          Send-Json -Response $response -StatusCode 400 -Data @{ error = "invalid_request" }
          continue
        }
        if ([string]::IsNullOrWhiteSpace($env:OPENAI_API_KEY)) {
          Send-Json -Response $response -StatusCode 503 -Data @{ error = "missing_key" }
          continue
        }

        $openAiRequest = @{
          model = $(if ($env:OPENAI_MODEL) { $env:OPENAI_MODEL } else { "gpt-4o-mini" })
          input = $prompt
          max_output_tokens = 1200
        } | ConvertTo-Json -Compress

        $http = [System.Net.Http.HttpClient]::new()
        $http.Timeout = [TimeSpan]::FromSeconds(90)
        $http.DefaultRequestHeaders.Authorization =
          [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $env:OPENAI_API_KEY)
        $content = [System.Net.Http.StringContent]::new(
          $openAiRequest,
          [System.Text.Encoding]::UTF8,
          "application/json"
        )

        $openAiResponse = $http.PostAsync(
          "https://api.openai.com/v1/responses",
          $content
        ).GetAwaiter().GetResult()
        $openAiBody = $openAiResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()

        if (-not $openAiResponse.IsSuccessStatusCode) {
          $statusCode = [int]$openAiResponse.StatusCode
          Send-Json -Response $response -StatusCode $(if ($statusCode -eq 429) { 429 } else { 502 }) -Data @{ error = "openai"; status = $statusCode }
          $content.Dispose()
          $http.Dispose()
          continue
        }

        $openAiData = $openAiBody | ConvertFrom-Json
        $textParts = @()
        foreach ($item in @($openAiData.output)) {
          foreach ($part in @($item.content)) {
            if ($part.type -eq "output_text" -and $part.text) {
              $textParts += [string]$part.text
            }
          }
        }

        Send-Json -Response $response -StatusCode 200 -Data @{ text = ($textParts -join "") }
        $content.Dispose()
        $http.Dispose()
      }
      catch {
        Write-Host "Erreur API : $($_.Exception.Message)"
        Send-Json -Response $response -StatusCode 502 -Data @{ error = "server" }
      }
      continue
    }

    if ($request.HttpMethod -ne "GET" -and $request.HttpMethod -ne "HEAD") {
      $response.StatusCode = 405
      $response.Close()
      continue
    }

    $relativePath = $request.Url.AbsolutePath.TrimStart("/")
    if ([string]::IsNullOrWhiteSpace($relativePath)) {
      $relativePath = "index.html"
    }
    $relativePath = [Uri]::UnescapeDataString($relativePath).Replace("/", "\")
    $filePath = [System.IO.Path]::GetFullPath((Join-Path $Root $relativePath))

    if (-not $filePath.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase)) {
      $response.StatusCode = 403
      $response.Close()
      continue
    }

    Send-File -Context $context -FilePath $filePath
  }
}
finally {
  $listener.Stop()
  $listener.Close()
}
