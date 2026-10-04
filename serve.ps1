<#
  Tiny local web server for previewing the dashboard on this PC
  (browsers won't load data.json from a file:// page).
    powershell -ExecutionPolicy Bypass -File serve.ps1
  then open http://localhost:8406/   (or /?demo for sample data)
#>
param([int]$Port = 8406)
$root = $PSScriptRoot
$types = @{ ".html"="text/html; charset=utf-8"; ".json"="application/json"; ".js"="text/javascript"; ".css"="text/css"; ".png"="image/png"; ".svg"="image/svg+xml"; ".ico"="image/x-icon" }
$l = New-Object Net.HttpListener
$l.Prefixes.Add("http://localhost:$Port/")
$l.Start()
Write-Host "Serving $root at http://localhost:$Port/  (Ctrl+C to stop)"
while ($l.IsListening) {
  $c = $l.GetContext()
  $rel = [Uri]::UnescapeDataString($c.Request.Url.AbsolutePath.TrimStart('/'))
  if (-not $rel) { $rel = "index.html" }
  $path = [IO.Path]::GetFullPath((Join-Path $root $rel))
  if ($path.StartsWith($root) -and (Test-Path -LiteralPath $path -PathType Leaf) -and $rel -notmatch '^(collector|\.git)[\\/]') {
    $bytes = [IO.File]::ReadAllBytes($path)
    $ext = [IO.Path]::GetExtension($path).ToLower()
    $c.Response.ContentType = $(if ($types[$ext]) { $types[$ext] } else { "application/octet-stream" })
    $c.Response.Headers.Add("Cache-Control", "no-store")
    $c.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  } else { $c.Response.StatusCode = 404 }
  $c.Response.Close()
}
